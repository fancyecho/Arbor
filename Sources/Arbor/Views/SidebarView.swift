import SwiftUI

struct SidebarView: View {
    let workspace: WorkspaceState
    private let volumes = VolumeList.shared
    private let store = SidebarStore.shared
    private let library = WorkspaceLibrary.shared

    @Environment(\.arborTint) private var tint

    var body: some View {
        VStack(spacing: 0) {
            list
                .contentMargins(.top, 10, for: .scrollContent)
                .contentMargins(.bottom, 8, for: .scrollContent)
                // Rows dissolve into the card's edges instead of being cut off by them.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 12)
                    }
                }
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1).padding(.horizontal, 14)
            tintPicker
        }
    }

    private var list: some View {
        List {
            Section(isExpanded: expanded("favorites")) {
                ForEach(Array(store.favorites.enumerated()), id: \.element.id) { index, favorite in
                    row(Place(name: favorite.name, url: favorite.url, symbol: favorite.symbol), dimmed: !favorite.exists) {
                        Divider()
                        Button("从边栏中移除", systemImage: "minus.circle") { store.removeFavorite(favorite) }
                    }
                    .background { if index == 0 { SlimScrollers(tint: tint).frame(width: 0, height: 0) } }
                }
                .onMove { store.moveFavorites(from: $0, to: $1) }
                // Dropping a folder *between* rows adds it as a favorite.
                .onInsert(of: [.fileURL]) { index, providers in
                    loadFileURLs(providers) { urls in
                        for (offset, url) in urls.enumerated() { store.addFavorite(url, at: index + offset) }
                    }
                }
            } header: {
                Text("个人收藏")
                    .contextMenu {
                        Button("恢复默认收藏") { store.resetFavorites() }
                    }
            }

            Section(isExpanded: expanded("workspaces")) {
                ForEach(library.saved) { saved in workspaceRow(saved) }
                    .onMove { library.move(from: $0, to: $1) }
                Label {
                    Text(library.saved.isEmpty ? "把当前布局存为工作区…" : "存储当前布局…")
                } icon: {
                    Image(systemName: "plus.circle")
                }
                .foregroundStyle(.secondary)
                .modifier(SidebarRowStyle(isSelected: false) { workspace.workspaceNameRequest = .save })
                .help("工作区 = 一组存好的窗格、标签页和颜色。比如“写论文”同时打开论文和参考文献，“整理照片”打开相册和导出文件夹，点一下就切过去。")
            } header: {
                Text("工作区")
            }

            let recents = recentPlaces
            if !recents.isEmpty {
                Section(isExpanded: expanded("recents")) {
                    ForEach(recents, id: \.url) { row($0) }
                } header: {
                    Text("最近")
                        .contextMenu {
                            Button("清除最近位置") { store.clearRecents() }
                        }
                }
            }

            if let iCloud = Places.iCloudDrive {
                Section(isExpanded: expanded("icloud")) { row(iCloud) } header: { Text("iCloud") }
            }

            Section(isExpanded: expanded("tags")) {
                ForEach(FinderTags.standard, id: \.name) { tag in
                    Label {
                        Text(tag.name)
                    } icon: {
                        Image(nsImage: FinderTags.dot(tag.color, size: 11))
                    }
                    .modifier(SidebarRowStyle(isSelected: workspace.activeTab.tagQuery == tag.name) {
                        workspace.showTag(tag.name)
                    })
                    .dropDestination(for: URL.self) { urls, _ in
                        workspace.toggleTag(tag.name, urls)
                        return true
                    }
                }
            } header: {
                Text("标签")
            }

            Section(isExpanded: expanded("locations")) {
                ForEach(volumes.volumes, id: \.url) { place in
                    row(place) {
                        Divider()
                        Button("分析空间占用", systemImage: "chart.pie") { workspace.analyzeSpace(place.url) }
                        if place.isEjectable {
                            Button("推出“\(place.name)”", systemImage: "eject") { volumes.eject(place) }
                        }
                    }
                }
                row(Places.trash)
            } header: {
                Text("位置")
                    .contextMenu {
                        Button("连接服务器…", systemImage: "server.rack") { workspace.showConnectServer = true }
                    }
            }
        }
        .listStyle(.sidebar)
    }

    /// The window's color. With a saved workspace open, it is that workspace's color (saved as you pick).
    private var tintPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workspace.openWorkspace.map { "工作区“\($0.name)”的颜色" } ?? "窗口颜色")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(workspace.openWorkspace == nil
                      ? "这个窗口还没有打开已存的工作区，颜色只用于这个窗口。存成工作区后颜色会跟着工作区走。"
                      : "改变颜色会同时保存到这个工作区；切换到别的工作区时，窗口换成那个工作区的颜色。")
            HStack(spacing: 7) {
                ForEach(WorkspaceTint.allCases) { option in
                    let selected = workspace.tint == option
                    Button {
                        withAnimation(.easeInOut(duration: 0.35)) { workspace.setTint(option) }
                    } label: {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(option.color.gradient)
                            .frame(width: 20, height: 20)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(.white, lineWidth: selected ? 2 : 0)
                            }
                            .shadow(color: option.color.opacity(selected ? 0.55 : 0), radius: 4, y: 2)
                            .scaleEffect(selected ? 1.12 : 1)
                    }
                    .buttonStyle(.plain)
                    .help(option.title)
                    .accessibilityLabel("颜色：\(option.title)")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Rows

    private func isCurrent(_ url: URL) -> Bool {
        workspace.activeTab.tagQuery == nil && workspace.activeTab.url.isSameFile(as: url)
    }

    private func row(_ place: Place, dimmed: Bool = false, @ViewBuilder extraMenu: () -> some View = { EmptyView() }) -> some View {
        HStack {
            Label(place.name, systemImage: place.symbol)
                .opacity(dimmed ? 0.45 : 1)
                .overlay(alignment: .bottomLeading) {
                    if let fullness = place.fullness { CapacityHairline(fullness: fullness).offset(x: 26, y: 5) }
                }
            Spacer(minLength: 0)
            if place.isEjectable {
                Button { volumes.eject(place) } label: { Image(systemName: "eject.fill").font(.caption) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("推出")
            }
        }
        .modifier(SidebarRowStyle(isSelected: isCurrent(place.url)) {
            workspace.activeTab.navigate(to: place.url)
            workspace.focusToken += 1
        })
        .help(dimmed ? "\(place.url.path)（不存在）" : place.url.path)
        // Dropping *onto* a row moves/copies files into that folder.
        .dropDestination(for: URL.self) { urls, _ in
            FileOperationQueue.shared.transfer(urls, to: place.url) { _, error in workspace.report(error) }
            return true
        }
        .contextMenu {
            Button("在新标签页中打开", systemImage: "plus.square.on.square") { workspace.openInNewTab(place.url) }
            Button("在另一窗格中打开", systemImage: "rectangle.split.2x1") { workspace.openInOtherPane(place.url) }
            Divider()
            Button("拷贝路径", systemImage: "link") { workspace.copyPath([place.url]) }
            Button("在终端中打开", systemImage: "terminal") { workspace.openInTerminal(place.url) }
            Button("在访达中显示", systemImage: "macwindow") { workspace.revealInFinder([place.url]) }
            if !store.isFavorite(place.url) {
                Button("添加到个人收藏", systemImage: "star") { store.addFavorite(place.url) }
            }
            extraMenu()
        }
    }

    private func workspaceRow(_ saved: SavedWorkspace) -> some View {
        let isOpen = saved.id == workspace.openWorkspaceID
        return Label {
            HStack(spacing: 6) {
                Text(saved.name).fontWeight(isOpen ? .semibold : .regular)
                Spacer(minLength: 0)
                if isOpen {
                    Text("当前").font(.system(size: 10, weight: .medium)).foregroundStyle(saved.tint.color)
                }
            }
        } icon: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(saved.tint.color.gradient)
                .frame(width: 14, height: 14)
        }
        .modifier(SidebarRowStyle(isSelected: false) {
            withAnimation(.easeInOut(duration: 0.35)) { workspace.open(saved) }
        })
        .help("\(saved.summary)\n点击切换到这个工作区（布局和颜色）")
        .contextMenu {
            Button("切换到这个工作区", systemImage: "arrow.up.forward.app") { workspace.open(saved) }
            Button("用当前布局更新", systemImage: "arrow.triangle.2.circlepath") { workspace.updateSavedWorkspace(saved) }
            Button("重命名…", systemImage: "pencil") { workspace.workspaceNameRequest = .rename(saved) }
            Divider()
            Button("删除", systemImage: "trash", role: .destructive) { workspace.deleteSavedWorkspace(saved) }
        }
    }

    /// Recent folders that aren't already shown elsewhere in the sidebar.
    private var recentPlaces: [Place] {
        let shown = Set(store.favorites.map(\.path) + volumes.volumes.map { $0.url.standardizedFileURL.path })
        return store.recents
            .filter { !shown.contains($0) && FileManager.default.fileExists(atPath: $0) }
            .prefix(6)
            .map { path in
                let url = URL(fileURLWithPath: path)
                return Place(name: Places.displayName(for: url), url: url, symbol: "clock")
            }
    }

    private func expanded(_ section: String) -> Binding<Bool> {
        Binding(get: { store.isExpanded(section) }, set: { store.setExpanded(section, $0) })
    }
}

/// Sidebar rows draw their own selection and hover: a soft wash of the workspace color instead of
/// the system's gray / accent-blue highlight, with the icon taking the color when selected.
private struct SidebarRowStyle: ViewModifier {
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.arborTint) private var tint
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.primary.opacity(0.88)))
            .symbolRenderingMode(.monochrome)
            .tint(isSelected ? tint : Color.secondary)
            .fontWeight(isSelected ? .semibold : .regular)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
            .listRowBackground(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(isSelected ? 0.16 : (hovering ? 0.07 : 0)))
                    .padding(.horizontal, 10)
                    .animation(.easeOut(duration: 0.12), value: hovering)
            )
    }
}

/// How full a disk is, as a hairline under its name; turns orange past 90%.
private struct CapacityHairline: View {
    let fullness: Double
    @Environment(\.arborTint) private var tint

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.1))
            .frame(width: 64, height: 2.5)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(fullness > 0.9 ? Color.orange : tint)
                    .frame(width: max(64 * fullness, 2.5), height: 2.5)
            }
            .help("已用 \(Int((fullness * 100).rounded()))%")
    }
}
