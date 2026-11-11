import AppKit
import SwiftUI

/// The branch of the repository a tab is in, at the end of the path bar: "⎇ main  ↑1  ● 3".
/// Clicking it lists the changed files.
struct GitBranchChip: View {
    let workspace: WorkspaceState
    let tab: TabState
    let status: GitRepoStatus

    @Environment(\.arborTint) private var tint
    @State private var showsChanges = false

    var body: some View {
        Button { showsChanges.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10, weight: .semibold))
                Text(status.branch ?? "?")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 120)
                if status.ahead > 0 { Text("↑\(status.ahead)").foregroundStyle(tint) }
                if status.behind > 0 { Text("↓\(status.behind)").foregroundStyle(.orange) }
                let count = status.changeCount
                if count > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(Color.orange).frame(width: 5, height: 5)
                        Text("\(count)")
                    }
                    .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("Git 仓库：\((status.root as NSString).abbreviatingWithTildeInPath)。点按查看改动和标记说明"))
        .popover(isPresented: $showsChanges, arrowEdge: .bottom) {
            GitChangesPopover(workspace: workspace, tab: tab, status: status) { showsChanges = false }
        }
    }
}

private struct GitChangesPopover: View {
    let workspace: WorkspaceState
    let tab: TabState
    let status: GitRepoStatus
    let dismiss: () -> Void

    @Environment(\.arborTint) private var tint

    var body: some View {
        let changes = status.changes
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.branch ?? "?").font(.headline)
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if changes.isEmpty {
                Label(L("工作区是干净的"), systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(changes.prefix(300), id: \.path) { entry in
                            row(entry.path, entry.change)
                        }
                    }
                }
                .frame(maxHeight: 280)
                if changes.count > 300 {
                    Text(L("还有 \(changes.count - 300) 项")).font(.caption).foregroundStyle(.tertiary)
                }
            }
            GitLegend()
            Divider()
            HStack(spacing: 8) {
                Button(L("打开仓库"), systemImage: "folder") {
                    tab.navigate(to: URL(fileURLWithPath: status.root, isDirectory: true))
                    dismiss()
                }
                Button(L("在终端中打开"), systemImage: "terminal") {
                    workspace.openInTerminal(URL(fileURLWithPath: status.root, isDirectory: true))
                    dismiss()
                }
                Button(L("拷贝分支名"), systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(status.branch ?? "", forType: .string)
                    dismiss()
                }
            }
            .buttonStyle(.glassCompact)
        }
        .padding(14)
        .frame(width: 360)
    }

    private var summary: String {
        var parts: [String] = []
        let count = status.changeCount
        parts.append(count == 0 ? L("没有改动") : L("\(count) 项改动"))
        if status.ahead > 0 { parts.append(L("领先 \(status.ahead) 个提交")) }
        if status.behind > 0 { parts.append(L("落后 \(status.behind) 个提交")) }
        if !status.hasUpstream, !status.detached { parts.append(L("没有上游分支")) }
        return parts.joined(separator: " · ")
    }

    private func row(_ path: String, _ change: GitChange) -> some View {
        let url = URL(fileURLWithPath: status.root).appendingPathComponent(path)
        let name = (path.hasSuffix("/") ? String(path.dropLast()) : path) as NSString
        return Button {
            guard change != .deleted else { return }
            tab.navigate(to: url.deletingLastPathComponent(), select: url)
            workspace.focusToken += 1
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Text(change.letter)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(nsColor: change.color))
                    .frame(width: 14)
                Text(name.lastPathComponent).lineLimit(1)
                let folder = name.deletingLastPathComponent
                if !folder.isEmpty {
                    Text(folder).lineLimit(1).truncationMode(.head).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .help(change.title)
    }
}

/// What the marks in the list mean, in one glance.
struct GitLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("列表里的标记")).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading),
                           GridItem(.flexible(), alignment: .leading)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
                ForEach([GitChange.modified, .added, .untracked, .deleted, .renamed, .conflicted], id: \.self) { change in
                    HStack(spacing: 5) {
                        Text(change.letter)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(nsColor: change.color))
                            .frame(width: 12)
                        Text(change.title)
                    }
                }
                HStack(spacing: 5) {
                    Text("●").font(.system(size: 9)).foregroundStyle(.orange).frame(width: 12)
                    Text(L("文件夹里有改动"))
                }
                HStack(spacing: 5) {
                    Text("Aa").font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 12)
                    Text(L("淡色：已忽略"))
                }
            }
            .font(.system(size: 11))
            Text(L("改动相对于最近一次提交；选中文件后，检查器里会显示具体改了哪几行。"))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }
}

/// Rows in a popover that light up under the pointer.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.arborTint) private var tint

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.22 : hovering ? 0.12 : 0)))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Inspector

/// What changed in a file since the last commit, as a colored diff in the inspector.
struct GitDiffSection: View {
    let item: FileItem

    @Environment(\.arborTint) private var tint
    @State private var lines: [DiffLine]?
    @State private var expanded = true

    struct DiffLine: Identifiable {
        let id: Int
        let text: String
        let kind: Kind
        enum Kind { case added, removed, hunk, context }
    }

    var body: some View {
        let mark = GitIndex.shared.mark(for: item.url, isFolder: item.isDirectory)
        Group {
            if case .item(let change) = mark, change != .ignored, !item.isDirectory {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(change.letter)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: change.color)))
                        Text("Git · " + change.title).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if let lines {
                            let added = lines.filter { $0.kind == .added }.count
                            let removed = lines.filter { $0.kind == .removed }.count
                            Text("+\(added)").foregroundStyle(.green)
                            Text("−\(removed)").foregroundStyle(.red)
                        }
                        if lines?.isEmpty == false {
                            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                                Image(systemName: "chevron.right")
                                    .rotationEffect(.degrees(expanded ? 90 : 0))
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    if change == .untracked {
                        Text(L("新文件，还没有加入 Git。")).font(.caption).foregroundStyle(.secondary)
                    } else if let lines, expanded, !lines.isEmpty {
                        diffBody(lines)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                .task(id: "\(item.url.path)|\(GitIndex.shared.revision)") { await load(change) }
            }
        }
    }

    private func diffBody(_ lines: [DiffLine]) -> some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines.prefix(600)) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(color(line.kind))
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line.kind))
                }
            }
            .textSelection(.enabled)
        }
        .frame(maxHeight: 260)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func color(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: .green
        case .removed: .red
        case .hunk: tint
        case .context: .secondary
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: .green.opacity(0.08)
        case .removed: .red.opacity(0.08)
        case .hunk: tint.opacity(0.08)
        case .context: .clear
        }
    }

    private func load(_ change: GitChange) async {
        guard change != .untracked, let root = GitIndex.shared.repoRoot(for: item.url.deletingLastPathComponent()) else {
            lines = nil
            return
        }
        let output = await GitIndex.diff(of: item.url, root: root) ?? ""
        guard !Task.isCancelled else { return }
        lines = Self.parse(output)
    }

    static func parse(_ diff: String) -> [DiffLine] {
        var result: [DiffLine] = []
        var started = false
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") { started = true }
            guard started else { continue } // skip the "diff --git / index / ---/+++" header
            let kind: DiffLine.Kind = line.hasPrefix("@@") ? .hunk
                : line.hasPrefix("+") ? .added : line.hasPrefix("-") ? .removed : .context
            if line.hasPrefix("\\") { continue } // "\ No newline at end of file"
            result.append(DiffLine(id: result.count, text: line, kind: kind))
        }
        return result
    }
}
