import SwiftUI

/// Clickable breadcrumbs; click the empty area (or ⌘L) to type a path.
struct PathBarView: View {
    let workspace: WorkspaceState
    let tab: TabState
    /// Under the pane's title: the folders above the current one, small (the title names the current one).
    var parentsOnly = false
    var isActive = true

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    @State private var chipWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            if isEditing {
                TextField(L("输入路径，例如 ~/Downloads"), text: $draft)
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
        .frame(height: parentsOnly ? 20 : 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: tab.url) { _, _ in isEditing = false }
        .onChange(of: workspace.pathEditToken) { _, _ in
            if isActive { beginEditing() }
        }
    }

    /// The full path when it fits; otherwise the middle folders collapse into a "…" menu, so the
    /// current folder is always fully visible (like Finder's path bar).
    private var crumbs: some View {
        var all = Self.components(of: tab.url)
        // Above the home folder's title, show where it lives (Macintosh HD › 用户) rather than nothing.
        if parentsOnly, all.count == 1, all[0].symbol == "house.fill" {
            all = Self.components(of: tab.url, stopAtHome: false)
        }
        let parts = parentsOnly ? Array(all.dropLast()) : all
        return ViewThatFits(in: .horizontal) {
            crumbRow(parts, hidden: [])
            ForEach([3, 2, 1], id: \.self) { keep in
                if parts.count > keep + 1 {
                    crumbRow([parts[0]] + parts.suffix(keep), hidden: Array(parts.dropFirst().dropLast(keep)), collapseAfterFirst: true)
                }
            }
            crumbRow(Array(parts.suffix(1)), hidden: Array(parts.dropLast()), collapseAfterFirst: false)
        }
        .padding(.leading, parentsOnly ? -6 : 6)
        .padding(.trailing, 34 + (tab.gitStatus == nil || parentsOnly ? 0 : chipWidth + 6)) // keep the last crumb clear of the buttons
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            // Clicking empty space switches to the text field.
            Color.clear.contentShape(Rectangle()).onTapGesture(count: 1, perform: beginEditing)
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 6) {
                if let status = tab.gitStatus, !tab.isSearchMode, !parentsOnly {
                    GitBranchChip(workspace: workspace, tab: tab, status: status)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipWidth = $0 }
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                Button(action: beginEditing) { Image(systemName: "pencil.line").font(.system(size: parentsOnly ? 10.5 : 13)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help(L("编辑路径"))
            }
            .padding(.trailing, 8)
            .animation(.snappy(duration: 0.25), value: tab.gitStatus?.root)
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
            .font(.system(size: parentsOnly ? 9.5 : 11, weight: .medium))
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
        Crumb(part: part, isLast: isLast && !parentsOnly, compact: compact, small: parentsOnly, workspace: workspace) {
            tab.navigate(to: part.url)
            workspace.focusToken += 1
        }
        .contextMenu {
            Button(L("在新标签页中打开"), systemImage: "plus.square.on.square") { workspace.openInNewTab(part.url) }
            Button(L("在另一窗格中打开"), systemImage: "rectangle.split.2x1") { workspace.openInOtherPane(part.url) }
            Divider()
            Button(L("拷贝路径"), systemImage: "link") { workspace.copyPath([part.url]) }
            Button(L("在终端中打开"), systemImage: "terminal") { workspace.openInTerminal(part.url) }
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
            workspace.alertMessage = L("找不到路径“\(draft)”。")
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
    /// Breadcrumbs by path: working them out reads volume information for every folder up the path, and
    /// the header asks again on every redraw.
    @MainActor private static var componentCache: [String: [Part]] = [:]

    @MainActor static func components(of url: URL, stopAtHome: Bool = true) -> [Part] {
        let key = (stopAtHome ? "h|" : "v|") + url.standardizedFileURL.path
        if let cached = componentCache[key] { return cached }
        let parts = computeComponents(of: url, stopAtHome: stopAtHome)
        if componentCache.count > 300 { componentCache.removeAll() }
        componentCache[key] = parts
        return parts
    }

    private static func computeComponents(of url: URL, stopAtHome: Bool) -> [Part] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        var parts: [Part] = []
        var current = URL(fileURLWithPath: path)
        while true {
            let currentPath = current.path
            if currentPath == home, stopAtHome {
                parts.append(Part(name: L("主目录"), url: current, symbol: "house.fill"))
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
            parts.append(Part(name: Places.displayName(for: current), url: current, symbol: nil))
            current = current.deletingLastPathComponent()
        }
        return parts.reversed()
    }
}

private struct Crumb: View {
    let part: PathBarView.Part
    let isLast: Bool
    var compact = false
    var small = false
    let workspace: WorkspaceState
    let action: () -> Void

    @Environment(\.arborTint) private var tint
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol = part.symbol {
                    Image(systemName: symbol).font(.system(size: small ? 9.5 : 10)).foregroundStyle(dropTargeted ? tint : .secondary)
                }
                if !compact {
                    Text(part.name)
                        .font(.system(size: small ? 11.5 : 12, weight: isLast ? .semibold : .regular))
                        .foregroundStyle(dropTargeted ? AnyShapeStyle(tint) : AnyShapeStyle(isLast ? .primary : .secondary))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, small ? 5 : 6)
            .padding(.vertical, small ? 2 : 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(dropTargeted ? tint.opacity(0.16) : Color.primary.opacity(hovering ? 0.07 : 0)))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(dropTargeted ? tint.opacity(0.6) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(part.url.path)
        .dropDestination(for: URL.self) { urls, _ in
            let copy = NSEvent.modifierFlags.contains(.option)
            FileOperationQueue.shared.transfer(urls, to: part.url, forceCopy: copy) { _, error in
                workspace.report(error)
            }
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}

