import AppKit

/// Something the ⌘K palette can run.
struct PaletteItem: Identifiable {
    enum Kind: Int { case path, folder, command, workspace, custom }

    let id: String
    let kind: Kind
    let title: String
    var subtitle: String?
    var symbol: String
    var icon: NSImage?
    var shortcut: String?
    var score: Double = 0
    /// For folders: the URL, so ⌘↩ / ⌥↩ can open it in a new tab / the other pane.
    var url: URL?
    let action: @MainActor () -> Void
}

@MainActor
enum PaletteCommands {
    /// Every built-in command. Titles are what users type (Chinese, pinyin or initials all match).
    static func all(_ ws: WorkspaceState) -> [PaletteItem] {
        func cmd(_ title: String, _ symbol: String, _ shortcut: String? = nil, _ action: @escaping @MainActor () -> Void) -> PaletteItem {
            PaletteItem(id: "cmd:" + title, kind: .command, title: title, symbol: symbol, shortcut: shortcut, action: action)
        }
        var items: [PaletteItem] = [
            cmd("新建文件夹", "folder.badge.plus", "⇧⌘N") { ws.newFolder() },
            cmd("新建文本文件", "doc.badge.plus", "⌥⌘N") { ws.newFile() },
            cmd("新建标签页", "plus.square", "⌘T") { ws.newTab() },
            cmd("重新打开关闭的标签页", "arrow.uturn.backward.square", "⇧⌘T") { ws.reopenClosedTab() },
            cmd("固定 / 取消固定标签页", "pin") { ws.activePane.togglePin(ws.activePane.activeTabID) },
            cmd("撤销", "arrow.uturn.backward", "⌘Z") { ws.undo() },
            cmd("重做", "arrow.uturn.forward", "⇧⌘Z") { ws.redo() },
            cmd("批量重命名", "character.cursor.ibeam", "⇧⌘R") { ws.batchRename() },
            cmd("移到废纸篓", "trash", "⌘⌫") { ws.moveToTrash() },
            cmd("复制所选项目", "plus.square.on.square", "⌘D") { ws.duplicate() },
            cmd("拷贝到另一窗格", "arrow.right.doc.on.clipboard", "⌥⌘→") { ws.copyToOtherPane() },
            cmd("对比两个窗格", "arrow.left.arrow.right.square", "⌃⌘C") { ws.comparePanes() },
            cmd("对比：只选较新的", "arrow.left.arrow.right.square") { ws.comparePanes(select: .newer) },
            cmd("对比：只选仅此侧有的", "arrow.left.arrow.right.square") { ws.comparePanes(select: .onlyHere) },
            cmd("清除对比标记", "xmark.square") { ws.clearComparison() },
            cmd("加入暂存架", "tray.and.arrow.down", "⌥⌘A") { ws.addToShelf() },
            cmd("显示 / 隐藏暂存架", "tray", "⌥⌘S") { StashShelf.shared.toggle() },
            cmd("同步文件夹", "arrow.triangle.2.circlepath", "⌃⌘Y") {
                if ws.otherPane == nil { ws.setPaneCount(2) }
                ws.showSync = true
            },
            cmd("移动到另一窗格", "arrow.right.square", "⇧⌥⌘→") { ws.copyToOtherPane(move: true) },
            cmd("全选", "checkmark.circle", "⌘A") { ws.selectAll() },
            cmd("搜索子文件夹", "magnifyingglass", "⌥⌘F") { ws.search(in: .subfolders) },
            cmd("Spotlight 搜索", "sparkle.magnifyingglass", "⇧⌥⌘F") { ws.search(in: .spotlight) },
            cmd("按条件选择", "line.3.horizontal.decrease.circle", "⌃⌘A") { ws.showSelectByCondition = true },
            cmd("选择同类型", "square.on.square") { ws.selectSameType() },
            cmd("显示 / 隐藏隐藏文件", "eye", "⇧⌘.") { ws.toggleHidden() },
            cmd("外观：跟随系统", "circle.lefthalf.filled") { AppSettings.shared.appearance = .system },
            cmd("外观：浅色", "sun.max") { AppSettings.shared.appearance = .light },
            cmd("外观：深色", "moon") { AppSettings.shared.appearance = .dark },
            cmd("显示 / 隐藏检查器", "sidebar.trailing", "⌥⌘I") { ws.showInspector.toggle() },
            cmd("单窗格", "rectangle", "⌃⌘1") { ws.setPaneCount(1) },
            cmd("双窗格", "rectangle.split.2x1", "⌃⌘2") { ws.setPaneCount(2) },
            cmd("三窗格", "rectangle.split.3x1", "⌃⌘3") { ws.setPaneCount(3) },
            cmd("切换到下一个窗格", "arrow.left.arrow.right", "⇥") { ws.focusNextPane() },
            cmd("列表视图", "list.bullet", "⌘1") { ws.setViewMode(.list) },
            cmd("图标视图", "square.grid.2x2", "⌘2") { ws.setViewMode(.grid) },
            cmd("分栏视图", "rectangle.split.3x1", "⌘3") { ws.setViewMode(.columns) },
            cmd("空间视图：分析空间占用", "chart.pie", "⌘4") { ws.analyzeSpace() },
            cmd("扫描整个磁盘", "internaldrive") { ws.analyzeSpace(URL(fileURLWithPath: "/")) },
            cmd("在终端中打开", "terminal", "⌥⌘T") { ws.openInTerminal() },
            cmd("在\(AppSettings.shared.editorName)中打开", "chevron.left.forwardslash.chevron.right", "⌥⌘E") { ws.openInEditor() },
            cmd("在访达中显示", "macwindow", "⌥⌘R") { ws.revealInFinder() },
            cmd("快速查看", "eye", "空格") { ws.quickLook() },
            cmd("存储为工作区", "square.stack.3d.up", "⌃⌘S") { ws.workspaceNameRequest = .save },
            cmd("刷新", "arrow.clockwise", "⌘R") { ws.activeTab.reload() },
            cmd("检查更新", "arrow.down.circle") { Updater.shared.check(userInitiated: true) },
            cmd("返回", "chevron.left", "⌘[") { ws.goBack() },
            cmd("前进", "chevron.right", "⌘]") { ws.goForward() },
            cmd("上层文件夹", "arrow.up", "⌘↑") { ws.goUp() },
        ]
        items += [
            cmd("用所选项目新建文件夹", "folder.badge.plus", "⌃⌘N") { ws.newFolderWithSelection() },
            cmd("平铺文件夹", "square.stack.3d.down.right") { ws.flatten() },
            cmd("制作替身", "arrowshape.turn.up.right") { ws.makeLinks(alias: true) },
            cmd("创建符号链接", "link") { ws.makeLinks(alias: false) },
            cmd("计算哈希", "number") { ws.showHashes() },
            cmd("导出目录树", "list.bullet.indent") { ws.exportTree() },
            cmd("打开模板文件夹", "folder") { ws.openTemplatesFolder() },
            cmd("连接服务器", "server.rack", "⇧⌘K") { ws.showConnectServer = true },
        ]
        for template in Templates.all {
            items.append(cmd("新建：" + template.deletingPathExtension().lastPathComponent, "doc.badge.plus") { ws.newFile(from: template) })
        }
        for style in PathStyle.allCases {
            items.append(cmd("拷贝路径：\(style.title)", "link") { ws.copyPath(as: style) })
        }
        return items
    }

    static func workspaces(_ ws: WorkspaceState) -> [PaletteItem] {
        WorkspaceLibrary.shared.saved.map { saved in
            PaletteItem(id: "ws:" + saved.id.uuidString, kind: .workspace, title: saved.name,
                        subtitle: "工作区 · " + saved.summary, symbol: "square.stack.3d.up") { ws.open(saved) }
        }
    }

    static func customCommands(_ ws: WorkspaceState) -> [PaletteItem] {
        AppSettings.shared.customCommands.map { command in
            PaletteItem(id: "custom:" + command.id.uuidString, kind: .custom, title: command.name,
                        subtitle: "自定义命令 · " + command.mode.title,
                        symbol: command.mode == .terminal ? "terminal" : "gearshape") { ws.run(command) }
        }
    }
}
