import SwiftUI

/// Clickable breadcrumbs; click the empty area (or ⌘L) to type a path.
struct PathBarView: View {
    let workspace: WorkspaceState
    let tab: TabState

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if isEditing {
                TextField("输入路径，例如 ~/Downloads", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onExitCommand { isEditing = false }
                    .onChange(of: fieldFocused) { _, focused in if !focused { isEditing = false } }
                    .padding(.horizontal, 10)
            } else {
                crumbs
            }
        }
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: tab.url) { _, _ in isEditing = false }
    }

    /// The full path when it fits; otherwise the middle folders collapse into a "…" menu, so the
    /// current folder is always fully visible (like Finder's path bar).
    private var crumbs: some View {
        let parts = Self.components(of: tab.url)
        return ViewThatFits(in: .horizontal) {
            crumbRow(parts, hidden: [])
            ForEach([3, 2, 1], id: \.self) { keep in
                if parts.count > keep + 1 {
                    crumbRow([parts[0]] + parts.suffix(keep), hidden: Array(parts.dropFirst().dropLast(keep)), collapseAfterFirst: true)
                }
            }
            crumbRow(Array(parts.suffix(1)), hidden: Array(parts.dropLast()), collapseAfterFirst: false)
        }
        .padding(.leading, 6)
        .padding(.trailing, 34) // keep the last crumb clear of the edit button
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            // Clicking empty space switches to the text field.
            Color.clear.contentShape(Rectangle()).onTapGesture(count: 1, perform: beginEditing)
        }
        .overlay(alignment: .trailing) {
            Button(action: beginEditing) { Image(systemName: "pencil.line") }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("编辑路径")
                .padding(.trailing, 8)
        }
    }

    private func crumbRow(_ shown: [Part], hidden: [Part], collapseAfterFirst: Bool = false) -> some View {
        HStack(spacing: 1) {
            if !hidden.isEmpty && !collapseAfterFirst { collapsed(hidden); separator }
            ForEach(Array(shown.enumerated()), id: \.offset) { index, part in
                if index > 0 { separator }
                if index == 1, collapseAfterFirst, !hidden.isEmpty { collapsed(hidden); separator }
                // When collapsed, the root (🏠 / disk) shrinks to its icon to leave room for the path's end.
                crumb(part, isLast: index == shown.count - 1, compact: index == 0 && collapseAfterFirst && part.symbol != nil)
            }
        }
        .fixedSize()
    }

    private var separator: some View {
        Image(systemName: "chevron.compact.right")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
    }

    /// "…" with the folders that didn't fit.
    private func collapsed(_ parts: [Part]) -> some View {
        Menu {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Button(part.name, systemImage: part.symbol ?? "folder") {
                    tab.navigate(to: part.url)
                    workspace.focusToken += 1
                }
            }
        } label: {
            Text("…").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(parts.map(\.name).joined(separator: " › "))
    }

    private func crumb(_ part: Part, isLast: Bool, compact: Bool = false) -> some View {
        Crumb(part: part, isLast: isLast, compact: compact) {
            tab.navigate(to: part.url)
            workspace.focusToken += 1
        }
        .contextMenu {
            Button("在新标签页中打开", systemImage: "plus.square.on.square") { workspace.openInNewTab(part.url) }
            Button("在另一窗格中打开", systemImage: "rectangle.split.2x1") { workspace.openInOtherPane(part.url) }
            Divider()
            Button("拷贝路径", systemImage: "link") { workspace.copyPath([part.url]) }
            Button("在终端中打开", systemImage: "terminal") { workspace.openInTerminal(part.url) }
        }
    }

    private func beginEditing() {
        draft = (tab.url.path as NSString).abbreviatingWithTildeInPath
        isEditing = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commit() {
        let path = (draft.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            workspace.alertMessage = "找不到路径“\(draft)”。"
            return
        }
        isEditing = false
        workspace.go(to: URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue))
    }

    struct Part {
        let name: String
        let url: URL
        let symbol: String?
    }

    /// Paths inside the home folder start at 🏠, others at the volume.
    static func components(of url: URL) -> [Part] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        var parts: [Part] = []
        var current = URL(fileURLWithPath: path)
        while true {
            let currentPath = current.path
            if currentPath == home {
                parts.append(Part(name: NSUserName(), url: current, symbol: "house.fill"))
                break
            }
            if currentPath == "/" {
                let volume = (try? current.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "/"
                parts.append(Part(name: volume, url: current, symbol: "internaldrive.fill"))
                break
            }
            if let values = try? current.resourceValues(forKeys: [.isVolumeKey, .volumeLocalizedNameKey]), values.isVolume == true {
                parts.append(Part(name: values.volumeLocalizedName ?? current.lastPathComponent, url: current, symbol: "externaldrive.fill"))
                break
            }
            parts.append(Part(name: FileManager.default.displayName(atPath: currentPath), url: current, symbol: nil))
            current = current.deletingLastPathComponent()
        }
        return parts.reversed()
    }
}

private struct Crumb: View {
    let part: PathBarView.Part
    let isLast: Bool
    var compact = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol = part.symbol {
                    Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if !compact {
                    Text(part.name)
                        .font(.system(size: 12, weight: isLast ? .semibold : .regular))
                        .foregroundStyle(isLast ? .primary : .secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(part.url.path)
        .dropDestination(for: URL.self) { urls, _ in
            FileOperationQueue.shared.transfer(urls, to: part.url) { _, _ in }
            return true
        }
    }
}

