import SwiftUI

/// ⌘K: one box for commands, smart folder jumps (frecency), typed paths, workspaces and custom commands.
/// ↩ runs / goes, ⌘↩ opens a folder in a new tab, ⌥↩ in the other pane, ⇥ completes a path.
struct CommandPalette: View {
    @Environment(\.arborTint) private var tint
    let workspace: WorkspaceState

    @State private var query = ""
    @State private var selected = 0
    @State private var results: [PaletteItem] = []
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture(perform: close)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: isPathQuery ? "folder" : "magnifyingglass")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                    TextField("输入命令、文件夹名称或路径（支持拼音）", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .focused($focused)
                        .onSubmit { execute(results.indices.contains(selected) ? results[selected] : nil) }
                        .onKeyPress(.upArrow) { move(-1) }
                        .onKeyPress(.downArrow) { move(1) }
                        .onKeyPress(.tab) { complete() }
                        .onKeyPress(.escape) { close(); return .handled }
                }
                .padding(.horizontal, 16)
                .frame(height: 52)

                if !results.isEmpty {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                    PaletteRow(item: item, isSelected: index == selected)
                                        .id(index)
                                        .onTapGesture { execute(item) }
                                        .onHover { if $0 { selected = index } }
                                }
                            }
                            .padding(6)
                            .slimScrollers(tint)
                        }
                        .frame(maxHeight: 380)
                        .onChange(of: selected) { _, index in proxy.scrollTo(index) }
                    }
                }

                Divider()
                HStack(spacing: 14) {
                    hint("↩", "执行 / 前往")
                    hint("⌘↩", "新标签页")
                    hint("⌥↩", "另一窗格")
                    hint("⇥", "补全路径")
                    Spacer()
                    hint("esc", "关闭")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(height: 28)
            }
            .frame(width: 620)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
            .padding(.top, 70)
        }
        .onAppear {
            focused = true
            refresh()
        }
        .onChange(of: query) { _, _ in refresh() }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).fontWeight(.semibold)
            Text(text)
        }
    }

    // MARK: Results

    private var isPathQuery: Bool { query.hasPrefix("/") || query.hasPrefix("~") }

    private func refresh() {
        results = isPathQuery ? pathResults() : rankedResults()
        selected = 0
    }

    private func rankedResults() -> [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var items: [PaletteItem] = []

        // Folders: frecency history, favorites and the current folder's subfolders.
        let frecency = Frecency.shared.ranked()
        let maxFrecency = frecency.first?.score ?? 1
        var candidates: [(String, Double)] = frecency.prefix(400).map { ($0.path, $0.score / maxFrecency) }
        candidates += SidebarStore.shared.favorites.map { ($0.path, 0.15) }
        candidates += workspace.activeTab.items.filter(\.isNavigable).map { ($0.url.standardizedFileURL.path, 0.1) }
        var seen = Set<String>()
        for (path, weight) in candidates where seen.insert(path).inserted {
            guard path != workspace.activeTab.url.standardizedFileURL.path else { continue }
            let match: Double
            if q.isEmpty {
                guard weight > 0.15 || items.count < 6 else { continue }
                match = 0.6
            } else {
                guard let s = Fuzzy.pathScore(q, path) else { continue }
                match = s
            }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)
            items.append(PaletteItem(
                id: "dir:" + path, kind: .folder, title: Places.displayName(for: url),
                subtitle: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                symbol: Places.symbol(for: url), score: match * 0.85 + min(weight, 1) * 0.3, url: url
            ) { workspace.go(to: url) })
        }
        if q.isEmpty { items = Array(items.sorted { $0.score > $1.score }.prefix(6)) }

        let commands = PaletteCommands.all(workspace) + PaletteCommands.workspaces(workspace)
            + PaletteCommands.customCommands(workspace)
        for var item in commands {
            if q.isEmpty {
                item.score = 0.1
            } else {
                guard let s = Fuzzy.score(q, item.title) else { continue }
                item.score = s + (item.kind == .workspace ? 0.05 : 0)
            }
            items.append(item)
        }
        return Array(items.sorted { $0.score == $1.score ? $0.kind.rawValue < $1.kind.rawValue : $0.score > $1.score }.prefix(60))
    }

    /// "~/Doc" → subfolders of ~ starting with "Doc"; "~/Documents/" → everything inside.
    private func pathResults() -> [PaletteItem] {
        let expanded = (query as NSString).expandingTildeInPath
        let endsWithSlash = query.hasSuffix("/")
        let parent = endsWithSlash ? URL(fileURLWithPath: expanded) : URL(fileURLWithPath: expanded).deletingLastPathComponent()
        let prefix = endsWithSlash ? "" : URL(fileURLWithPath: expanded).lastPathComponent
        var items: [PaletteItem] = []

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) {
            let url = URL(fileURLWithPath: expanded)
            items.append(PaletteItem(id: "go:" + expanded, kind: .path,
                                     title: isDirectory.boolValue ? "前往“\(url.lastPathComponent)”" : "显示“\(url.lastPathComponent)”",
                                     subtitle: (expanded as NSString).abbreviatingWithTildeInPath,
                                     symbol: "arrow.right.circle", score: 2, url: isDirectory.boolValue ? url : nil) {
                workspace.go(to: url)
            })
        }

        let children = (try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: [])) ?? []
        let matches = children
            .filter { TabState.resolvedDirectory($0) != nil }
            .filter { prefix.hasPrefix(".") || !$0.lastPathComponent.hasPrefix(".") }
            .filter { prefix.isEmpty || $0.lastPathComponent.lowercased().hasPrefix(prefix.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(40)
        for url in matches where !url.isSameFile(as: URL(fileURLWithPath: expanded)) {
            items.append(PaletteItem(id: "sub:" + url.path, kind: .folder, title: url.lastPathComponent,
                                     subtitle: (url.path as NSString).abbreviatingWithTildeInPath,
                                     symbol: Places.symbol(for: url), url: url) { workspace.go(to: url) })
        }
        return items
    }

    // MARK: Keys

    private func move(_ step: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        selected = (selected + step + results.count) % results.count
        return .handled
    }

    private func complete() -> KeyPress.Result {
        guard results.indices.contains(selected), let url = results[selected].url else { return .handled }
        query = (url.path as NSString).abbreviatingWithTildeInPath + "/"
        return .handled
    }

    private func execute(_ item: PaletteItem?) {
        guard let item else { return }
        let flags = NSEvent.modifierFlags
        close()
        if let url = item.url, item.kind == .folder || item.kind == .path {
            if flags.contains(.command) {
                workspace.openInNewTab(url)
                return
            }
            if flags.contains(.option) {
                workspace.openInOtherPane(url)
                return
            }
        }
        item.action()
    }

    private func close() {
        workspace.showPalette = false
        workspace.focusToken += 1
    }
}

private struct PaletteRow: View {
    @Environment(\.arborTint) private var tint
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .font(.system(size: 14))
                .frame(width: 22)
                .foregroundStyle(isSelected ? Color.white : (item.kind == .folder || item.kind == .path ? tint : .secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
            }
        }
        .foregroundStyle(isSelected ? Color.white : .primary)
        .padding(.horizontal, 10)
        .frame(height: item.subtitle == nil ? 32 : 40)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isSelected ? tint : .clear))
        .contentShape(Rectangle())
    }
}
