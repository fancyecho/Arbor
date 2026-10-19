import SwiftUI

/// Window root. The workspace is created once per window (not on every view re-init),
/// and the first window of a launch restores the previous session.
struct ContentView: View {
    @State private var workspace: WorkspaceState?

    var body: some View {
        if let workspace {
            WorkspaceWindow(workspace: workspace)
        } else {
            Color.clear.onAppear { workspace = WorkspaceRegistry.shared.makeWorkspace() }
        }
    }
}

struct WorkspaceWindow: View {
    @Bindable var workspace: WorkspaceState
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        window
            .tint(workspace.tint.color)
            .environment(\.arborTint, workspace.tint.color)
    }

    private var window: some View {
        // Everything floats on one tinted, blurred backdrop: sidebar, panes and inspector are glass cards.
        HStack(spacing: 0) {
            if workspace.showSidebar {
                SidebarView(workspace: workspace)
                    .scrollContentBackground(.hidden)
                    .frame(width: 220)
                    .background(Glass.card(active: false), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Glass.hairline))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding([.leading, .bottom], 10)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            PanesView(workspace: workspace)
            if workspace.showInspector {
                InspectorView(workspace: workspace)
                    .frame(width: 300)
                    .background(Glass.card(active: true), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Glass.hairline))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                    .padding([.trailing, .bottom], 10)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background { WorkspaceBackdrop(tint: workspace.tint.color) }
        .modifier(TransparentToolbar())
        .animation(.snappy(duration: 0.3), value: workspace.showSidebar)
        .animation(.snappy(duration: 0.3), value: workspace.showInspector)
        .navigationTitle(workspace.activeTab.title)
        .toolbar(id: "arbor.main") {
            toolbar
            optionalToolbar
            trailingToolbar
        }
        .searchable(text: filterBinding, placement: .toolbar, prompt: searchPrompt)
        .searchScopes(scopeBinding) {
            ForEach(SearchScope.allCases) { Text($0.title).tag($0) }
        }
        .modifier(SearchFocus(token: workspace.searchFocusToken))
        .focusedSceneValue(\.workspace, workspace)
        .sheet(isPresented: batchRenameBinding) {
            BatchRenameView(workspace: workspace, urls: workspace.batchRenameTargets ?? [])
        }
        .overlay {
            if workspace.showPalette { CommandPalette(workspace: workspace) }
        }
        .sheet(item: $workspace.commandOutput) { CommandOutputSheet(output: $0) }
        .sheet(isPresented: $workspace.showSelectByCondition) { SelectByConditionView(workspace: workspace) }
        .sheet(isPresented: $workspace.showSync) { SyncSheet(workspace: workspace) }
        .sheet(isPresented: $workspace.showConnectServer) { ConnectServerSheet(workspace: workspace) }
        .sheet(isPresented: updateSheetBinding) { UpdateSheet() }
        .sheet(item: $workspace.workspaceNameRequest) { request in
            WorkspaceNameSheet(workspace: workspace, request: request)
        }
        .onChange(of: controlActiveState, initial: true) { _, state in
            if state == .key { WorkspaceRegistry.shared.markActive(workspace) }
        }
        .onDisappear { WorkspaceRegistry.shared.persist(workspace) }
        .onAppear { AppActions.openWindow = openWindow }
        .onReceive(NotificationCenter.default.publisher(for: Snapshot.demoRequest)) { note in
            let fm = FileManager.default
            switch note.object as? String {
            case "palette":
                Frecency.shared.visit(fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
                workspace.showPalette = true
                return
            case "compare":
                workspace.visiblePanes[1].activeTab.navigate(to: workspace.visiblePanes[0].activeTab.url.appendingPathComponent("Documents"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { workspace.comparePanes() }
                return
            case "sync":
                workspace.showSync = true
                return
            case "stress":
                // Hammers the flows that used to hang/crash: sidebar, inspector, colors, photo selection,
                // pane counts and window resizing, every 150 ms for ~12 s.
                let folder = ProcessInfo.processInfo.environment["ARBOR_DEMO_DIR"].map { URL(fileURLWithPath: $0) }
                if let folder {
                    workspace.visiblePanes[0].activeTab.navigate(to: folder)
                    workspace.visiblePanes[1].activeTab.navigate(to: folder)
                }
                var step = 0
                Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        step += 1
                        if step > 180 { timer.invalidate(); return }
                        switch step % 9 {
                        case 0: workspace.showSidebar.toggle()
                        case 1: workspace.setTint(WorkspaceTint.allCases[step % WorkspaceTint.allCases.count])
                        case 2: workspace.showInspector.toggle()
                        case 3:
                            let items = workspace.activeTab.visibleItems
                            if !items.isEmpty { workspace.activeTab.selection = [items[step % items.count].url] }
                        case 4: workspace.setPaneCount(step % 3 + 1)
                        case 5:
                            if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
                                var frame = window.frame
                                frame.size.width = step % 2 == 0 ? 900 : 1300
                                window.setFrame(frame, display: true)
                            }
                        case 6: workspace.setViewMode(ViewMode.allCases[step % 3])
                        case 7: workspace.quickLook()
                        default: workspace.focusNextPane()
                        }
                    }
                }
                return
            case "photos":
                // Photo folder from ARBOR_DEMO_DIR in icon view, a photo selected, list of the same folder beside it.
                guard let path = ProcessInfo.processInfo.environment["ARBOR_DEMO_DIR"] else { return }
                let folder = URL(fileURLWithPath: path)
                workspace.setTint(.coral)
                workspace.visiblePanes[0].activeTab.navigate(to: folder)
                workspace.visiblePanes[0].activeTab.viewMode = .grid
                workspace.visiblePanes[1].activeTab.navigate(to: folder)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    workspace.visiblePanes[0].activeTab.selection = [folder.appendingPathComponent("岚山-日落.jpg")]
                    workspace.visiblePanes[1].activeTab.selection = [folder.appendingPathComponent("旅行视频.mov")]
                    workspace.showInspector = true
                    workspace.activate(workspace.visiblePanes[0])
                }
                // Overlay scroll bars only show while scrolling; keep flashing them for screenshots.
                Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        func flash(_ view: NSView) {
                            (view as? NSScrollView)?.flashScrollers()
                            view.subviews.forEach(flash)
                        }
                        NSApp.windows.compactMap(\.contentView).forEach(flash)
                    }
                }
                return
            case "text":
                let project = URL(fileURLWithPath: fm.currentDirectoryPath)
                workspace.go(to: project.appendingPathComponent("README.md"))
                AppSettings.shared.listColumns = ["modified", "size", "ext", "tags"]
                workspace.showInspector = true
                return
            default: break
            }
            // Populates the features that only show up after use: pinned tabs, workspaces, recents.
            let pane = workspace.visiblePanes[0]
            pane.togglePin(pane.activeTabID)
            pane.newTab(url: fm.urls(for: .documentDirectory, in: .userDomainMask)[0])
            pane.newTab(url: URL(fileURLWithPath: "/Applications"))
            for path in ["/Applications/Utilities", "/Library/Fonts"] { SidebarStore.shared.visit(URL(fileURLWithPath: path)) }
            workspace.saveWorkspace(named: "写论文")
            workspace.saveWorkspace(named: "整理照片")
        }
        .onReceive(NotificationCenter.default.publisher(for: Snapshot.gridRequest)) { note in
            workspace.setViewMode(ViewMode(rawValue: note.object as? String ?? "") ?? .grid)
            workspace.activeTab.selection = Set(workspace.activeTab.visibleItems.prefix(1).map(\.url))
            workspace.showInspector = true
        }
        .alert("无法完成操作", isPresented: alertBinding) {
            Button("好") { workspace.alertMessage = nil }
        } message: {
            Text(workspace.alertMessage ?? "")
        }
    }

    // MARK: Toolbar

    /// Customizable: right-click the toolbar › 自定义工具栏. Extra buttons are hidden by default.
    @ToolbarContentBuilder
    private var toolbar: some CustomizableToolbarContent {
        let tab = workspace.activeTab
        ToolbarItem(id: "sidebar", placement: .navigation) {
            Button { workspace.showSidebar.toggle() } label: { Label("侧边栏", systemImage: "sidebar.leading") }
                .help("显示 / 隐藏侧边栏 (⌃⌘B)")
        }
        ToolbarItem(id: "nav", placement: .navigation) {
            ControlGroup {
                Button { workspace.goBack() } label: { Label("返回", systemImage: "chevron.left") }
                    .disabled(!tab.canGoBack)
                    .help("返回 (⌘[)")
                Button { workspace.goForward() } label: { Label("前进", systemImage: "chevron.right") }
                    .disabled(!tab.canGoForward)
                    .help("前进 (⌘])")
            }
            .controlGroupStyle(.navigation)
        }
        ToolbarItem(id: "up", placement: .navigation) {
            Button { workspace.goUp() } label: { Label("上层文件夹", systemImage: "arrow.up") }
                .disabled(!tab.canGoUp)
                .help("上层文件夹 (⌘↑)")
        }

        ToolbarItem(id: "panes", placement: .principal) {
            Picker("窗格", selection: Binding(get: { workspace.paneCount }, set: { workspace.setPaneCount($0) })) {
                Label("单窗格", systemImage: "rectangle").tag(1)
                Label("双窗格", systemImage: "rectangle.split.2x1").tag(2)
                Label("三窗格", systemImage: "rectangle.split.3x1.fill").tag(3)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("窗格布局 (⌃⌘1 / 2 / 3)")
        }

        ToolbarItem(id: "view", placement: .principal) {
            Picker("视图", selection: Binding(get: { workspace.activeTab.viewMode }, set: { workspace.setViewMode($0) })) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("视图 (⌘1 / ⌘2 / ⌘3)")
        }

        ToolbarItem(id: "operations", placement: .primaryAction) { OperationsButton() }
    }

    @ToolbarContentBuilder
    private var optionalToolbar: some CustomizableToolbarContent {

        ToolbarItem(id: "palette", placement: .primaryAction, showsByDefault: false) {
            button("命令面板", "command", "⌘K") { workspace.showPalette.toggle() }
        }
        ToolbarItem(id: "newFolder", placement: .primaryAction, showsByDefault: false) {
            button("新建文件夹", "folder.badge.plus", "⇧⌘N") { workspace.newFolder() }
        }
        ToolbarItem(id: "trash", placement: .primaryAction, showsByDefault: false) {
            button("移到废纸篓", "trash", "⌘⌫") { workspace.moveToTrash() }
        }
        ToolbarItem(id: "copyPath", placement: .primaryAction, showsByDefault: false) {
            button("拷贝路径", "link", "⌥⌘C") { workspace.copyPath() }
        }
        ToolbarItem(id: "terminal", placement: .primaryAction, showsByDefault: false) {
            button("终端", "terminal", "⌥⌘T") { workspace.openInTerminal() }
        }
        ToolbarItem(id: "editor", placement: .primaryAction, showsByDefault: false) {
            button(AppSettings.shared.editorName, "chevron.left.forwardslash.chevron.right", "⌥⌘E") { workspace.openInEditor() }
        }
        ToolbarItem(id: "compare", placement: .primaryAction, showsByDefault: false) {
            button("对比窗格", "arrow.left.arrow.right.square", "⌃⌘C") { workspace.comparePanes() }
        }
        ToolbarItem(id: "sync", placement: .primaryAction, showsByDefault: false) {
            button("同步文件夹", "arrow.triangle.2.circlepath", "⌃⌘Y") {
                if workspace.otherPane == nil { workspace.setPaneCount(2) }
                workspace.showSync = true
            }
        }
        ToolbarItem(id: "server", placement: .primaryAction, showsByDefault: false) {
            button("连接服务器", "server.rack", "⇧⌘K") { workspace.showConnectServer = true }
        }
        ToolbarItem(id: "reload", placement: .primaryAction, showsByDefault: false) {
            button("刷新", "arrow.clockwise", "⌘R") { workspace.activeTab.reload() }
        }

    }

    @ToolbarContentBuilder
    private var trailingToolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "shelf", placement: .primaryAction) {
            button("暂存架", StashShelf.shared.items.isEmpty ? "tray" : "tray.full", "⌥⌘S") { StashShelf.shared.toggle() }
        }

        ToolbarItem(id: "actions", placement: .primaryAction) {
            Menu {
                Button("新建文件夹", systemImage: "folder.badge.plus") { workspace.newFolder() }
                Menu("从模板新建", systemImage: "doc.badge.plus") {
                    ForEach(Templates.all, id: \.self) { template in
                        Button(template.deletingPathExtension().lastPathComponent) { workspace.newFile(from: template) }
                    }
                }
                Divider()
                Button("批量重命名…", systemImage: "character.cursor.ibeam") { workspace.batchRename() }
                Button("在终端中打开", systemImage: "terminal") { workspace.openInTerminal() }
                Button("拷贝当前路径", systemImage: "link") { workspace.copyPath([workspace.activeTab.url]) }
                Button("连接服务器…", systemImage: "server.rack") { workspace.showConnectServer = true }
            } label: {
                Label("新建与操作", systemImage: "plus")
            }
            .help("新建与操作")
        }

        ToolbarItem(id: "hidden", placement: .primaryAction) {
            Toggle(isOn: Binding(get: { AppSettings.shared.showHidden }, set: { AppSettings.shared.showHidden = $0 })) {
                Label("隐藏文件", systemImage: AppSettings.shared.showHidden ? "eye" : "eye.slash")
            }
            .help("显示隐藏文件 (⇧⌘.)")
        }

        ToolbarItem(id: "inspector", placement: .primaryAction) {
            button("检查器", "sidebar.trailing", "⌥⌘I") { workspace.showInspector.toggle() }
        }
    }

    private func button(_ title: String, _ symbol: String, _ shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .help("\(title) (\(shortcut))")
    }

    // MARK: Bindings

    private var filterBinding: Binding<String> {
        Binding(get: { workspace.activeTab.filter }, set: { workspace.activeTab.filter = $0 })
    }

    private var scopeBinding: Binding<SearchScope> {
        Binding(get: { workspace.activeTab.searchScope }, set: { workspace.activeTab.searchScope = $0 })
    }

    private var searchPrompt: String {
        switch workspace.activeTab.searchScope {
        case .folder: "过滤当前文件夹"
        case .subfolders: "搜索“\(workspace.activeTab.title)”及子文件夹"
        case .spotlight: "用 Spotlight 搜索名称和内容"
        }
    }

    /// The update sheet appears only in the frontmost window.
    private var updateSheetBinding: Binding<Bool> {
        Binding(get: { Updater.shared.showsSheet && WorkspaceRegistry.shared.current === workspace },
                set: { if !$0 { Updater.shared.showsSheet = false } })
    }

    private var batchRenameBinding: Binding<Bool> {
        Binding(get: { workspace.batchRenameTargets != nil }, set: { if !$0 { workspace.batchRenameTargets = nil } })
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { workspace.alertMessage != nil }, set: { if !$0 { workspace.alertMessage = nil } })
    }
}

/// Side-by-side floating pane cards. The gap between two cards is a handle for resizing them.
struct PanesView: View {
    let workspace: WorkspaceState

    private static let gap: CGFloat = 10
    private static let minimumWidth: CGFloat = 240

    /// Fractions when the current drag began; widths are always computed from these, never incrementally.
    @State private var dragStart: [CGFloat]?

    var body: some View {
        GeometryReader { geometry in
            let panes = workspace.visiblePanes
            let fractions = Array(workspace.paneFractions.prefix(panes.count))
            let total = fractions.reduce(0, +)
            let available = geometry.size.width - Self.gap * CGFloat(panes.count + 1)
            HStack(spacing: 0) {
                ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                    if index > 0 {
                        PaneGutter(width: Self.gap) { translation in
                            resize(index - 1, translation: translation, available: available)
                        } onEnd: {
                            dragStart = nil
                        } onReset: {
                            workspace.paneFractions = [1, 1, 1]
                        }
                    }
                    PaneView(workspace: workspace, pane: pane)
                        .frame(width: max(Self.minimumWidth, available * fractions[index] / total))
                }
            }
            .padding(.horizontal, Self.gap)
            .padding(.bottom, Self.gap)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
    }

    /// Sets pane `index` and the next one from the drag's total translation (in window coordinates),
    /// clamped so both stay at least `minimumWidth` wide. Same input → same output: no jitter.
    private func resize(_ index: Int, translation: CGFloat, available: CGFloat) {
        let start = dragStart ?? workspace.paneFractions
        if dragStart == nil { dragStart = start }
        guard let fractions = Self.resized(start, divider: index, translation: translation, available: available,
                                           count: workspace.visiblePanes.count, minimumWidth: Self.minimumWidth),
              fractions != workspace.paneFractions else { return }
        workspace.paneFractions = fractions
    }

    static func resized(_ start: [CGFloat], divider index: Int, translation: CGFloat, available: CGFloat,
                        count: Int, minimumWidth: CGFloat) -> [CGFloat]? {
        guard start.indices.contains(index + 1) else { return nil }
        let total = start.prefix(count).reduce(0, +)
        let perPoint = total / max(available, 1)
        let pair = start[index] + start[index + 1]
        let minimum = minimumWidth * perPoint
        guard pair > minimum * 2 else { return nil }
        let left = min(max(start[index] + translation * perPoint, minimum), pair - minimum)
        var fractions = start
        fractions[index] = left
        fractions[index + 1] = pair - left
        return fractions
    }
}

/// The transparent gap between two pane cards: drag to resize, double-click to make them equal.
private struct PaneGutter: View {
    let width: CGFloat
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void

    @State private var hovering = false
    @State private var dragging = false
    @State private var cursorPushed = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: width)
            .overlay {
                Capsule()
                    .fill(Color.primary.opacity(dragging ? 0.35 : (hovering ? 0.22 : 0)))
                    .frame(width: 3, height: 36)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                updateCursor()
            }
            // Global coordinates: the gutter moves while it is dragged, so local ones would feed back.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if !dragging {
                        dragging = true
                        updateCursor()
                    }
                    onDrag(value.translation.width)
                }
                .onEnded { _ in
                    dragging = false
                    onEnd()
                    updateCursor()
                })
            .onTapGesture(count: 2, perform: onReset)
            .onDisappear {
                if cursorPushed { NSCursor.pop() }
                cursorPushed = false
            }
            .help("拖动调整宽度，双击恢复等宽")
    }

    /// Exactly one push per pop, however often hover flips while the gutter slides under the pointer.
    private func updateCursor() {
        let want = hovering || dragging
        if want, !cursorPushed {
            NSCursor.resizeLeftRight.push()
            cursorPushed = true
        } else if !want, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}

/// Focuses the toolbar search field when `token` changes (macOS 15+; earlier systems just switch scope).
private struct SearchFocus: ViewModifier {
    let token: Int
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .searchFocused($focused)
                .onChange(of: token) { _, _ in focused = true }
        } else {
            content
        }
    }
}

/// Lets the tinted backdrop show through the toolbar (macOS 15+).
private struct TransparentToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}
