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
            cmd(L("新建文件夹"), "folder.badge.plus", "⇧⌘N") { ws.newFolder() },
            cmd(L("新建文本文件"), "doc.badge.plus", "⌥⌘N") { ws.newFile() },
            cmd(L("新建标签页"), "plus.square", "⌘T") { ws.newTab() },
            cmd(L("重新打开关闭的标签页"), "arrow.uturn.backward.square", "⇧⌘T") { ws.reopenClosedTab() },
            cmd(L("固定 / 取消固定标签页"), "pin") { ws.activePane.togglePin(ws.activePane.activeTabID) },
            cmd(L("撤销"), "arrow.uturn.backward", "⌘Z") { ws.undo() },
            cmd(L("重做"), "arrow.uturn.forward", "⇧⌘Z") { ws.redo() },
            cmd(L("批量重命名"), "character.cursor.ibeam", "⇧⌘R") { ws.batchRename() },
            cmd(L("移到废纸篓"), "trash", "⌘⌫") { ws.moveToTrash() },
            cmd(L("复制所选项目"), "plus.square.on.square", "⌘D") { ws.duplicate() },
            cmd(L("拷贝到另一窗格"), "arrow.right.doc.on.clipboard", "⌥⌘→") { ws.copyToOtherPane() },
            cmd(L("对比两个窗格"), "arrow.left.arrow.right.square", "⌃⌘C") { ws.comparePanes() },
            cmd(L("对比：只选较新的"), "arrow.left.arrow.right.square") { ws.comparePanes(select: .newer) },
            cmd(L("对比：只选仅此侧有的"), "arrow.left.arrow.right.square") { ws.comparePanes(select: .onlyHere) },
            cmd(L("清除对比标记"), "xmark.square") { ws.clearComparison() },
            cmd(L("加入暂存架"), "tray.and.arrow.down", "⌥⌘A") { ws.addToShelf() },
            cmd(L("显示 / 隐藏暂存架"), "tray", "⌥⌘S") { StashShelf.shared.toggle() },
            cmd(L("同步文件夹"), "arrow.triangle.2.circlepath", "⌃⌘Y") {
                if ws.otherPane == nil { ws.setPaneCount(2) }
                ws.showSync = true
            },
            cmd(L("移动到另一窗格"), "arrow.right.square", "⇧⌥⌘→") { ws.copyToOtherPane(move: true) },
            cmd(L("全选"), "checkmark.circle", "⌘A") { ws.selectAll() },
            cmd(L("搜索子文件夹"), "magnifyingglass", "⌥⌘F") { ws.search(in: .subfolders) },
            cmd(L("Spotlight 搜索"), "sparkle.magnifyingglass", "⇧⌥⌘F") { ws.search(in: .spotlight) },
            cmd(L("按条件选择"), "line.3.horizontal.decrease.circle", "⌃⌘A") { ws.showSelectByCondition = true },
            cmd(L("选择同类型"), "square.on.square") { ws.selectSameType() },
            cmd(L("显示 / 隐藏隐藏文件"), "eye", "⇧⌘.") { ws.toggleHidden() },
            cmd(L("外观：跟随系统"), "circle.lefthalf.filled") { AppSettings.shared.appearance = .system },
            cmd(L("外观：浅色"), "sun.max") { AppSettings.shared.appearance = .light },
            cmd(L("外观：深色"), "moon") { AppSettings.shared.appearance = .dark },
            cmd(L("显示 / 隐藏检查器"), "sidebar.trailing", "⌥⌘I") { ws.showInspector.toggle() },
            cmd(L("单窗格"), "rectangle", "⌃⌘1") { ws.setPaneCount(1) },
            cmd(L("双窗格"), "rectangle.split.2x1", "⌃⌘2") { ws.setPaneCount(2) },
            cmd(L("三窗格"), "rectangle.split.3x1", "⌃⌘3") { ws.setPaneCount(3) },
            cmd(L("切换到下一个窗格"), "arrow.left.arrow.right", "⇥") { ws.focusNextPane() },
            cmd(L("列表视图"), "list.bullet", "⌘1") { ws.setViewMode(.list) },
            cmd(L("图标视图"), "square.grid.2x2", "⌘2") { ws.setViewMode(.grid) },
            cmd(L("分栏视图"), "rectangle.split.3x1", "⌘3") { ws.setViewMode(.columns) },
            cmd(L("空间视图：分析空间占用"), "chart.pie", "⌘4") { ws.analyzeSpace() },
            cmd(L("扫描整个磁盘"), "internaldrive") { ws.analyzeSpace(URL(fileURLWithPath: "/")) },
            cmd(L("在终端中打开"), "terminal", "⌥⌘T") { ws.openInTerminal() },
            cmd(L("在\(AppSettings.shared.editorName)中打开"), "chevron.left.forwardslash.chevron.right", "⌥⌘E") { ws.openInEditor() },
            cmd(L("在访达中显示"), "macwindow", "⌥⌘R") { ws.revealInFinder() },
            cmd(L("快速查看"), "eye", L("空格")) { ws.quickLook() },
            cmd(L("存储为工作区"), "square.stack.3d.up", "⌃⌘S") { ws.workspaceNameRequest = .save },
            cmd(L("刷新"), "arrow.clockwise", "⌘R") { ws.activeTab.reload() },
            cmd(L("检查更新"), "arrow.down.circle") { Updater.shared.check(userInitiated: true) },
            cmd(L("返回"), "chevron.left", "⌘[") { ws.goBack() },
            cmd(L("前进"), "chevron.right", "⌘]") { ws.goForward() },
            cmd(L("上层文件夹"), "arrow.up", "⌘↑") { ws.goUp() },
        ]
        items += [
            cmd(L("用所选项目新建文件夹"), "folder.badge.plus", "⌃⌘N") { ws.newFolderWithSelection() },
            cmd(L("平铺文件夹"), "square.stack.3d.down.right") { ws.flatten() },
            cmd(L("制作替身"), "arrowshape.turn.up.right") { ws.makeLinks(alias: true) },
            cmd(L("创建符号链接"), "link") { ws.makeLinks(alias: false) },
            cmd(L("计算哈希"), "number") { ws.showHashes() },
            cmd(L("导出目录树"), "list.bullet.indent") { ws.exportTree() },
            cmd(L("打开模板文件夹"), "folder") { ws.openTemplatesFolder() },
            cmd(L("连接服务器"), "server.rack", "⇧⌘K") { ws.showConnectServer = true },
        ]
        for template in Templates.all {
            items.append(cmd(L("新建：") + template.deletingPathExtension().lastPathComponent, "doc.badge.plus") { ws.newFile(from: template) })
        }
        for style in PathStyle.allCases {
            items.append(cmd(L("拷贝路径：\(style.title)"), "link") { ws.copyPath(as: style) })
        }
        return items
    }

    static func workspaces(_ ws: WorkspaceState) -> [PaletteItem] {
        WorkspaceLibrary.shared.saved.map { saved in
            PaletteItem(id: "ws:" + saved.id.uuidString, kind: .workspace, title: saved.name,
                        subtitle: L("工作区 · ") + saved.summary, symbol: "square.stack.3d.up") { ws.open(saved) }
        }
    }

    static func customCommands(_ ws: WorkspaceState) -> [PaletteItem] {
        AppSettings.shared.customCommands.map { command in
            PaletteItem(id: "custom:" + command.id.uuidString, kind: .custom, title: command.name,
                        subtitle: L("自定义命令 · ") + command.mode.title,
                        symbol: command.mode == .terminal ? "terminal" : "gearshape") { ws.run(command) }
        }
    }
}
