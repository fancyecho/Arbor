import SwiftUI

struct SidebarView: View {
    let workspace: WorkspaceState
    private let volumes = VolumeList.shared
    private let store = SidebarStore.shared
    private let library = WorkspaceLibrary.shared

    @Environment(\.arborTint) private var tint
    @Environment(\.colorScheme) private var colorScheme
    @State private var springLoader = SpringLoader()

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
        }
    }

    private var list: some View {
        List {
            Section(isExpanded: expanded("favorites")) {
                ForEach(Array(store.favorites.enumerated()), id: \.element.id) { index, favorite in
                    row(Place(name: favorite.name, url: favorite.url, symbol: favorite.symbol), dimmed: !favorite.exists) {
                        Divider()
                        Button(L("从边栏中移除"), systemImage: "minus.circle") { store.removeFavorite(favorite) }
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
                header(L("个人收藏"), "favorites", count: store.favorites.count)
                    .contextMenu {
                        Button(L("恢复默认收藏")) { store.resetFavorites() }
                    }
            }

            Section(isExpanded: expanded("workspaces")) {
                ForEach(library.saved) { saved in workspaceRow(saved) }
                    .onMove { library.move(from: $0, to: $1) }
                Label {
                    Text(library.saved.isEmpty ? L("把当前布局存为工作区…") : L("存储当前布局…"))
                } icon: {
                    Image(systemName: "plus.circle")
                }
                .foregroundStyle(.secondary)
                .modifier(SidebarRowStyle(isSelected: false) { workspace.workspaceNameRequest = .save })
                .help(L("工作区 = 一组存好的窗格、标签页和颜色。比如“写论文”同时打开论文和参考文献，“整理照片”打开相册和导出文件夹，点一下就切过去。"))
            } header: {
                HStack {
                    header(L("工作区"), "workspaces", count: library.saved.count)
                    TintButton(workspace: workspace)
                }
            }

            let recents = recentPlaces
            if !recents.isEmpty {
                Section(isExpanded: expanded("recents")) {
                    ForEach(recents, id: \.url) { row($0) }
                } header: {
                    header(L("最近"), "recents", count: recents.count)
                        .contextMenu {
                            Button(L("清除最近位置")) { store.clearRecents() }
                        }
                }
            }

            if let iCloud = Places.iCloudDrive {
                Section(isExpanded: expanded("icloud")) { row(iCloud) } header: { header("iCloud", "icloud", count: 1) }
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
                HStack(spacing: 8) {
                    Text(L("标签"))
                    // Collapsed, the tags stay one click away as a row of dots.
                    if !store.isExpanded("tags") {
                        HStack(spacing: 5) {
                            ForEach(FinderTags.standard, id: \.name) { tag in
                                Button { workspace.showTag(tag.name) } label: {
                                    Image(nsImage: FinderTags.dot(tag.color, size: 8))
                                }
                                .buttonStyle(.plain)
                                .help(tag.name)
                            }
                        }
                        .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                }
            }

            Section(isExpanded: expanded("locations")) {
                ForEach(volumes.volumes, id: \.url) { place in
                    row(place) {
                        Divider()
                        Button(L("分析空间占用"), systemImage: "chart.pie") { workspace.analyzeSpace(place.url) }
                        if place.isEjectable {
                            Button(L("推出“\(place.name)”"), systemImage: "eject") { volumes.eject(place) }
                        }
                    }
                }
                row(Places.trash) {
                    Divider()
                    Button(L("清倒废纸篓…"), systemImage: "trash.slash") { TrashBin.shared.empty(workspace: workspace) }
                        .disabled(TrashBin.shared.isEmptying)
                }
            } header: {
                header(L("位置"), "locations", count: volumes.volumes.count + 1)
                    .contextMenu {
                        Button(L("连接服务器…"), systemImage: "server.rack") { workspace.showConnectServer = true }
                    }
            }
        }
        .listStyle(.sidebar)
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
            if let free = place.free {
                Text(Format.bytes(free))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .help(L("可用空间"))
            }
            if place.isEjectable {
                if volumes.ejecting.contains(place.url.standardizedFileURL) {
                    ProgressView().controlSize(.mini).help(L("正在推出…"))
                } else {
                    Button { volumes.eject(place) } label: { Image(systemName: "eject.fill").font(.caption) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        // Its own gesture wins over the row's tap, so ejecting never opens the disk first.
                        .highPriorityGesture(TapGesture().onEnded { volumes.eject(place) })
                        .help(L("推出"))
                }
            }
        }
        .modifier(SidebarRowStyle(isSelected: isCurrent(place.url)) {
            workspace.activeTab.navigate(to: place.url)
            workspace.focusToken += 1
        })
        .help(dimmed ? L("\(place.url.path)（不存在）") : place.url.path)
        // Dropping *onto* a row moves/copies files into that folder.
        .dropDestination(for: URL.self) { urls, _ in
            springLoader.cancel()
            FileOperationQueue.shared.transfer(urls, to: place.url) { _, error in workspace.report(error) }
            return true
        } isTargeted: { targeted in
            // Holding a drag over a place opens it in the active pane, like Finder's sidebar.
            if targeted {
                springLoader.open = { [workspace] folder in workspace.activeTab.navigate(to: folder) }
                springLoader.hover(place.url)
            } else {
                springLoader.leave(place.url)
            }
        }
        .contextMenu {
            Button(L("在新标签页中打开"), systemImage: "plus.square.on.square") { workspace.openInNewTab(place.url) }
            Button(L("在另一窗格中打开"), systemImage: "rectangle.split.2x1") { workspace.openInOtherPane(place.url) }
            Divider()
            Button(L("拷贝路径"), systemImage: "link") { workspace.copyPath([place.url]) }
            Button(L("在终端中打开"), systemImage: "terminal") { workspace.openInTerminal(place.url) }
            Button(L("在访达中显示"), systemImage: "macwindow") { workspace.revealInFinder([place.url]) }
            if !store.isFavorite(place.url) {
                Button(L("添加到个人收藏"), systemImage: "star") { store.addFavorite(place.url) }
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
                    Text(L("当前")).font(.system(size: 10, weight: .medium)).foregroundStyle(saved.tint.color.onSidebarGlass(colorScheme))
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
        .help(L("\(saved.summary)\n点击切换到这个工作区（布局和颜色）"))
        .contextMenu {
            Button(L("切换到这个工作区"), systemImage: "arrow.up.forward.app") { workspace.open(saved) }
            Button(L("用当前布局更新"), systemImage: "arrow.triangle.2.circlepath") { workspace.updateSavedWorkspace(saved) }
            Button(L("重命名…"), systemImage: "pencil") { workspace.workspaceNameRequest = .rename(saved) }
            Divider()
            Button(L("删除"), systemImage: "trash", role: .destructive) { workspace.deleteSavedWorkspace(saved) }
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

    /// A section title. Collapsed, it says how much is folded away, so it never reads as an empty section.
    private func header(_ title: String, _ section: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if !store.isExpanded(section), count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .frame(height: 15)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
    }

    private func expanded(_ section: String) -> Binding<Bool> {
        Binding(get: { store.isExpanded(section) },
                set: { value in withAnimation(.snappy(duration: 0.25)) { store.setExpanded(section, value) } })
    }
}

/// Sidebar rows draw their own selection and hover: the selected place is a raised solid chip instead of
/// the system's gray / accent highlight, and every icon wears the workspace color.
private struct SidebarRowStyle: ViewModifier {
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.arborTint) private var tint
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.primary.opacity(0.88)))
            .symbolRenderingMode(.monochrome)
            .labelStyle(SidebarIconStyle(color: isSelected ? tint : tint.opacity(0.8)))
            .fontWeight(isSelected ? .semibold : .regular)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hovering = $0 }
            .listRowBackground(
                // The selected place is a small solid chip raised off the base; hover is a faint wash.
                RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Surface.raised) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.05 : 0)))
                    .shadow(color: .black.opacity(isSelected ? (colorScheme == .dark ? 0.3 : 0.08) : 0), radius: 1.5, y: 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                            .strokeBorder(Surface.hairline.opacity(isSelected ? 0.8 : 0), lineWidth: 0.5)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 1)
                    .animation(.easeOut(duration: 0.12), value: hovering)
                    .animation(.easeOut(duration: 0.18), value: isSelected)
            )
    }
}

/// Colors the row's icon itself in the workspace color (fuller when selected).
private struct SidebarIconStyle: LabelStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon.foregroundStyle(color)
        }
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
            .help(L("已用 \(Int((fullness * 100).rounded()))%"))
    }
}

/// The window's color: a small swatch in the 工作区 header that opens the palette. With a saved workspace
/// open, the color is that workspace's (saved as you pick).
private struct TintButton: View {
    let workspace: WorkspaceState
    @State private var open = false

    private var title: String { workspace.openWorkspace.map { L("工作区“\($0.name)”的颜色") } ?? L("窗口颜色") }

    var body: some View {
        Button { open.toggle() } label: {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(workspace.tint.color)
                .frame(width: 11, height: 11)
                .overlay { RoundedRectangle(cornerRadius: 3.5, style: .continuous).strokeBorder(.black.opacity(0.12), lineWidth: 0.5) }
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .popover(isPresented: $open, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 12, weight: .semibold))
                HStack(spacing: 8) {
                    ForEach(WorkspaceTint.allCases) { option in
                        let selected = workspace.tint == option
                        Button {
                            withAnimation(.easeInOut(duration: 0.35)) { workspace.setTint(option) }
                        } label: {
                            Circle()
                                .fill(option.color)
                                .frame(width: 22, height: 22)
                                .overlay { Circle().strokeBorder(.white, lineWidth: selected ? 2 : 0) }
                                .overlay { Circle().strokeBorder(option.color, lineWidth: selected ? 1 : 0).padding(-2) }
                        }
                        .buttonStyle(.plain)
                        .help(option.title)
                        .accessibilityLabel(L("颜色：\(option.title)"))
                    }
                }
                Text(workspace.openWorkspace == nil
                     ? L("这个窗口还没有打开已存的工作区，颜色只用于这个窗口。存成工作区后颜色会跟着工作区走。")
                     : L("改变颜色会同时保存到这个工作区；切换到别的工作区时，窗口换成那个工作区的颜色。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 240, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }
}
