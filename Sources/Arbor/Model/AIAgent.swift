import AppKit
import Observation

/// One thing the model asked Arbor to do.
struct AIToolCall: Sendable, Equatable {
    enum Tool: String, CaseIterable, Sendable {
        // Looking around: run straight away, results go back to the model.
        case list, search, info, read
        // Showing things: run straight away.
        case show, navigate, select, open, newTab
        // Changing files: collected into a plan the user approves.
        case mkdir, move, copy, rename, trash, tag, untag, command

        var changesFiles: Bool {
            switch self {
            case .mkdir, .move, .copy, .rename, .trash, .tag, .untag, .command: true
            default: false
            }
        }

        var looksAround: Bool { self == .list || self == .search || self == .info || self == .read }
    }

    var tool: Tool
    var path = ""
    var paths: [String] = []
    var to = ""
    var name = ""
    var command = ""
    var title = ""
    var query = AICommand.Query()

    static func == (a: AIToolCall, b: AIToolCall) -> Bool {
        a.tool == b.tool && a.path == b.path && a.paths == b.paths && a.to == b.to && a.name == b.name && a.command == b.command
    }
}

/// Changes waiting for the user's go-ahead.
struct AIPlan: Identifiable, Equatable {
    let id = UUID()
    var steps: [Step]
    /// The model wants to carry on after these run (e.g. report what it moved).
    var continues: Bool

    struct Step: Identifiable, Equatable {
        let id = UUID()
        let call: AIToolCall
        let summary: String
        let detail: [String]
        let symbol: String
        let isDestructive: Bool
    }
}

/// The "问 Arbor" assistant: looks around with read-only tools, shows and selects things directly, and
/// proposes file changes as a plan. Works with any model that can return JSON (no native tool calling needed).
@MainActor @Observable
final class AIAgent {
    enum Entry: Identifiable, Equatable {
        case user(UUID, String)
        case assistant(UUID, String)
        case activity(UUID, symbol: String, text: String)
        case plan(UUID, AIPlan)
        case error(UUID, String)

        var id: UUID {
            switch self {
            case .user(let id, _), .assistant(let id, _), .activity(let id, _, _), .plan(let id, _), .error(let id, _): id
            }
        }
    }

    enum PlanState: Equatable { case waiting, running, done, cancelled }

    private(set) var entries: [Entry] = [] {
        didSet { lastActivity = Date() }
    }
    /// When anything last happened; an idle conversation starts over the next time the bar opens.
    @ObservationIgnored private(set) var lastActivity = Date.distantPast
    private(set) var isThinking = false
    private(set) var planStates: [UUID: PlanState] = [:]

    @ObservationIgnored private weak var workspace: WorkspaceState?
    @ObservationIgnored private var conversation: [(role: String, content: String)] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pendingPlan: AIPlan?

    static let maxRounds = 8
    /// Opening the bar after this long without activity starts a fresh conversation.
    static let idleReset: TimeInterval = 180
    /// Requests kept as context for follow-ups ("move them too"); older ones are dropped.
    static let keptRequests = 3

    /// The bar is opening: a conversation that has gone quiet (and isn't waiting on a plan) starts over.
    func prepareForOpen() {
        guard !isThinking, pendingPlan == nil, hasConversation,
              Date().timeIntervalSince(lastActivity) > Self.idleReset else { return }
        reset()
    }

    /// The step under way, shown live while the model works.
    var liveStatus: String? {
        guard isThinking else { return nil }
        for entry in entries.reversed() {
            switch entry {
            case .activity(_, _, let text): return text
            case .assistant(_, let text): return text
            case .user: return nil
            default: continue
            }
        }
        return nil
    }

    /// Keeps the last few requests (for the model and on screen); simple tasks don't need a long history.
    private func trimHistory() {
        let requests = conversation.indices.filter { conversation[$0].role == "user" && conversation[$0].content.contains("\nRequest: ") }
        if requests.count > Self.keptRequests {
            conversation.removeSubrange(..<requests[requests.count - Self.keptRequests])
        }
        let turns = entries.indices.filter { if case .user = entries[$0] { true } else { false } }
        if turns.count > Self.keptRequests * 2 {
            entries.removeSubrange(..<turns[turns.count - Self.keptRequests * 2])
        }
    }

    init(workspace: WorkspaceState) {
        self.workspace = workspace
    }

    var hasConversation: Bool { !entries.isEmpty }

    func reset() {
        stop()
        entries = []
        conversation = []
        planStates = [:]
        pendingPlan = nil
    }

    func stop() {
        task?.cancel()
        task = nil
        setThinking(false)
    }

    // MARK: Asking

    func send(_ request: String) {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking, let workspace else { return }
        // A new request drops a plan nobody approved.
        if let plan = pendingPlan { planStates[plan.id] = .cancelled; pendingPlan = nil }
        entries.append(.user(UUID(), text))
        let config = AppSettings.shared.aiConfig
        guard config.isUsable else {
            entries.append(.error(UUID(), AIError.notConfigured.localizedDescription))
            return
        }
        conversation.append(("user", AIAgentPrompt.context(for: workspace) + "\n\nRequest: " + text))
        trimHistory()
        run(config: config)
    }

    private func run(config: AIConfig) {
        setThinking(true)
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.setThinking(false) }
            do {
                try await self.loop(config: config)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                self.entries.append(.error(UUID(), error.localizedDescription))
            }
        }
    }

    /// Ask, run what can run, feed results back — until the model is done, proposes changes, or runs out of rounds.
    private func loop(config: AIConfig) async throws {
        let language = Localization.isEnglish ? "English" : "Simplified Chinese"
        for round in 0..<Self.maxRounds {
            try Task.checkCancellation()
            let object = try await ask(config: config, language: language)
            try Task.checkCancellation()
            conversation.append(("assistant", Self.json(object)))
            let say = (object["say"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let calls = (object["calls"] as? [[String: Any]] ?? []).compactMap(AIAgentPrompt.call(from:))
            let done = object["done"] as? Bool ?? true
            if !say.isEmpty { entries.append(.assistant(UUID(), say)) }

            let immediate = calls.filter { !$0.tool.changesFiles }
            let changes = calls.filter(\.tool.changesFiles)
            var results: [String] = []
            for call in immediate { results.append(await perform(call)) }

            if !changes.isEmpty {
                let base = workspace?.activeTab.url
                let plan = AIPlan(steps: changes.map { Self.describe($0, base: base) }, continues: !done)
                pendingPlan = plan
                planStates[plan.id] = .waiting
                entries.append(.plan(UUID(), plan))
                if !results.isEmpty { conversation.append(("user", "Results:\n" + results.joined(separator: "\n\n"))) }
                return
            }
            if done || calls.isEmpty {
                if say.isEmpty, calls.isEmpty { entries.append(.assistant(UUID(), L("好了。"))) }
                return
            }
            if round == Self.maxRounds - 1 {
                entries.append(.error(UUID(), L("步骤太多了，先停在这里。可以换个更具体的说法再试。")))
                return
            }
            conversation.append(("user", "Results:\n" + results.joined(separator: "\n\n")))
        }
    }

    /// One model turn. A reply that isn't the JSON object (blank, prose, cut off) gets up to two corrections:
    /// the model sees what it sent and is asked again. The failed exchange is then dropped from the history.
    private func ask(config: AIConfig, language: String) async throws -> [String: Any] {
        let mark = conversation.count
        var attempt = 0
        while true {
            do {
                let object = try await AIClient.conversation(system: AIAgentPrompt.system(language: language),
                                                             messages: conversation, schema: AIAgentPrompt.schema(),
                                                             config: config, maxTokens: 8192)
                if conversation.count > mark { conversation.removeSubrange(mark...) }
                return object
            } catch AIError.unreadable(let raw) where attempt < 2 {
                attempt += 1
                try Task.checkCancellation()
                entries.append(.activity(UUID(), symbol: "arrow.clockwise", text: L("模型的回复格式不对，正在让它重新回答…")))
                let sent = AIError.snippet(raw) == nil ? "(an empty reply)" : String(raw.prefix(1500))
                conversation.append(("assistant", sent))
                conversation.append(("user", """
                    That reply was not a valid JSON object. Answer again with ONLY one JSON object of the form \
                    {"say": "...", "calls": [...], "done": true|false} — no other text, no code fences, no thinking.
                    """))
            } catch AIError.unreadable where attempt >= 2 {
                if conversation.count > mark { conversation.removeSubrange(mark...) }
                throw AIError.unreadable(raw: "")
            }
        }
    }

    // MARK: Plans

    func approve(_ plan: AIPlan) {
        guard pendingPlan?.id == plan.id, let workspace else { return }
        pendingPlan = nil
        planStates[plan.id] = .running
        setThinking(true)
        task = Task { [weak self] in
            guard let self else { return }
            var results: [String] = []
            var failed = false
            for step in plan.steps {
                if Task.isCancelled { break }
                let result = await self.execute(step.call, in: workspace)
                results.append(result.text)
                if !result.ok { failed = true; break }
            }
            self.planStates[plan.id] = .done
            // Result lists point at where files were; after changes, show the folder as it is now.
            if workspace.hasAIResults { workspace.closeAIResults() }
            workspace.activeTab.reload()
            self.entries.append(.activity(UUID(), symbol: failed ? "exclamationmark.triangle" : "checkmark.circle",
                                          text: failed ? L("执行到一半停下了：\(results.last ?? "")")
                                                       : L("已完成，可以用 ⌘Z 撤销。")))
            self.conversation.append(("user", "The user approved. Results:\n" + results.joined(separator: "\n")))
            self.setThinking(false)
            if plan.continues, !failed {
                self.run(config: AppSettings.shared.aiConfig)
            }
        }
    }

    func reject(_ plan: AIPlan) {
        guard pendingPlan?.id == plan.id else { return }
        pendingPlan = nil
        planStates[plan.id] = .cancelled
        conversation.append(("user", "The user declined these changes. Nothing was changed."))
    }

    private func setThinking(_ value: Bool) {
        isThinking = value
        workspace?.aiThinking = value
    }

    // MARK: Running tools

    /// Runs a tool that doesn't change files and returns what to tell the model.
    private func perform(_ call: AIToolCall) async -> String {
        guard let workspace else { return "error: no window" }
        let tab = workspace.activeTab
        switch call.tool {
        case .list:
            guard let folder = resolve(call.path, directory: true) else { return "list \(call.path): not found" }
            entries.append(.activity(UUID(), symbol: "folder", text: L("查看 \(Self.short(folder))")))
            return "list \(folder.path):\n" + (await AIAgentTools.list(folder))
        case .search:
            let scope = call.query.wholeHome || call.path.isEmpty && tab.url.path == "/"
                ? FileManager.default.homeDirectoryForCurrentUser : (resolve(call.path, directory: true) ?? tab.url)
            guard let predicate = AIAssistant.predicate(for: call.query) else { return "search: empty query" }
            let found: [FileItem]
            do {
                found = try await AIAgentTools.search(predicate, in: scope)
            } catch {
                entries.append(.activity(UUID(), symbol: "exclamationmark.triangle", text: L("搜索失败：\(error.localizedDescription)")))
                return "search failed: \(error.localizedDescription). Try a simpler query."
            }
            entries.append(.activity(UUID(), symbol: "magnifyingglass",
                                     text: L("在 \(Self.short(scope)) 中搜索，找到 \(found.count) 项")))
            return "search in \(scope.path) → \(found.count) results (newest first):\n"
                + found.prefix(80).map(AIAgentTools.line).joined(separator: "\n")
        case .info:
            let urls = call.paths.compactMap { resolve($0) }
            entries.append(.activity(UUID(), symbol: "info.circle", text: L("查看 \(urls.count) 项的信息")))
            return await AIAgentTools.info(urls)
        case .read:
            guard let url = resolve(call.path) else { return "read \(call.path): not found" }
            entries.append(.activity(UUID(), symbol: "doc.text.magnifyingglass", text: L("读取 \(url.lastPathComponent)")))
            let text = await AIAssistant.excerpt(of: url, limit: 2500)
            return "read \(url.path):\n" + (text.isEmpty ? "(no readable text)" : text)
        case .show:
            let urls = call.paths.compactMap { resolve($0) }
            let title = call.title.isEmpty ? L("AI 结果") : call.title
            if !urls.isEmpty {
                workspace.showAIResults(TabState.AIQuery(title: title, predicate: nil, scope: tab.url, urls: urls))
            } else if let predicate = AIAssistant.predicate(for: call.query) {
                let scope = call.query.wholeHome ? FileManager.default.homeDirectoryForCurrentUser
                    : (resolve(call.path, directory: true) ?? tab.url)
                workspace.showAIResults(TabState.AIQuery(title: title, predicate: predicate, scope: scope))
            } else {
                return "show: nothing to show"
            }
            workspace.focusToken += 1
            entries.append(.activity(UUID(), symbol: "list.bullet.rectangle", text: L("在临时标签页里显示“\(title)”")))
            return "show: displayed in the current tab"
        case .navigate, .newTab:
            guard let folder = resolve(call.path, directory: true) else { return "\(call.tool.rawValue) \(call.path): not found" }
            if call.tool == .newTab { workspace.openInNewTab(folder) } else { workspace.go(to: folder) }
            entries.append(.activity(UUID(), symbol: "arrow.right.circle", text: L("打开 \(Self.short(folder))")))
            return "\(call.tool.rawValue): now showing \(folder.path)"
        case .select:
            let urls = call.paths.compactMap { resolve($0) }
            guard let first = urls.first else { return "select: nothing found" }
            // Already on screen (this folder, or AI results)? Select in place; otherwise go to their folder first.
            let shown = Set(tab.visibleRows.map(\.url.standardizedFileURL.path))
            if !urls.allSatisfy({ shown.contains($0.path) }) {
                tab.navigate(to: first.deletingLastPathComponent())
                try? await Task.sleep(for: .milliseconds(300)) // let the folder load
            }
            tab.selection = Set(urls)
            workspace.focusToken += 1
            entries.append(.activity(UUID(), symbol: "checkmark.circle", text: L("选中了 \(urls.count) 项")))
            return "select: selected \(urls.count) items"
        case .open:
            let urls = call.paths.compactMap { resolve($0) }.prefix(10)
            for url in urls { NSWorkspace.shared.open(url) }
            entries.append(.activity(UUID(), symbol: "arrow.up.forward.app", text: L("打开了 \(urls.count) 个文件")))
            return "open: opened \(urls.count) files"
        default:
            return "\(call.tool.rawValue): needs approval"
        }
    }

    private func execute(_ call: AIToolCall, in workspace: WorkspaceState) async -> (ok: Bool, text: String) {
        do {
            let text = try await AIAgentTools.execute(call, workspace: workspace, resolve: { self.resolve($0) })
            return (true, text)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Absolute, ~/…, or relative to the active tab's folder.
    func resolve(_ raw: String, directory: Bool = false) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || directory else { return nil }
        let base = workspace?.activeTab.url ?? FileManager.default.homeDirectoryForCurrentUser
        let url: URL
        if text.isEmpty { url = base }
        else if text.hasPrefix("/") || text.hasPrefix("~") { url = URL(fileURLWithPath: (text as NSString).expandingTildeInPath) }
        else { url = base.appendingPathComponent(text) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if directory, !isDirectory.boolValue { return nil }
        return url.standardizedFileURL
    }

    // MARK: Describing

    private static func describe(_ call: AIToolCall, base: URL?) -> AIPlan.Step {
        let names = call.paths.map { ($0 as NSString).lastPathComponent }
        let what = names.count == 1 ? "“\(names[0])”" : L("\(names.count) 个项目")
        let target = display(call.to, base: base)
        switch call.tool {
        case .mkdir:
            return .init(call: call, summary: L("新建文件夹 \(display(call.path, base: base))"), detail: [],
                         symbol: "folder.badge.plus", isDestructive: false)
        case .move:
            return .init(call: call, summary: L("把\(what)移到 \(target)"), detail: names, symbol: "arrow.right.doc.on.clipboard",
                         isDestructive: false)
        case .copy:
            return .init(call: call, summary: L("把\(what)拷贝到 \(target)"), detail: names, symbol: "doc.on.doc",
                         isDestructive: false)
        case .rename:
            return .init(call: call, summary: L("把“\((call.path as NSString).lastPathComponent)”改名为“\(call.name)”"), detail: [],
                         symbol: "pencil", isDestructive: false)
        case .trash:
            return .init(call: call, summary: L("把\(what)移到废纸篓"), detail: names, symbol: "trash", isDestructive: true)
        case .tag:
            return .init(call: call, summary: L("给\(what)加上标签“\(call.name)”"), detail: names, symbol: "tag", isDestructive: false)
        case .untag:
            return .init(call: call, summary: L("去掉\(what)的标签“\(call.name)”"), detail: names, symbol: "tag.slash",
                         isDestructive: false)
        case .command:
            let on = names.isEmpty ? "" : L("（对\(what)）")
            return .init(call: call, summary: L("执行命令“\(call.command)”") + on, detail: names, symbol: "command",
                         isDestructive: false)
        default:
            return .init(call: call, summary: call.tool.rawValue, detail: [], symbol: "questionmark", isDestructive: false)
        }
    }

    static func short(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// "“PDF 归档”" for something in the current folder, "~/Documents/…" otherwise.
    static func display(_ raw: String, base: URL?) -> String {
        // /tmp and /private/tmp are the same folder; paths that don't exist yet can't be resolved, so compare by hand.
        func normalized(_ path: String) -> String {
            let clean = URL(fileURLWithPath: path).standardizedFileURL.path
            for root in ["/private/tmp", "/private/var", "/private/etc"] where clean == root || clean.hasPrefix(root + "/") {
                return String(clean.dropFirst("/private".count))
            }
            return clean
        }
        let path = normalized((raw as NSString).expandingTildeInPath)
        if let base = base.map({ normalized($0.path) }), path.hasPrefix(base + "/") {
            return "“" + String(path.dropFirst(base.count + 1)) + "”"
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
