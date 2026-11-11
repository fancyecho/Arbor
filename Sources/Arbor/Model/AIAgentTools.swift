import AppKit

/// The prompt, reply schema and context for the agent.
@MainActor
enum AIAgentPrompt {
    static func system(language: String) -> String {
        """
        You are the assistant inside Arbor, a macOS file manager. You help the user find, organize and act on files \
        by calling tools. Each reply is one JSON object: "say" (a short message to the user, in \(language)), "calls" \
        (tools to run now, in order) and "done" (true when nothing more is needed after these calls).

        Tools (every call has all fields; leave the ones a tool doesn't use as "" / [] / empty query):
        Looking around — results come back to you in the next message:
        - list: path → the folder's contents.
        - search: query (+ path as the folder to search, or query.wholeHome) → matching files via Spotlight.
        - info: paths → size, dates, kind, tags, download source.
        - read: path → the text of a file (also PDFs, and text found in images).
        Showing — run immediately:
        - show: paths (or a query) → shows those files as a result list in the current tab; title names it.
        - navigate: path → opens a folder. newTab: path → opens it in a new tab.
        - select: paths → selects them (opening their folder if needed).
        - open: paths → opens files in their default apps.
        Changing files — the user sees these as a plan and must approve; batch every change of a task into one reply,
        in order (mkdir before moving into it):
        - mkdir: path (the new folder's full path). move / copy: paths → to (an existing or just-created folder).
        - rename: path → name (new name with extension). trash: paths. tag / untag: paths, name (a Finder tag).
        - command: command (exact title from the command list) → runs that Arbor command on paths (selected first).

        Rules:
        - Never guess paths. Use list or search first unless the path is in the context. Paths are absolute or start with ~.
        - To answer "find/show me X", search, then show the results (pass the exact paths you found).
        - Don't search again for what a previous result already told you.
        - Arbor can undo every change; still, only trash what the user clearly asked to remove.
        - Be brief: "say" is one or two sentences. Put lists in "show", not in "say".
        - If you only need to answer a question, give the answer in "say" with no calls and done true.

        Query fields: keywords match names and contents (don't repeat words that are a kind or a date); kinds from the \
        enum; extensions without dots; withinDays counts back from today (0 = no limit); after/before YYYY-MM-DD or ""; \
        minMB/maxMB 0 = no limit; downloadedFrom a site such as github.com or ""; wholeHome true to search the whole home folder.
        """
    }

    static func schema() -> [String: Any] {
        let string: [String: Any] = ["type": "string"]
        let strings: [String: Any] = ["type": "array", "items": string]
        let query = AIAssistant.commandSchema()["properties"].flatMap { ($0 as? [String: Any])?["query"] } ?? [:]
        let call: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["tool", "path", "paths", "to", "name", "command", "title", "query"],
            "properties": [
                "tool": ["type": "string", "enum": AIToolCall.Tool.allCases.map(\.rawValue)],
                "path": string, "paths": strings, "to": string, "name": string, "command": string, "title": string,
                "query": query,
            ],
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["say", "calls", "done"],
            "properties": ["say": string, "calls": ["type": "array", "items": call], "done": ["type": "boolean"]],
        ]
    }

    /// Where the user is: folders, selection, what's here, and the commands Arbor has.
    static func context(for workspace: WorkspaceState) -> String {
        let tab = workspace.activeTab
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var lines = [
            "Today: \(AIAssistant.day.string(from: Date()))",
            "Home folder: \(home) (Desktop, Documents, Downloads, Pictures, Movies, Music inside it)",
            "Current folder: \(tab.url.path)\(tab.isSearchMode ? " — showing search results" : "")",
        ]
        if let other = workspace.otherPane?.activeTab.url { lines.append("Other pane: \(other.path)") }
        let selected = tab.selectedItems
        if !selected.isEmpty {
            lines.append("Selected (\(selected.count)): " + selected.prefix(40).map(\.url.path).joined(separator: ", "))
        }
        let items = tab.visibleRows
        lines.append("Shown in the current tab (\(items.count); name | kind | size | modified):")
        for item in items.prefix(120) { lines.append("- " + AIAgentTools.line(item)) }
        if items.count > 120 { lines.append("… and \(items.count - 120) more (use list or search)") }
        let commands = PaletteCommands.all(workspace).filter { $0.kind == .command }.map(\.title)
        lines.append("Commands (for the command tool): " + commands.joined(separator: " | "))
        return lines.joined(separator: "\n")
    }

    static func call(from object: [String: Any]) -> AIToolCall? {
        guard let raw = object["tool"] as? String, let tool = AIToolCall.Tool(rawValue: raw) else { return nil }
        var call = AIToolCall(tool: tool)
        call.path = object["path"] as? String ?? ""
        call.paths = (object["paths"] as? [String] ?? []).filter { !$0.isEmpty }
        call.to = object["to"] as? String ?? ""
        call.name = object["name"] as? String ?? ""
        call.command = object["command"] as? String ?? ""
        call.title = object["title"] as? String ?? ""
        if let query = object["query"] as? [String: Any],
           let parsed = try? AIAssistant.command(from: ["action": "search", "query": query]) {
            call.query = parsed.query
        }
        return call
    }
}

enum AIErrorText: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}

/// What the agent's tools actually do.
@MainActor
enum AIAgentTools {
    nonisolated static func line(_ item: FileItem) -> String {
        let size = item.isNavigable ? "folder" : Format.bytes(item.size)
        let date = item.modified.map(AIAssistant.day.string(from:)) ?? ""
        return "\(item.url.path) | \(item.localizedKind) | \(size) | \(date)"
    }

    /// Off the main thread: reading another app's container can stop for a privacy prompt.
    static func list(_ folder: URL) async -> String {
        await Task.detached(priority: .userInitiated) {
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: FileItem.resourceKeys,
                                                                   options: [.skipsHiddenFiles])
            } catch {
                return "(can't read this folder: \(error.localizedDescription))"
            }
            let items = urls.map(FileItem.init(url:)).sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            var lines = items.prefix(150).map(line)
            if items.count > 150 { lines.append("… and \(items.count - 150) more (search to narrow down)") }
            return lines.isEmpty ? "(empty)" : lines.joined(separator: "\n")
        }.value
    }

    /// Spotlight, newest first; waits up to a few seconds for the first results.
    static func search(_ predicate: NSPredicate, in scope: URL) async throws -> [FileItem] {
        let once = OneShotSearch()
        let urls = await once.run(predicate, scope: scope)
        if let failure = once.failure { throw failure }
        return await Task.detached(priority: .userInitiated) { urls.prefix(300).map(FileItem.init(url:)) }.value
    }

    static func info(_ urls: [URL]) async -> String {
        let scanned = urls.map { SpaceIndex.shared.folderSize($0) }
        return await Task.detached(priority: .userInitiated) {
            zip(urls, scanned).map { url, folderSize in
                let item = FileItem(url: url)
                var parts = [line(item)]
                if let added = item.added { parts.append("added \(AIAssistant.day.string(from: added))") }
                if !item.tagNames.isEmpty { parts.append("tags: " + item.tagNames.joined(separator: ", ")) }
                if let froms = NSMetadataItem(url: url)?.value(forAttribute: "kMDItemWhereFroms") as? [String], !froms.isEmpty {
                    parts.append("downloaded from: " + froms.prefix(2).joined(separator: " "))
                }
                if item.isNavigable, let folderSize { parts.append("folder size \(Format.bytes(folderSize))") }
                return parts.joined(separator: " | ")
            }.joined(separator: "\n")
        }.value
    }

    // MARK: Changing files

    /// Runs one approved step. Every change is recorded so ⌘Z undoes it.
    static func execute(_ call: AIToolCall, workspace: WorkspaceState, resolve: (String) -> URL?) async throws -> String {
        let fm = FileManager.default
        func sources() throws -> [URL] {
            let urls = call.paths.compactMap(resolve)
            guard !urls.isEmpty else { throw AIErrorText.message(L("找不到要处理的文件")) }
            return urls
        }
        switch call.tool {
        case .mkdir:
            let path = (call.path as NSString).expandingTildeInPath
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : workspace.activeTab.url.appendingPathComponent(path)
            if fm.fileExists(atPath: url.path) { return "mkdir: \(url.path) already exists" }
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            FileHistory.shared.record(L("新建文件夹"), steps: [.trash(url)])
            return "mkdir: created \(url.path)"
        case .move, .copy:
            let items = try sources()
            guard let destination = resolve(call.to) else { throw AIErrorText.message(L("找不到目标文件夹“\(call.to)”")) }
            let created: [URL] = try await withCheckedThrowingContinuation { continuation in
                let done: ([URL], Error?) -> Void = { urls, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: urls) }
                }
                if call.tool == .move {
                    FileOperationQueue.shared.move(items, to: destination, completion: done)
                } else {
                    FileOperationQueue.shared.copy(items, to: destination, completion: done)
                }
            }
            return "\(call.tool.rawValue): \(created.count) items now in \(destination.path)"
        case .rename:
            guard let url = resolve(call.path) else { throw AIErrorText.message(L("找不到“\(call.path)”")) }
            let name = call.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let problem = BatchRenamer.problems(urls: [url], newNames: [name]).first ?? nil {
                throw AIErrorText.message(problem.message)
            }
            let renamed = try BatchRenamer.perform(urls: [url], newNames: [name])
            FileHistory.shared.record(L("重命名"), steps: UndoExecutor.renameSteps([(from: url, to: url.deletingLastPathComponent().appendingPathComponent(name))]))
            return "rename: now \(renamed.first?.path ?? name)"
        case .trash:
            let items = try sources()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                FileOperationQueue.shared.trash(items) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            return "trash: moved \(items.count) items to the Trash"
        case .tag, .untag:
            let items = try sources()
            let tag = call.name.trimmingCharacters(in: .whitespaces)
            guard !tag.isEmpty else { throw AIErrorText.message(L("没有说明是哪个标签")) }
            for url in items {
                var tags = FinderTags.tags(of: url)
                if call.tool == .tag { if !tags.contains(tag) { tags.append(tag) } } else { tags.removeAll { $0 == tag } }
                try FinderTags.setTags(tags, on: url)
            }
            return "\(call.tool.rawValue): \(items.count) items"
        case .command:
            let commands = PaletteCommands.all(workspace).filter { $0.kind == .command }
            guard let command = commands.first(where: { $0.title == call.command })
                    ?? commands.first(where: { $0.title.localizedCaseInsensitiveContains(call.command) }) else {
                throw AIErrorText.message(L("没有叫“\(call.command)”的命令"))
            }
            let urls = call.paths.compactMap(resolve)
            if !urls.isEmpty {
                let tab = workspace.activeTab
                let shown = Set(tab.visibleRows.map(\.url.standardizedFileURL.path))
                if !urls.allSatisfy({ shown.contains($0.path) }), let parent = urls.first?.deletingLastPathComponent() {
                    tab.navigate(to: parent)
                    try? await Task.sleep(for: .milliseconds(300))
                }
                tab.selection = Set(urls)
            }
            // Outside the task: a command may open a sheet or a panel with its own event loop.
            let action = command.action
            DispatchQueue.main.async { action() }
            return "command: ran “\(command.title)”"
        default:
            return ""
        }
    }
}

/// One Spotlight query that answers once (its first gathered results, or nothing after a timeout).
@MainActor
private final class OneShotSearch {
    private var search: SpotlightSearch?
    private var continuation: CheckedContinuation<[URL], Never>?
    private(set) var failure: Error?

    func run(_ predicate: NSPredicate, scope: URL) async -> [URL] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            search = SpotlightSearch(predicate: predicate, scopes: [scope]) { [weak self] urls in self?.finish(urls) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.finish([]) }
        }
    }

    private func finish(_ urls: [URL]) {
        guard let continuation else { return }
        self.continuation = nil
        failure = search?.failure
        search?.stop()
        search = nil
        continuation.resume(returning: urls)
    }
}
