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
    @Environment(\.openSettings) private var openSettings
    @State private var windowWidth: CGFloat = 0

    var body: some View {
        window
            .tint(workspace.tint.color)
            .environment(\.arborTint, workspace.tint.color)
    }

    /// 300pt when there's room; in a narrow window it gives up to 40pt so the panes keep theirs.
    private var inspectorWidth: CGFloat {
        let sidebar: CGFloat = workspace.showSidebar ? WindowLayout.sidebar : 0
        let spare = windowWidth - sidebar - PanesView.preferredWidth(count: workspace.visiblePanes.count) - 10
        return min(300, max(WindowLayout.inspector - 10, spare))
    }

    private var minimumWidth: CGFloat {
        WindowLayout.minimumWidth(panes: workspace.visiblePanes.count, sidebar: workspace.showSidebar,
                                  inspector: workspace.showInspector)
    }

    /// The first file list in a view tree (snapshot scenes).
    static func firstTable(in view: NSView?) -> FileTableView? {
        guard let view else { return nil }
        if let table = view as? FileTableView { return table }
        for subview in view.subviews { if let table = firstTable(in: subview) { return table } }
        return nil
    }

    /// On a screen too small for everything that's switched on, the inspector gives way, then panes.
    private func fitScreen() {
        guard let screen = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.width else { return }
        if minimumWidth > screen, workspace.showInspector { workspace.showInspector = false }
        while minimumWidth > screen, workspace.paneCount > 1 { workspace.setPaneCount(workspace.paneCount - 1) }
    }

    private var window: some View {
        // Everything floats on one tinted, blurred backdrop: sidebar, panes and inspector are glass cards,
        // laid out (and animated) by the deck.
        DeckView(workspace: workspace, inspectorWidth: inspectorWidth)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        // Never narrower than what's switched on needs; switching more on widens the window.
        .frame(minWidth: minimumWidth)
        .onChange(of: minimumWidth, initial: true) { _, _ in fitScreen() }
        .background { WorkspaceBackdrop(tint: workspace.tint.color) }
        .background { WindowFrameKeeper(minimumWidth: minimumWidth).frame(width: 0, height: 0) }
        .modifier(TransparentToolbar())
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
        .onDisappear { WorkspaceRegistry.shared.windowClosed(workspace) }
        .onAppear {
            WorkspaceRegistry.shared.windowAppeared(workspace)
            AppActions.openWindow = openWindow
        }
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
            case "settings":
                openSettings()
                return
            case "update", "update-install":
                // Checks GitHub for real; with ARBOR_FAKE_CURRENT_TAG set lower, the latest release is offered.
                Updater.shared.check(userInitiated: true)
                if note.object as? String == "update-install" {
                    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                        MainActor.assumeIsolated {
                            if case .available(let release) = Updater.shared.phase {
                                timer.invalidate()
                                Updater.shared.install(release)
                            }
                        }
                    }
                }
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
            case "toggles":
                // Inspector on/off and pane count 2→3→2, a second apart, for watching column changes.
                if let width = ProcessInfo.processInfo.environment["ARBOR_WINDOW_WIDTH"].flatMap(Double.init),
                   let window = NSApp.windows.first(where: \.isVisible) {
                    var frame = window.frame
                    frame.size.width = width
                    window.setFrame(frame, display: true)
                    workspace.setPaneCount(3)
                }
                let steps: [() -> Void] = [
                    { print("STEP inspector on"); workspace.showInspector = true },
                    { print("STEP inspector off"); workspace.showInspector = false },
                    { print("STEP panes 3"); workspace.setPaneCount(3) },
                    { print("STEP panes 2"); workspace.setPaneCount(2) },
                    { print("STEP sidebar off"); workspace.showSidebar = false },
                    { print("STEP sidebar on"); workspace.showSidebar = true },
                ]
                for (index, step) in steps.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(index) * 1.2, execute: step)
                }
                return
            case "space":
                // Space view of ARBOR_DEMO_DIR (or home) in the first pane, list of the same folder beside it.
                let folder = ProcessInfo.processInfo.environment["ARBOR_DEMO_DIR"].map { URL(fileURLWithPath: $0) }
                    ?? fm.homeDirectoryForCurrentUser
                workspace.visiblePanes[0].activeTab.navigate(to: folder)
                workspace.visiblePanes[0].activeTab.viewMode = .space
                if workspace.visiblePanes.count > 1 { workspace.visiblePanes[1].activeTab.navigate(to: folder) }
                if let panes = ProcessInfo.processInfo.environment["ARBOR_PANES"].flatMap(Int.init) { workspace.setPaneCount(panes) }
                if ProcessInfo.processInfo.environment["ARBOR_SPACE_TYPES"] != nil { AppSettings.shared.spaceColoring = .types }
                if ProcessInfo.processInfo.environment["ARBOR_SPACE_SCAN_NOW"] != nil { SpaceIndex.shared.startScan(folder) }
                if ProcessInfo.processInfo.environment["ARBOR_COMPACT_SIDEBAR"] != nil {
                    for section in ["favorites", "tags", "workspaces"] { SidebarStore.shared.setExpanded(section, false) }
                }
                if ProcessInfo.processInfo.environment["ARBOR_SORT_SIZE"] != nil, workspace.visiblePanes.count > 1 {
                    workspace.visiblePanes[1].activeTab.sort.key = .size
                    workspace.visiblePanes[1].activeTab.sort.ascending = false
                }
                if let child = ProcessInfo.processInfo.environment["ARBOR_SPACE_DRILL"] {
                    // Zoom into a child after the scan, then back out, for checking the transition.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        workspace.visiblePanes[0].activeTab.navigate(to: folder.appendingPathComponent(child))
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { workspace.visiblePanes[0].activeTab.goBack() }
                }
                return
            case "marquee":
                // Drag-selects in ARBOR_DEMO_DIR with synthetic mouse events sent to this window only (the real
                // pointer stays put): from the date column of row 1 down to row 4, or across the icon grid (ARBOR_GRID).
                guard let path = ProcessInfo.processInfo.environment["ARBOR_DEMO_DIR"] else { return }
                let tab = workspace.visiblePanes[0].activeTab
                tab.navigate(to: URL(fileURLWithPath: path))
                let grid = ProcessInfo.processInfo.environment["ARBOR_GRID"] != nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                          let table = Self.firstTable(in: window.contentView) else { return }
                    let start: NSPoint, end: NSPoint
                    if grid {
                        // The grid replaces the list in the same place: start in its 12 pt margin, top left.
                        let frame = table.enclosingScrollView!.convert(table.enclosingScrollView!.bounds, to: nil)
                        start = NSPoint(x: frame.minX + 5, y: frame.maxY - 5)
                        end = NSPoint(x: frame.minX + 250, y: frame.maxY - 150)
                        tab.viewMode = .grid
                    } else {
                        let first = table.rect(ofRow: 1), last = table.rect(ofRow: 4)
                        start = table.convert(NSPoint(x: first.maxX - 40, y: first.midY), to: nil)
                        end = ProcessInfo.processInfo.environment["ARBOR_CLICK"] != nil
                            ? start : table.convert(NSPoint(x: last.maxX - 120, y: last.midY), to: nil)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + (grid ? 1 : 0)) {
                        func post(_ type: NSEvent.EventType, _ point: NSPoint) {
                            NSApp.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                               clickCount: 1, pressure: 1)!, atStart: false)
                        }
                        post(.leftMouseDown, start)
                        for step in 1...12 {
                            let t = CGFloat(step) / 12
                            post(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
                        }
                        // Leave the rectangle up for the snapshot unless asked to finish.
                        if ProcessInfo.processInfo.environment["ARBOR_RELEASE"] != nil { post(.leftMouseUp, end) }
                    }
                }
                return
            case "newfolder":
                // New folder in ARBOR_DEMO_DIR, the way the context menu does it, for checking inline naming.
                guard let path = ProcessInfo.processInfo.environment["ARBOR_DEMO_DIR"] else { return }
                workspace.visiblePanes[0].activeTab.navigate(to: URL(fileURLWithPath: path))
                workspace.activate(workspace.visiblePanes[0])
                if ProcessInfo.processInfo.environment["ARBOR_MENU"] != nil {
                    // Through the real context menu: build it as a right-click on empty space does, then pick the item.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        let menu = NSMenu()
                        ContextMenuBuilder.build(into: menu, workspace: workspace, tab: workspace.activeTab, selected: [])
                        if let index = menu.items.firstIndex(where: { $0.title == L("新建文件夹") }) { menu.performActionForItem(at: index) }
                    }
                    return
                }
                guard ProcessInfo.processInfo.environment["ARBOR_MANUAL"] == nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if ProcessInfo.processInfo.environment["ARBOR_NEW_FILE"] != nil { workspace.newFile() } else { workspace.newFolder() }
                }
                return
            case "eject":
                // Show the volume at ARBOR_DEMO_DIR in a pane, then eject it from under ourselves.
                guard let path = ProcessInfo.processInfo.environment["ARBOR_DEMO_DIR"] else { return }
                let volume = URL(fileURLWithPath: path)
                workspace.visiblePanes[0].activeTab.navigate(to: volume)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    print("EJECT start", Date().timeIntervalSince1970)
                    VolumeList.shared.eject(Place(name: volume.lastPathComponent, url: volume, symbol: "externaldrive", isEjectable: true))
                    print("EJECT returned", Date().timeIntervalSince1970)
                }
                return
            case "shelf":
                // A few items from ARBOR_DEMO_DIR on the shelf (or an empty shelf with ARBOR_SHELF_EMPTY).
                StashShelf.shared.clear()
                if ProcessInfo.processInfo.environment["ARBOR_SHELF_EMPTY"] == nil,
                   let path = ProcessInfo.processInfo.environment["ARBOR_DEMO_DIR"],
                   let names = try? fm.contentsOfDirectory(atPath: path) {
                    StashShelf.shared.add(names.sorted().prefix(4).map { URL(fileURLWithPath: path).appendingPathComponent($0) })
                }
                StashShelf.shared.show()
                return
            case "columnsempty":
                // Column view in the home folder with an empty folder (ARBOR_DEMO_DIR) selected… navigated into.
                guard let path = ProcessInfo.processInfo.environment["ARBOR_DEMO_DIR"] else { return }
                workspace.visiblePanes[0].activeTab.navigate(to: URL(fileURLWithPath: path))
                workspace.visiblePanes[0].activeTab.viewMode = .columns
                return
            case "contextmenu":
                // A real right-click on the list of ARBOR_DEMO_DIR, for checking the menu's target highlight:
                // ARBOR_MENU_SELECT rows selected (default 3), clicked on row ARBOR_MENU_ROW (default 1).
                guard let path = ProcessInfo.processInfo.environment["ARBOR_DEMO_DIR"] else { return }
                let env = ProcessInfo.processInfo.environment
                workspace.visiblePanes[0].activeTab.navigate(to: URL(fileURLWithPath: path))
                workspace.activate(workspace.visiblePanes[0])
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let tab = workspace.visiblePanes[0].activeTab
                    tab.selection = Set(tab.visibleItems.prefix(env["ARBOR_MENU_SELECT"].flatMap(Int.init) ?? 3).map(\.url))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        func table(in view: NSView) -> FileTableView? {
                            (view as? FileTableView) ?? view.subviews.lazy.compactMap(table).first
                        }
                        guard let window = NSApp.windows.first(where: \.isVisible), let content = window.contentView,
                              let list = table(in: content) else { return }
                        let row = list.rect(ofRow: env["ARBOR_MENU_ROW"].flatMap(Int.init) ?? 1)
                        let point = list.convert(NSPoint(x: row.minX + 60, y: row.midY), to: nil)
                        if let click = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: window.windowNumber, context: nil,
                                                          eventNumber: 0, clickCount: 1, pressure: 1) {
                            list.rightMouseDown(with: click)
                        }
                    }
                }
                return
            case "narrow":
                // Three panes and the inspector in a window narrower than they'd like.
                workspace.setPaneCount(3)
                workspace.showInspector = true
                if let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) {
                    var frame = window.frame
                    frame.size.width = 900
                    window.setFrame(frame, display: true)
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
                    workspace.visiblePanes[0].activeTab.selection = [folder.appendingPathComponent(L("岚山-日落.jpg"))]
                    workspace.visiblePanes[1].activeTab.selection = [folder.appendingPathComponent(L("旅行视频.mov"))]
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
            workspace.saveWorkspace(named: L("写论文"))
            workspace.saveWorkspace(named: L("整理照片"))
        }
        .onReceive(NotificationCenter.default.publisher(for: Snapshot.gridRequest)) { note in
            workspace.setViewMode(ViewMode(rawValue: note.object as? String ?? "") ?? .grid)
            workspace.activeTab.selection = Set(workspace.activeTab.visibleItems.prefix(1).map(\.url))
            workspace.showInspector = true
        }
        .alert(L("无法完成操作"), isPresented: alertBinding) {
            Button(L("好")) {
                workspace.alertMessage = nil
                if let pending = workspace.renameAfterAlert {
                    workspace.renameAfterAlert = nil
                    DispatchQueue.main.async { pending.tab.renamingURL = pending.url }
                }
            }
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
            Button { workspace.showSidebar.toggle() } label: { Label(L("侧边栏"), systemImage: "sidebar.leading") }
                .help(L("显示 / 隐藏侧边栏 (⌃⌘B)"))
        }
        ToolbarItem(id: "nav", placement: .navigation) {
            ControlGroup {
                Button { workspace.goBack() } label: { Label(L("返回"), systemImage: "chevron.left") }
                    .disabled(!tab.canGoBack)
                    .help(L("返回 (⌘[)"))
                Button { workspace.goForward() } label: { Label(L("前进"), systemImage: "chevron.right") }
                    .disabled(!tab.canGoForward)
                    .help(L("前进 (⌘])"))
            }
            .controlGroupStyle(.navigation)
        }
        ToolbarItem(id: "up", placement: .navigation) {
            Button { workspace.goUp() } label: { Label(L("上层文件夹"), systemImage: "arrow.up") }
                .disabled(!tab.canGoUp)
                .help(L("上层文件夹 (⌘↑)"))
        }

        ToolbarItem(id: "panes", placement: .principal) {
            Picker(L("窗格"), selection: Binding(get: { workspace.paneCount }, set: { workspace.setPaneCount($0) })) {
                Label(L("单窗格"), systemImage: "rectangle").tag(1)
                Label(L("双窗格"), systemImage: "rectangle.split.2x1").tag(2)
                Label(L("三窗格"), systemImage: "rectangle.split.3x1.fill").tag(3)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help(L("窗格布局 (⌃⌘1 / 2 / 3)"))
        }

        ToolbarItem(id: "view", placement: .principal) {
            Picker(L("视图"), selection: Binding(get: { workspace.activeTab.viewMode }, set: { workspace.setViewMode($0) })) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help(L("视图 (⌘1 / ⌘2 / ⌘3 / ⌘4)"))
        }

        ToolbarItem(id: "operations", placement: .primaryAction) { OperationsButton() }
    }

    @ToolbarContentBuilder
    private var optionalToolbar: some CustomizableToolbarContent {

        ToolbarItem(id: "palette", placement: .primaryAction, showsByDefault: false) {
            button(L("命令面板"), "command", "⌘K") { workspace.showPalette.toggle() }
        }
        ToolbarItem(id: "newFolder", placement: .primaryAction, showsByDefault: false) {
            button(L("新建文件夹"), "folder.badge.plus", "⇧⌘N") { workspace.newFolder() }
        }
        ToolbarItem(id: "trash", placement: .primaryAction, showsByDefault: false) {
            button(L("移到废纸篓"), "trash", "⌘⌫") { workspace.moveToTrash() }
        }
        ToolbarItem(id: "copyPath", placement: .primaryAction, showsByDefault: false) {
            button(L("拷贝路径"), "link", "⌥⌘C") { workspace.copyPath() }
        }
        ToolbarItem(id: "terminal", placement: .primaryAction, showsByDefault: false) {
            button(L("终端"), "terminal", "⌥⌘T") { workspace.openInTerminal() }
        }
        ToolbarItem(id: "editor", placement: .primaryAction, showsByDefault: false) {
            button(AppSettings.shared.editorName, "chevron.left.forwardslash.chevron.right", "⌥⌘E") { workspace.openInEditor() }
        }
        ToolbarItem(id: "compare", placement: .primaryAction, showsByDefault: false) {
            button(L("对比窗格"), "arrow.left.arrow.right.square", "⌃⌘C") { workspace.comparePanes() }
        }
        ToolbarItem(id: "sync", placement: .primaryAction, showsByDefault: false) {
            button(L("同步文件夹"), "arrow.triangle.2.circlepath", "⌃⌘Y") {
                if workspace.otherPane == nil { workspace.setPaneCount(2) }
                workspace.showSync = true
            }
        }
        ToolbarItem(id: "server", placement: .primaryAction, showsByDefault: false) {
            button(L("连接服务器"), "server.rack", "⇧⌘K") { workspace.showConnectServer = true }
        }
        ToolbarItem(id: "reload", placement: .primaryAction, showsByDefault: false) {
            button(L("刷新"), "arrow.clockwise", "⌘R") { workspace.activeTab.reload() }
        }

    }

    @ToolbarContentBuilder
    private var trailingToolbar: some CustomizableToolbarContent {
        ToolbarItem(id: "shelf", placement: .primaryAction) {
            button(L("暂存架"), StashShelf.shared.items.isEmpty ? "tray" : "tray.full", "⌥⌘S") { StashShelf.shared.toggle() }
        }

        ToolbarItem(id: "actions", placement: .primaryAction) {
            Menu {
                Button(L("新建文件夹"), systemImage: "folder.badge.plus") { workspace.newFolder() }
                Menu(L("从模板新建"), systemImage: "doc.badge.plus") {
                    ForEach(Templates.all, id: \.self) { template in
                        Button(template.deletingPathExtension().lastPathComponent) { workspace.newFile(from: template) }
                    }
                }
                Divider()
                Button(L("批量重命名…"), systemImage: "character.cursor.ibeam") { workspace.batchRename() }
                Button(L("在终端中打开"), systemImage: "terminal") { workspace.openInTerminal() }
                Button(L("拷贝当前路径"), systemImage: "link") { workspace.copyPath([workspace.activeTab.url]) }
                Button(L("连接服务器…"), systemImage: "server.rack") { workspace.showConnectServer = true }
            } label: {
                Label(L("新建与操作"), systemImage: "plus")
            }
            .help(L("新建与操作"))
        }

        ToolbarItem(id: "hidden", placement: .primaryAction) {
            Toggle(isOn: Binding(get: { AppSettings.shared.showHidden }, set: { AppSettings.shared.showHidden = $0 })) {
                Label(L("隐藏文件"), systemImage: AppSettings.shared.showHidden ? "eye" : "eye.slash")
            }
            .help(L("显示隐藏文件 (⇧⌘.)"))
        }

        ToolbarItem(id: "inspector", placement: .primaryAction) {
            button(L("检查器"), "sidebar.trailing", "⌥⌘I") { workspace.showInspector.toggle() }
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
        case .folder: L("过滤当前文件夹")
        case .subfolders: L("搜索“\(workspace.activeTab.title)”及子文件夹")
        case .spotlight: L("用 Spotlight 搜索名称和内容")
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
