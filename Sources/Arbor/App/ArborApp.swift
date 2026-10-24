import AppKit
import Quartz
import SwiftUI

@main
struct ArborApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppLanguage.settleFirstLaunch()
    }

    var body: some Scene {
        WindowGroup("Arbor", id: "browser") {
            ContentView()
                .frame(minHeight: 480)
        }
        .defaultSize(width: 1280, height: 780)
        // Files and folders sent to Arbor (Dock drops, `open -a`, other apps' "show in file viewer")
        // go to the app delegate, which opens them as a tab. Left to itself SwiftUI would open a blank
        // new window for each and drop the file.
        .handlesExternalEvents(matching: [])
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { ArborCommands() }

        Settings {
            SettingsView()
        }

        MenuBarExtra("Arbor", systemImage: "tree", isInserted: Binding(
            get: { AppSettings.shared.showMenuBarIcon },
            set: { AppSettings.shared.showMenuBarIcon = $0 })) {
            MenuBarContent()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServiceProvider()
    private let dockMenu = DockMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        if !Snapshot.isActive {
            MainActor.assumeIsolated { AppSettings.shared.applyAppearance() }
        }
        // Dock › Quit, logout and shutdown arrive as a quit Apple event; route them past open sheets too.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuit(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEQuitApplication))
        Snapshot.scheduleIfRequested()
        if !Snapshot.isActive {
            MainActor.assumeIsolated { GlobalHotKey.shared.register(AppSettings.shared.hotKey) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                MainActor.assumeIsolated { Updater.shared.checkInBackgroundIfDue() }
            }
        }
    }

    @objc private func handleQuit(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated { AppActions.quit() }
    }

    /// With the menu bar icon (and its hotkey) Arbor keeps running after the last window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !AppSettings.shared.showMenuBarIcon }
    }

    /// Clicking the Dock icon with every browser window closed opens a new one. SwiftUI's own
    /// handling skips this when any window is still visible (the stash shelf, the menu bar extra's
    /// hidden panel), so Arbor decides by its browser windows only.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            if !AppActions.hasBrowserWindow { AppActions.show() }
        }
        return false
    }

    /// Right-clicking the Dock icon: a new window, favorites and saved workspaces.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        var menu: NSMenu?
        MainActor.assumeIsolated { menu = dockMenu.build() }
        return menu
    }

    /// Folders/files dropped on the Dock icon or opened with `open -a Arbor <path>`.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls where url.isFileURL { AppActions.show(url) }
        }
    }

    // The app delegate is the last stop of every responder chain, so claiming Quick Look
    // control here makes the panel work no matter which view has focus.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookController.shared
        panel.delegate = QuickLookController.shared
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

// MARK: - Menu commands

struct ArborCommands: Commands {
    @FocusedValue(\.workspace) private var workspace

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(L("检查更新…")) { Updater.shared.check(userInitiated: true) }
        }

        CommandGroup(replacing: .appTermination) {
            Button(L("退出 Arbor")) { AppActions.quit() }
                .keyboardShortcut("q")
        }

        CommandGroup(after: .newItem) {
            Button(L("命令面板…")) { workspace?.showPalette.toggle() }
                .shortcut("命令面板…", KeyboardShortcut("k"))
                .disabled(workspace == nil)
            Divider()
            Button(L("新建标签页")) { workspace?.newTab() }
                .shortcut("新建标签页", KeyboardShortcut("t"))
                .disabled(workspace == nil)
            Button(L("新建文件夹")) { workspace?.newFolder() }
                .shortcut("新建文件夹", KeyboardShortcut("n", modifiers: [.command, .shift]))
                .disabled(workspace == nil)
            Button(L("新建文本文件")) { workspace?.newFile() }
                .shortcut("新建文本文件", KeyboardShortcut("n", modifiers: [.command, .option]))
                .disabled(workspace == nil)
            Menu(L("从模板新建")) {
                ForEach(Templates.all, id: \.self) { template in
                    Button(template.deletingPathExtension().lastPathComponent) { workspace?.newFile(from: template) }
                }
                Divider()
                Button(L("打开模板文件夹…")) { workspace?.openTemplatesFolder() }
            }
            .disabled(workspace == nil)
            Button(L("用所选项目新建文件夹")) { workspace?.newFolderWithSelection() }
                .shortcut("用所选项目新建文件夹", KeyboardShortcut("n", modifiers: [.command, .control]))
                .disabled(workspace?.hasSelection != true)
            Divider()
            Button(L("打开")) { workspace?.openSelection() }
                .shortcut("打开", KeyboardShortcut("o"))
                .disabled(workspace?.hasSelection != true)
            Button(L("在新标签页中打开")) { workspace?.openInNewTab() }
                .disabled(workspace == nil)
            Button(L("在另一窗格中打开")) { workspace?.openInOtherPane() }
                .shortcut("在另一窗格中打开", KeyboardShortcut("o", modifiers: [.command, .option]))
                .disabled(workspace == nil)
            Button(L("快速查看")) { workspace?.quickLook() }
                .shortcut("快速查看", KeyboardShortcut("y"))
                .disabled(workspace?.hasSelection != true)
            Divider()
            Button(L("关闭标签页")) { workspace?.closeTab() }
                .shortcut("关闭标签页", KeyboardShortcut("w"))
            Button(L("重新打开关闭的标签页")) { workspace?.reopenClosedTab() }
                .shortcut("重新打开关闭的标签页", KeyboardShortcut("t", modifiers: [.command, .shift]))
                .disabled(workspace?.recentlyClosed.isEmpty != false)
            Button(workspace?.activeTab.isPinned == true ? L("取消固定标签页") : L("固定标签页")) {
                guard let workspace else { return }
                workspace.activePane.togglePin(workspace.activePane.activeTabID)
            }
            .disabled(workspace == nil)
        }

        CommandGroup(replacing: .undoRedo) {
            let history = FileHistory.shared
            Button(history.undoTitle.map { L("撤销\($0)") } ?? L("撤销")) {
                textOr(Selector(("undo:"))) { workspace?.undo() }
            }
            .keyboardShortcut("z")
            Button(history.redoTitle.map { L("重做\($0)") } ?? L("重做")) {
                textOr(Selector(("redo:"))) { workspace?.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .pasteboard) {
            Button(L("剪切")) { textOr(#selector(NSText.cut(_:))) { workspace?.cut() } }
                .keyboardShortcut("x")
            Button(L("拷贝")) { textOr(#selector(NSText.copy(_:))) { workspace?.copy() } }
                .keyboardShortcut("c")
            Button(L("粘贴")) { textOr(#selector(NSText.paste(_:))) { workspace?.paste() } }
                .keyboardShortcut("v")
            Button(L("全选")) { textOr(#selector(NSText.selectAll(_:))) { workspace?.selectAll() } }
                .keyboardShortcut("a")
            Divider()
            Button(L("复制")) { workspace?.duplicate() }
                .shortcut("复制", KeyboardShortcut("d"))
                .disabled(workspace?.hasSelection != true)
            Button(L("重命名")) { workspace?.rename() }
                .disabled(workspace?.hasSelection != true)
            Button(L("批量重命名…")) { workspace?.batchRename() }
                .shortcut("批量重命名…", KeyboardShortcut("r", modifiers: [.command, .shift]))
                .disabled(workspace == nil)
            Button(L("移到废纸篓")) {
                textOr(#selector(NSResponder.deleteToBeginningOfLine(_:))) { workspace?.moveToTrash() }
            }
            .shortcut("移到废纸篓", KeyboardShortcut(.delete))
            Divider()
            Menu(L("对比并选择")) {
                ForEach(CompareSelection.allCases) { mode in
                    Button(mode.title) { workspace?.comparePanes(select: mode) }
                }
                Divider()
                Button(L("清除对比标记")) { workspace?.clearComparison() }
            }
            Button(L("对比两个窗格")) { workspace?.comparePanes() }
                .shortcut("对比两个窗格", KeyboardShortcut("c", modifiers: [.command, .control]))
                .disabled(workspace == nil)
            Button(L("加入暂存架")) { workspace?.addToShelf() }
                .shortcut("加入暂存架", KeyboardShortcut("a", modifiers: [.command, .option]))
                .disabled(workspace?.hasSelection != true)
            Button(StashShelf.shared.isVisible ? L("隐藏暂存架") : L("显示暂存架")) { StashShelf.shared.toggle() }
                .shortcut("显示 / 隐藏暂存架", KeyboardShortcut("s", modifiers: [.command, .option]))
            Button(L("同步文件夹…")) {
                if workspace?.otherPane == nil { workspace?.setPaneCount(2) }
                workspace?.showSync = true
            }
            .shortcut("同步文件夹…", KeyboardShortcut("y", modifiers: [.command, .control]))
            .disabled(workspace == nil)
            Divider()
            Button(L("拷贝到另一窗格")) { workspace?.copyToOtherPane() }
                .shortcut("拷贝到另一窗格", KeyboardShortcut(.rightArrow, modifiers: [.command, .option]))
                .disabled(workspace?.otherPane == nil)
            Button(L("移动到另一窗格")) { workspace?.copyToOtherPane(move: true) }
                .shortcut("移动到另一窗格", KeyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift]))
                .disabled(workspace?.otherPane == nil)
            Divider()
            Button(L("拷贝路径")) { workspace?.copyPath() }
                .shortcut("拷贝路径", KeyboardShortcut("c", modifiers: [.command, .option]))
            Menu(L("拷贝路径为")) {
                ForEach(PathStyle.allCases) { style in
                    Button(style.title) { workspace?.copyPath(as: style) }
                }
            }
            Button(L("在终端中打开")) { workspace?.openInTerminal() }
                .shortcut("在终端中打开", KeyboardShortcut("t", modifiers: [.command, .option]))
            Button(L("在\(AppSettings.shared.editorName)中打开")) { workspace?.openInEditor() }
                .shortcut("在编辑器中打开", KeyboardShortcut("e", modifiers: [.command, .option]))
            Button(L("在访达中显示")) { workspace?.revealInFinder() }
                .shortcut("在访达中显示", KeyboardShortcut("r", modifiers: [.command, .option]))
        }

        CommandGroup(before: .toolbar) {
            Button(L("列表视图")) { workspace?.setViewMode(.list) }
                .shortcut("列表视图", KeyboardShortcut("1"))
            Button(L("图标视图")) { workspace?.setViewMode(.grid) }
                .shortcut("图标视图", KeyboardShortcut("2"))
            Button(L("分栏视图")) { workspace?.setViewMode(.columns) }
                .shortcut("分栏视图", KeyboardShortcut("3"))
            Button(L("空间视图")) { workspace?.setViewMode(.space) }
                .shortcut("空间视图", KeyboardShortcut("4"))
            Divider()
            Button(L("单窗格")) { workspace?.setPaneCount(1) }
                .shortcut("单窗格", KeyboardShortcut("1", modifiers: [.command, .control]))
            Button(L("双窗格")) { workspace?.setPaneCount(2) }
                .shortcut("双窗格", KeyboardShortcut("2", modifiers: [.command, .control]))
            Button(L("三窗格")) { workspace?.setPaneCount(3) }
                .shortcut("三窗格", KeyboardShortcut("3", modifiers: [.command, .control]))
            Button(L("切换到下一个窗格")) { workspace?.focusNextPane() }
                .shortcut("切换到下一个窗格", KeyboardShortcut("`", modifiers: [.control]))
            Divider()
            Button(AppSettings.shared.showHidden ? L("隐藏隐藏文件") : L("显示隐藏文件")) { workspace?.toggleHidden() }
                .shortcut("显示 / 隐藏隐藏文件", KeyboardShortcut(".", modifiers: [.command, .shift]))
            Button(workspace?.showInspector == true ? L("隐藏检查器") : L("显示检查器")) { workspace?.showInspector.toggle() }
                .shortcut("显示 / 隐藏检查器", KeyboardShortcut("i", modifiers: [.command, .option]))
            Button(L("显示 / 隐藏侧边栏")) { workspace?.showSidebar.toggle() }
                .shortcut("显示 / 隐藏侧边栏", KeyboardShortcut("b", modifiers: [.command, .control]))
            Button(L("搜索子文件夹")) { workspace?.search(in: .subfolders) }
                .shortcut("搜索子文件夹", KeyboardShortcut("f", modifiers: [.command, .option]))
            Button(L("Spotlight 搜索")) { workspace?.search(in: .spotlight) }
                .shortcut("Spotlight 搜索", KeyboardShortcut("f", modifiers: [.command, .option, .shift]))
            Button(L("按条件选择…")) { workspace?.showSelectByCondition = true }
                .shortcut("按条件选择…", KeyboardShortcut("a", modifiers: [.command, .control]))
            Button(L("选择同类型")) { workspace?.selectSameType() }
                .disabled(workspace?.hasSelection != true)
            Divider()
            Button(L("刷新")) { workspace?.activeTab.reload() }
                .shortcut("刷新", KeyboardShortcut("r"))
            Divider()
        }

        CommandMenu(L("前往")) {
            Button(L("连接服务器…")) { workspace?.showConnectServer = true }
                .shortcut("连接服务器…", KeyboardShortcut("k", modifiers: [.command, .shift]))
                .disabled(workspace == nil)
            Divider()
            Button(L("返回")) { workspace?.goBack() }
                .shortcut("返回", KeyboardShortcut("["))
                .disabled(workspace?.activeTab.canGoBack != true)
            Button(L("前进")) { workspace?.goForward() }
                .shortcut("前进", KeyboardShortcut("]"))
                .disabled(workspace?.activeTab.canGoForward != true)
            Button(L("上层文件夹")) { workspace?.goUp() }
                .shortcut("上层文件夹", KeyboardShortcut(.upArrow))
            Button(L("打开所选项")) { workspace?.openSelection() }
                .shortcut("打开所选项", KeyboardShortcut(.downArrow))
                .disabled(workspace?.hasSelection != true)
            Divider()
            ForEach(Places.favorites, id: \.url) { place in
                Button(place.name) { workspace?.go(to: place.url) }
                    .optionalShortcut(place.shortcut, modifiers: [.command, .shift])
            }
            Divider()
            Button(L("下一个标签页")) { workspace?.activePane.selectNextTab(1) }
                .shortcut("下一个标签页", KeyboardShortcut("}", modifiers: [.command, .shift]))
            Button(L("上一个标签页")) { workspace?.activePane.selectNextTab(-1) }
                .shortcut("上一个标签页", KeyboardShortcut("{", modifiers: [.command, .shift]))
        }

        CommandMenu(L("工作区")) {
            Button(L("存储为工作区…")) { workspace?.workspaceNameRequest = .save }
                .shortcut("存储为工作区…", KeyboardShortcut("s", modifiers: [.command, .control]))
                .disabled(workspace == nil)
            let saved = WorkspaceLibrary.shared.saved
            if !saved.isEmpty {
                Divider()
                ForEach(Array(saved.enumerated()), id: \.element.id) { index, entry in
                    Button(entry.name) { workspace?.open(entry) }
                        .optionalShortcut(index < 9 ? Character("\(index + 1)") : nil, modifiers: [.command, .option])
                }
                Divider()
                Menu(L("用当前布局更新")) {
                    ForEach(saved) { entry in
                        Button(entry.name) { workspace?.updateSavedWorkspace(entry) }
                    }
                }
                .disabled(workspace == nil)
            }
        }
    }

    /// Text fields keep their standard editing commands; otherwise the file command runs.
    private func textOr(_ selector: Selector, _ fileAction: () -> Void) {
        if NSApp.keyWindow?.firstResponder is NSText {
            NSApp.sendAction(selector, to: nil, from: nil)
        } else {
            fileAction()
        }
    }
}

extension View {
    @ViewBuilder
    func optionalShortcut(_ key: Character?, modifiers: EventModifiers) -> some View {
        if let key { keyboardShortcut(KeyEquivalent(key), modifiers: modifiers) } else { self }
    }
}
