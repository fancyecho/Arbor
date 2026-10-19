import AppKit
import SwiftUI

/// A user-chosen menu shortcut, stored by key + modifiers.
struct ShortcutSpec: Codable, Equatable {
    var key: String
    var modifiers: Int

    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(Self.equivalent(key), modifiers: EventModifiers(rawValue: modifiers))
    }

    private static let specials: [String: KeyEquivalent] = [
        "delete": .delete, "up": .upArrow, "down": .downArrow, "left": .leftArrow, "right": .rightArrow,
        "return": .return, "space": .space, "tab": .tab, "escape": .escape,
    ]

    static func equivalent(_ key: String) -> KeyEquivalent {
        specials[key] ?? KeyEquivalent(Character(key))
    }

    init(key: String, modifiers: Int) {
        self.key = key
        self.modifiers = modifiers
    }

    init(_ shortcut: KeyboardShortcut) {
        let special = Self.specials.first { $0.value == shortcut.key }?.key
        self.init(key: special ?? String(shortcut.key.character), modifiers: shortcut.modifiers.rawValue)
    }

    var display: String {
        let flags = EventModifiers(rawValue: modifiers)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        let names = ["delete": "⌫", "up": "↑", "down": "↓", "left": "←", "right": "→", "return": "↩", "space": "Space",
                     "tab": "⇥", "escape": "⎋"]
        return text + (names[key] ?? key.uppercased())
    }
}

/// Every menu command whose shortcut can be changed in Settings, with its default (generated from ArborApp.swift).
enum ShortcutCatalog {
    static let entries: [(title: String, defaultShortcut: KeyboardShortcut)] = [
        ("命令面板…", KeyboardShortcut("k")),
        ("新建标签页", KeyboardShortcut("t")),
        ("新建文件夹", KeyboardShortcut("n", modifiers: [.command, .shift])),
        ("新建文本文件", KeyboardShortcut("n", modifiers: [.command, .option])),
        ("用所选项目新建文件夹", KeyboardShortcut("n", modifiers: [.command, .control])),
        ("打开", KeyboardShortcut("o")),
        ("在另一窗格中打开", KeyboardShortcut("o", modifiers: [.command, .option])),
        ("快速查看", KeyboardShortcut("y")),
        ("关闭标签页", KeyboardShortcut("w")),
        ("重新打开关闭的标签页", KeyboardShortcut("t", modifiers: [.command, .shift])),
        ("复制", KeyboardShortcut("d")),
        ("批量重命名…", KeyboardShortcut("r", modifiers: [.command, .shift])),
        ("移到废纸篓", KeyboardShortcut(.delete)),
        ("对比两个窗格", KeyboardShortcut("c", modifiers: [.command, .control])),
        ("加入暂存架", KeyboardShortcut("a", modifiers: [.command, .option])),
        ("同步文件夹…", KeyboardShortcut("y", modifiers: [.command, .control])),
        ("拷贝到另一窗格", KeyboardShortcut(.rightArrow, modifiers: [.command, .option])),
        ("移动到另一窗格", KeyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])),
        ("拷贝路径", KeyboardShortcut("c", modifiers: [.command, .option])),
        ("在终端中打开", KeyboardShortcut("t", modifiers: [.command, .option])),
        ("在访达中显示", KeyboardShortcut("r", modifiers: [.command, .option])),
        ("列表视图", KeyboardShortcut("1")),
        ("图标视图", KeyboardShortcut("2")),
        ("分栏视图", KeyboardShortcut("3")),
        ("单窗格", KeyboardShortcut("1", modifiers: [.command, .control])),
        ("双窗格", KeyboardShortcut("2", modifiers: [.command, .control])),
        ("三窗格", KeyboardShortcut("3", modifiers: [.command, .control])),
        ("切换到下一个窗格", KeyboardShortcut("`", modifiers: [.control])),
        ("显示 / 隐藏侧边栏", KeyboardShortcut("b", modifiers: [.command, .control])),
        ("显示 / 隐藏暂存架", KeyboardShortcut("s", modifiers: [.command, .option])),
        ("在编辑器中打开", KeyboardShortcut("e", modifiers: [.command, .option])),
        ("显示 / 隐藏隐藏文件", KeyboardShortcut(".", modifiers: [.command, .shift])),
        ("显示 / 隐藏检查器", KeyboardShortcut("i", modifiers: [.command, .option])),
        ("搜索子文件夹", KeyboardShortcut("f", modifiers: [.command, .option])),
        ("Spotlight 搜索", KeyboardShortcut("f", modifiers: [.command, .option, .shift])),
        ("按条件选择…", KeyboardShortcut("a", modifiers: [.command, .control])),
        ("刷新", KeyboardShortcut("r")),
        ("连接服务器…", KeyboardShortcut("k", modifiers: [.command, .shift])),
        ("返回", KeyboardShortcut("[")),
        ("前进", KeyboardShortcut("]")),
        ("上层文件夹", KeyboardShortcut(.upArrow)),
        ("打开所选项", KeyboardShortcut(.downArrow)),
        ("下一个标签页", KeyboardShortcut("}", modifiers: [.command, .shift])),
        ("上一个标签页", KeyboardShortcut("{", modifiers: [.command, .shift])),
        ("存储为工作区…", KeyboardShortcut("s", modifiers: [.command, .control])),
    ]

    @MainActor
    static func current(_ id: String) -> ShortcutSpec? {
        let settings = AppSettings.shared
        if settings.clearedShortcuts.contains(id) { return nil }
        if let custom = settings.customShortcuts[id] { return custom }
        return entries.first { $0.title == id }.map { ShortcutSpec($0.defaultShortcut) }
    }
}

extension View {
    /// Applies the user's shortcut for this command, falling back to `fallback`.
    @MainActor @ViewBuilder
    func shortcut(_ id: String, _ fallback: KeyboardShortcut) -> some View {
        if let spec = ShortcutCatalog.current(id) { keyboardShortcut(spec.keyboardShortcut) } else { self }
    }
}
