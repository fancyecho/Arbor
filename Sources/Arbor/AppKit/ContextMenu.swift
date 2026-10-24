import AppKit
import SwiftUI

/// One context-menu entry, rendered either as an NSMenuItem (list view) or a SwiftUI Button (grid view).
struct MenuEntry {
    var title: String
    var symbol: String?
    var image: NSImage?
    var isEnabled = true
    var isChecked = false
    /// Stable identity for the "右键菜单" settings when the title is dynamic.
    var key: String?
    var children: [[MenuEntry]] = []
    var action: (() -> Void)?

    init(_ title: String, symbol: String? = nil, image: NSImage? = nil, isEnabled: Bool = true,
         children: [[MenuEntry]] = [], key: String? = nil, action: (() -> Void)? = nil) {
        self.key = key
        self.title = title
        self.symbol = symbol
        self.image = image
        self.isEnabled = isEnabled
        self.children = children
        self.action = action
    }
}

@MainActor
enum ContextMenuBuilder {
    /// Entries that can be switched off in Settings › 右键菜单.
    static let customizable = [
        "打开方式", "显示包内容", "在新标签页中打开", "在另一窗格中打开", "添加到个人收藏", "快速查看",
        "复制", "加入暂存架", "拷贝到另一窗格", "移动到另一窗格", "批量重命名…",
        "拷贝路径", "拷贝路径为", "在终端中打开", "在编辑器中打开", "在访达中显示", "显示简介",
        "标签", "工具", "图片", "自定义命令", "新建文件", "导出目录树", "分析空间占用",
    ]

    /// Sections separated by dividers, minus the entries hidden in Settings.
    static func sections(workspace ws: WorkspaceState, tab: TabState, selected: [FileItem],
                         includeOpenWith: Bool = true) -> [[MenuEntry]] {
        // Settings stores the Chinese names; entries carry their titles (and keys) in the app's language.
        let hidden = Set(AppSettings.shared.hiddenMenuItems.map { L(key: $0) })
        return allSections(workspace: ws, tab: tab, selected: selected, includeOpenWith: includeOpenWith)
            .map { $0.filter { !hidden.contains($0.key ?? $0.title) } }
            .filter { !$0.isEmpty }
    }

    /// Sections separated by dividers. `selected` empty means the menu is for the folder background.
    private static func allSections(workspace ws: WorkspaceState, tab: TabState, selected: [FileItem],
                                    includeOpenWith: Bool) -> [[MenuEntry]] {
        let urls = selected.map(\.url)
        let pasteEntry = MenuEntry(L("粘贴"), symbol: "doc.on.clipboard", isEnabled: ws.canPaste) { ws.paste() }

        guard !selected.isEmpty else {
            return [
                [
                    MenuEntry(L("新建文件夹"), symbol: "folder.badge.plus") { ws.newFolder() },
                    MenuEntry(L("新建文件"), symbol: "doc.badge.plus", children: templateEntries(ws)),
                ],
                [pasteEntry],
                [
                    MenuEntry(L("拷贝当前路径"), symbol: "link") { ws.copyPath([tab.url]) },
                    MenuEntry(L("拷贝路径为"), symbol: "link.badge.plus", children: [pathEntries(ws, [tab.url])]),
                    MenuEntry(L("在终端中打开"), symbol: "terminal") { ws.openInTerminal(tab.url) },
                    MenuEntry(L("在\(AppSettings.shared.editorName)中打开"), symbol: "chevron.left.forwardslash.chevron.right", key: L("在编辑器中打开")) {
                        ws.openInEditor([tab.url])
                    },
                    MenuEntry(L("在访达中显示"), symbol: "macwindow") { ws.revealInFinder([tab.url]) },
                ],
                commandEntries(ws, []),
                [
                    MenuEntry(AppSettings.shared.showHidden ? L("隐藏隐藏文件") : L("显示隐藏文件"), symbol: "eye") { ws.toggleHidden() },
                    MenuEntry(L("批量重命名全部…"), symbol: "character.cursor.ibeam") { ws.batchRename([]) },
                    MenuEntry(L("导出目录树"), symbol: "list.bullet.indent") { ws.exportTree(tab.url) },
                    MenuEntry(L("分析空间占用"), symbol: "chart.pie") { ws.analyzeSpace() },
                ],
            ]
        }

        let single = selected.count == 1 ? selected[0] : nil
        let folder = single.flatMap { $0.isNavigable ? $0.url : TabState.resolvedDirectory($0.url) }

        var open: [MenuEntry] = [MenuEntry(L("打开"), symbol: "arrow.up.forward.app") { ws.openSelection(urls) }]
        // Apps, bundles, libraries… open as one thing; this steps inside instead, like Finder.
        if let single, single.isPackage {
            open.append(MenuEntry(L("显示包内容"), symbol: "shippingbox") {
                ws.activate(ws.panes.first { $0.tabs.contains { $0 === tab } } ?? ws.activePane)
                tab.navigate(to: single.url)
            })
        }
        if includeOpenWith, let single, !single.isNavigable {
            open.append(MenuEntry(L("打开方式"), symbol: "app.badge", children: [openWithEntries(for: single.url, ws: ws, urls: urls)]))
        }
        if let folder {
            open.append(MenuEntry(L("在新标签页中打开"), symbol: "plus.square.on.square") { ws.openInNewTab(folder) })
            open.append(MenuEntry(L("在另一窗格中打开"), symbol: "rectangle.split.2x1") { ws.openInOtherPane(folder) })
            if !SidebarStore.shared.isFavorite(folder) {
                open.append(MenuEntry(L("添加到个人收藏"), symbol: "star") { SidebarStore.shared.addFavorite(folder) })
            }
            open.append(MenuEntry(L("分析空间占用"), symbol: "chart.pie") { ws.analyzeSpace(folder) })
        }
        open.append(MenuEntry(L("快速查看"), symbol: "eye") { ws.quickLook(urls) })

        var transfer: [MenuEntry] = [
            MenuEntry(L("剪切"), symbol: "scissors") { ws.cut(urls) },
            MenuEntry(L("拷贝"), symbol: "doc.on.doc") { ws.copy(urls) },
            pasteEntry,
            MenuEntry(L("复制"), symbol: "plus.square.on.square") { ws.duplicate(urls) },
            MenuEntry(L("加入暂存架"), symbol: "tray.and.arrow.down") { ws.addToShelf(urls) },
        ]
        if ws.otherPane != nil {
            transfer.append(MenuEntry(L("拷贝到另一窗格"), symbol: "arrow.right.doc.on.clipboard") { ws.copyToOtherPane() })
            transfer.append(MenuEntry(L("移动到另一窗格"), symbol: "arrow.right.square") { ws.copyToOtherPane(move: true) })
        }

        return [
            open,
            transfer,
            [
                MenuEntry(L("重命名"), symbol: "pencil", isEnabled: single != nil) { ws.rename(single?.url) },
                MenuEntry(L("批量重命名…"), symbol: "character.cursor.ibeam") { ws.batchRename(urls) },
                MenuEntry(L("移到废纸篓"), symbol: "trash") { ws.moveToTrash(urls) },
            ],
            [
                MenuEntry(L("拷贝路径"), symbol: "link") { ws.copyPath(urls) },
                MenuEntry(L("拷贝路径为"), symbol: "link.badge.plus", children: [pathEntries(ws, urls)]),
                MenuEntry(L("在终端中打开"), symbol: "terminal", isEnabled: folder != nil) { ws.openInTerminal(folder) },
                MenuEntry(L("在\(AppSettings.shared.editorName)中打开"), symbol: "chevron.left.forwardslash.chevron.right", key: L("在编辑器中打开")) {
                    ws.openInEditor(urls)
                },
                MenuEntry(L("在访达中显示"), symbol: "macwindow") { ws.revealInFinder(urls) },
                MenuEntry(L("显示简介"), symbol: "info.circle") { ws.showInspector = true },
            ],
            [tagEntries(ws, urls), toolEntries(ws, urls, single: single, folder: folder)] + imageEntries(ws, urls),
            commandEntries(ws, urls),
        ].filter { !$0.isEmpty }
    }

    private static func tagEntries(_ ws: WorkspaceState, _ urls: [URL]) -> MenuEntry {
        let entries = FinderTags.standard.map { tag in
            var entry = MenuEntry(tag.name, image: FinderTags.dot(tag.color)) { ws.toggleTag(tag.name, urls) }
            entry.isChecked = urls.allSatisfy { FinderTags.tags(of: $0).contains(tag.name) }
            return entry
        }
        return MenuEntry(L("标签"), symbol: "tag", children: [entries])
    }

    /// "图片" submenu, only when everything selected is an image.
    private static func imageEntries(_ ws: WorkspaceState, _ urls: [URL]) -> [MenuEntry] {
        guard !urls.isEmpty, urls.allSatisfy(ImageTools.isImage) else { return [] }
        let convert = ImageFormat.allCases.map { format in
            MenuEntry(L("转换为 \(format.title)")) { ws.runImageJob(.convert(format, maxPixel: nil), urls) }
        }
        let resize = ([3840, 1920, 1280, 800] as [Int]).map { pixels in
            MenuEntry(L("缩小到长边 \(pixels) 像素")) { ws.runImageJob(.convert(.jpeg, maxPixel: pixels), urls) }
        }
        let other = [
            MenuEntry(L("向左旋转"), symbol: "rotate.left") { ws.runImageJob(.rotate(clockwise: false), urls) },
            MenuEntry(L("向右旋转"), symbol: "rotate.right") { ws.runImageJob(.rotate(clockwise: true), urls) },
            MenuEntry(L("合成 PDF"), symbol: "doc.richtext") { ws.runImageJob(.pdf, urls) },
            MenuEntry(L("移除背景"), symbol: "person.crop.rectangle") { ws.runImageJob(.removeBackground, urls) },
        ]
        return [MenuEntry(L("图片"), symbol: "photo", children: [convert, resize, other])]
    }

    private static func templateEntries(_ ws: WorkspaceState) -> [[MenuEntry]] {
        let templates = Templates.all.map { template in
            MenuEntry(template.deletingPathExtension().lastPathComponent,
                      image: { let icon = NSWorkspace.shared.icon(forFile: template.path); icon.size = NSSize(width: 16, height: 16); return icon }()) {
                ws.newFile(from: template)
            }
        }
        return [templates, [MenuEntry(L("打开模板文件夹…"), symbol: "folder") { ws.openTemplatesFolder() }]]
    }

    private static func toolEntries(_ ws: WorkspaceState, _ urls: [URL], single: FileItem?, folder: URL?) -> MenuEntry {
        var tools: [MenuEntry] = [
            MenuEntry(L("用所选项目新建文件夹"), symbol: "folder.badge.plus") { ws.newFolderWithSelection(urls) },
            MenuEntry(L("制作替身"), symbol: "arrowshape.turn.up.right") { ws.makeLinks(alias: true, urls) },
            MenuEntry(L("创建符号链接"), symbol: "link") { ws.makeLinks(alias: false, urls) },
            MenuEntry(L("计算哈希（MD5 / SHA）"), symbol: "number") { ws.showHashes(urls) },
        ]
        if let folder {
            tools.append(MenuEntry(L("平铺文件夹"), symbol: "square.stack.3d.down.right") { ws.flatten(folder) })
            tools.append(MenuEntry(L("导出目录树"), symbol: "list.bullet.indent") { ws.exportTree(folder) })
        }
        return MenuEntry(L("工具"), symbol: "wrench.and.screwdriver", children: [tools])
    }

    private static func pathEntries(_ ws: WorkspaceState, _ urls: [URL]) -> [MenuEntry] {
        PathStyle.allCases.map { style in
            MenuEntry(style.title + L("　") + PathFormatter.format(urls.prefix(1).map { $0 }, style)) {
                ws.copyPath(urls, as: style)
            }
        }
    }

    /// "自定义命令" submenu (empty section when there are none).
    private static func commandEntries(_ ws: WorkspaceState, _ urls: [URL]) -> [MenuEntry] {
        let commands = AppSettings.shared.customCommands
        guard !commands.isEmpty else { return [] }
        let items = commands.map { command in
            MenuEntry(command.name, symbol: command.mode == .terminal ? "terminal" : "gearshape") {
                ws.run(command, on: urls)
            }
        }
        return [MenuEntry(L("自定义命令"), symbol: "command", children: [items])]
    }

    private static func openWithEntries(for url: URL, ws: WorkspaceState, urls: [URL]) -> [MenuEntry] {
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        if let defaultApp { apps.removeAll { $0 == defaultApp }; apps.insert(defaultApp, at: 0) }
        return apps.prefix(20).map { app in
            var name = FileManager.default.displayName(atPath: app.path)
            if app == defaultApp { name += L("（默认）") }
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            return MenuEntry(name, image: icon) { ws.open(with: app, urls) }
        }
    }

    // MARK: NSMenu rendering

    static func build(into menu: NSMenu, workspace: WorkspaceState, tab: TabState, selected: [FileItem]) {
        append(sections(workspace: workspace, tab: tab, selected: selected), to: menu)
    }

    private static func append(_ sections: [[MenuEntry]], to menu: NSMenu) {
        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for entry in section {
                let item = ClosureMenuItem(title: entry.title, handler: entry.action)
                item.isEnabled = entry.isEnabled
                item.state = entry.isChecked ? .on : .off
                if let image = entry.image {
                    item.image = image
                } else if let symbol = entry.symbol {
                    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                }
                if !entry.children.isEmpty {
                    let submenu = NSMenu()
                    append(entry.children, to: submenu)
                    item.submenu = submenu
                }
                menu.addItem(item)
            }
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: (() -> Void)?

    init(title: String, handler: (() -> Void)?) {
        self.handler = handler
        super.init(title: title, action: handler == nil ? nil : #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler?() }
}

// MARK: SwiftUI rendering

struct MenuEntriesView: View {
    let sections: [[MenuEntry]]

    var body: some View {
        ForEach(sections.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(sections[index].indices, id: \.self) { row in
                entryView(sections[index][row])
            }
        }
    }

    @ViewBuilder
    private func entryView(_ entry: MenuEntry) -> some View {
        if !entry.children.isEmpty {
            Menu(entry.title) { MenuEntriesView(sections: entry.children) }
        } else if entry.isChecked {
            Button { entry.action?() } label: { Label(entry.title, systemImage: "checkmark") }
                .disabled(!entry.isEnabled)
        } else if let image = entry.image {
            Button { entry.action?() } label: { Label { Text(entry.title) } icon: { Image(nsImage: image) } }
                .disabled(!entry.isEnabled)
        } else {
            Button { entry.action?() } label: { Label(entry.title, systemImage: entry.symbol ?? "circle") }
                .disabled(!entry.isEnabled)
        }
    }
}
