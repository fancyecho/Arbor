import SwiftUI

/// Names a new saved workspace, or renames an existing one.
struct WorkspaceNameSheet: View {
    let workspace: WorkspaceState
    let request: WorkspaceNameRequest

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color: WorkspaceTint = .indigo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isRename ? L("重命名工作区") : L("存储为工作区")).font(.headline)
            if !isRename {
                Text(L("保存当前的窗格、标签页和路径，之后可从侧边栏或「工作区」菜单一键切换。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(L("名称"), text: $name, prompt: Text(L("例如：写论文、整理照片")))
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            if !isRename {
                HStack(spacing: 8) {
                    Text(L("颜色")).foregroundStyle(.secondary)
                    ForEach(WorkspaceTint.allCases) { tint in
                        Button { color = tint } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(tint.color.gradient)
                                .frame(width: 22, height: 22)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(.white, lineWidth: color == tint ? 2 : 0)
                                }
                                .shadow(color: tint.color.opacity(color == tint ? 0.5 : 0), radius: 3)
                        }
                        .buttonStyle(.plain)
                        .help(tint.title)
                        .accessibilityLabel(tint.title)
                    }
                }
                Text(L("切换到这个工作区时，整个窗口会变成这个颜色。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L("取消"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isRename ? L("重命名") : L("存储"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            switch request {
            case .save:
                name = workspace.activeTab.title
                color = workspace.suggestedNewWorkspaceTint
            case .rename(let saved): name = saved.name
            }
        }
    }

    private var isRename: Bool {
        if case .rename = request { return true }
        return false
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func commit() {
        guard !trimmed.isEmpty else { return }
        switch request {
        case .save: withAnimation(.easeInOut(duration: 0.35)) { workspace.saveWorkspace(named: trimmed, color: color) }
        case .rename(let saved): WorkspaceLibrary.shared.rename(saved.id, to: trimmed)
        }
        dismiss()
    }
}
