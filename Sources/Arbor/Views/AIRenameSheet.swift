import AppKit
import SwiftUI

/// "用 AI 重命名": reads each file on this Mac (text, PDF text, text in images), asks your model for
/// names that say what's inside, and shows them for review. Nothing is renamed until you apply.
struct AIRenameSheet: View {
    let workspace: WorkspaceState
    let urls: [URL]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.arborTint) private var tint
    @State private var names: [String] = []
    @State private var accepted: Set<Int> = []
    @State private var thinking = false
    @State private var error: String?
    @State private var hint = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(tint)
                Text(L("用 AI 重命名")).font(.headline)
                Spacer()
                Text(L("\(urls.count) 个文件")).foregroundStyle(.secondary).font(.callout)
            }
            HStack(spacing: 8) {
                TextField(L("可选：命名要求，比如“用英文”“加上日期”“按发票抬头命名”"), text: $hint)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(generate)
                Button(names.isEmpty ? L("生成") : L("重新生成"), action: generate)
                    .disabled(thinking)
            }
            list
                .overlay {
                    if thinking {
                        VStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(L("正在读取文件内容并起名…")).font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .lineLimit(3)
            }
            Text(L("文件名和读取到的内容摘要会发送给你设置的模型（\(AppSettings.shared.aiConfig.model)）。"))
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button(L("取消")) { task?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("重命名 \(changes.count) 个文件"), action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(changes.isEmpty || thinking || hasProblems)
            }
        }
        .padding(18)
        .frame(width: 640, height: 480)
        .overlay {
            AIGlowBorder(cornerRadius: 12, lineWidth: 1.5, spread: 0.7, active: thinking)
                .opacity(thinking ? 1 : 0)
                .animation(.easeInOut(duration: 0.5), value: thinking)
        }
        .onAppear(perform: generate)
        .onDisappear { task?.cancel() }
    }

    private var list: some View {
        let problems = BatchRenamer.problems(urls: urls, newNames: finalNames)
        return List {
            ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { accepted.contains(index) },
                        set: { on in if on { accepted.insert(index) } else { accepted.remove(index) } }))
                        .labelsHidden()
                        .disabled(names.count <= index)
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().frame(width: 18, height: 18)
                    Text(url.lastPathComponent)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .frame(width: 210, alignment: .leading)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                    if names.count > index {
                        TextField("", text: Binding(get: { names[index] }, set: { names[index] = $0 }))
                            .textFieldStyle(.plain)
                            .foregroundStyle(problems[index] != nil && accepted.contains(index) ? Color.red : Color.primary)
                            .help(problems[index]?.message ?? "")
                    } else {
                        RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)).frame(height: 14)
                    }
                }
                .font(.system(size: 12))
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
    }

    /// New name where accepted, the old one otherwise.
    private var finalNames: [String] {
        urls.enumerated().map { index, url in
            accepted.contains(index) && names.count > index ? names[index] : url.lastPathComponent
        }
    }

    private var changes: [Int] {
        accepted.filter { names.count > $0 && names[$0] != urls[$0].lastPathComponent }.sorted()
    }

    private var hasProblems: Bool {
        BatchRenamer.problems(urls: urls, newNames: finalNames).enumerated().contains { accepted.contains($0.offset) && $0.element != nil }
    }

    private func generate() {
        guard !thinking else { return }
        let config = AppSettings.shared.aiConfig
        guard config.isUsable else {
            error = AIError.notConfigured.localizedDescription
            return
        }
        error = nil
        thinking = true
        workspace.aiThinking = true
        let language = Localization.isEnglish ? "English" : "Simplified Chinese"
        let style = hint.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "The user asks: " + hint
        let urls = self.urls
        task = Task {
            defer {
                thinking = false
                workspace.aiThinking = false
            }
            do {
                let described = await AIAssistant.describe(urls)
                guard !Task.isCancelled else { return }
                let object = try await AIClient.json(system: AIAssistant.renamePrompt(language: language, style: style),
                                                     user: described, schema: AIAssistant.renameSchema(), config: config,
                                                     maxTokens: 4096)
                guard !Task.isCancelled else { return }
                let proposed = AIAssistant.names(from: object, for: urls)
                withAnimation(.snappy) {
                    names = zip(urls, proposed).map { $1 ?? $0.lastPathComponent }
                    accepted = Set(proposed.indices.filter { proposed[$0] != nil && proposed[$0] != urls[$0].lastPathComponent })
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func apply() {
        let tab = workspace.activeTab
        let newNames = finalNames
        do {
            let renamed = try BatchRenamer.perform(urls: urls, newNames: newNames)
            let pairs = zip(urls, newNames).filter { $0.lastPathComponent != $1 }
                .map { (from: $0, to: $0.deletingLastPathComponent().appendingPathComponent($1)) }
            FileHistory.shared.record(L("用 AI 重命名"), steps: UndoExecutor.renameSteps(pairs))
            tab.reload(selecting: Set(renamed))
            dismiss()
        } catch {
            workspace.report(error)
        }
    }
}
