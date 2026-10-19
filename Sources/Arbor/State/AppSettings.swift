import AppKit
import Foundation
import Observation

/// App-wide preferences, persisted in UserDefaults.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = AppDefaults.store

    var showHidden: Bool {
        didSet { defaults.set(showHidden, forKey: "showHidden") }
    }

    var foldersFirst: Bool {
        didSet { defaults.set(foldersFirst, forKey: "foldersFirst") }
    }

    /// Calculate folder sizes in the inspector without clicking.
    var autoFolderSize: Bool {
        didSet { defaults.set(autoFolderSize, forKey: "autoFolderSize") }
    }

    /// Terminal used by "在终端中打开" and terminal-mode custom commands.
    var terminalBundleID: String {
        didSet { defaults.set(terminalBundleID, forKey: "terminalBundleID") }
    }

    /// Editor used by "在编辑器中打开".
    var editorBundleID: String {
        didSet { defaults.set(editorBundleID, forKey: "editorBundleID") }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: Self { self }
        var title: String {
            switch self {
            case .system: "跟随系统"
            case .light: "浅色"
            case .dark: "深色"
            }
        }
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    /// Light, dark, or follow the system. Applied app-wide immediately.
    var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
        }
    }

    func applyAppearance() {
        NSApp?.appearance = appearance.nsAppearance
    }

    /// Workspaces keep their latest layout: saved when you switch away from one, and when Arbor quits.
    var autoSaveWorkspaces: Bool {
        didSet { defaults.set(autoSaveWorkspaces, forKey: "autoSaveWorkspaces") }
    }

    var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates") }
    }

    /// Also offer development previews (pre-releases) when checking for updates.
    var includePreviewUpdates: Bool {
        didSet { defaults.set(includePreviewUpdates, forKey: "includePreviewUpdates") }
    }

    /// Size bars and freshness dots in the list view.
    var showListInsights: Bool {
        didSet { defaults.set(showListInsights, forKey: "showListInsights") }
    }

    var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: "showMenuBarIcon") }
    }

    /// Global shortcut that shows/hides Arbor from any app.
    var hotKey: HotKeySpec? {
        didSet {
            defaults.set(try? JSONEncoder().encode(hotKey), forKey: "hotKey")
            defaults.set(hotKey == nil, forKey: "hotKeyCleared")
            GlobalHotKey.shared.register(hotKey)
        }
    }

    /// Optional list-view columns that are shown (raw values of FileListView.Column).
    var listColumns: [String] {
        didSet { defaults.set(listColumns, forKey: "listColumns") }
    }

    /// Menu shortcuts changed in Settings, by command title; cleared ones have no shortcut.
    var customShortcuts: [String: ShortcutSpec] {
        didSet { defaults.set(try? JSONEncoder().encode(customShortcuts), forKey: "customShortcuts") }
    }

    var clearedShortcuts: Set<String> {
        didSet { defaults.set(Array(clearedShortcuts), forKey: "clearedShortcuts") }
    }

    /// Context-menu entries the user switched off (by title).
    var hiddenMenuItems: Set<String> {
        didSet { defaults.set(Array(hiddenMenuItems), forKey: "hiddenMenuItems") }
    }

    var colorRules: [ColorRule] {
        didSet { defaults.set(try? JSONEncoder().encode(colorRules), forKey: "colorRules") }
    }

    var customCommands: [CustomCommand] {
        didSet { defaults.set(try? JSONEncoder().encode(customCommands), forKey: "customCommands") }
    }

    private init() {
        defaults.register(defaults: ["showHidden": false, "foldersFirst": true, "autoFolderSize": true])
        showHidden = defaults.bool(forKey: "showHidden")
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        foldersFirst = defaults.bool(forKey: "foldersFirst")
        autoFolderSize = defaults.bool(forKey: "autoFolderSize")
        terminalBundleID = defaults.string(forKey: "terminalBundleID") ?? "com.apple.Terminal"
        editorBundleID = defaults.string(forKey: "editorBundleID")
            ?? ExternalApp.installedEditors.first?.bundleID ?? "com.apple.TextEdit"
        defaults.register(defaults: ["showMenuBarIcon": true, "showListInsights": true, "autoSaveWorkspaces": true])
        autoSaveWorkspaces = defaults.bool(forKey: "autoSaveWorkspaces")
        defaults.register(defaults: ["autoCheckUpdates": true, "includePreviewUpdates": true])
        autoCheckUpdates = defaults.bool(forKey: "autoCheckUpdates")
        includePreviewUpdates = defaults.bool(forKey: "includePreviewUpdates")
        showListInsights = defaults.bool(forKey: "showListInsights")
        showMenuBarIcon = defaults.bool(forKey: "showMenuBarIcon")
        hotKey = defaults.bool(forKey: "hotKeyCleared") ? nil
            : defaults.data(forKey: "hotKey").flatMap { try? JSONDecoder().decode(HotKeySpec.self, from: $0) } ?? .defaultValue
        listColumns = defaults.stringArray(forKey: "listColumns") ?? ["modified", "size", "kind"]
        customShortcuts = defaults.data(forKey: "customShortcuts")
            .flatMap { try? JSONDecoder().decode([String: ShortcutSpec].self, from: $0) } ?? [:]
        clearedShortcuts = Set(defaults.stringArray(forKey: "clearedShortcuts") ?? [])
        hiddenMenuItems = Set(defaults.stringArray(forKey: "hiddenMenuItems") ?? [])
        colorRules = defaults.data(forKey: "colorRules")
            .flatMap { try? JSONDecoder().decode([ColorRule].self, from: $0) } ?? [
                ColorRule(pattern: "*.zip; *.rar; *.7z; *.dmg", tint: .purple, enabled: false),
            ]
        customCommands = defaults.data(forKey: "customCommands")
            .flatMap { try? JSONDecoder().decode([CustomCommand].self, from: $0) } ?? CustomCommand.examples
    }

    var terminalURL: URL {
        ExternalApp.terminals.first { $0.bundleID == terminalBundleID }?.url
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    }

    var editorURL: URL? {
        ExternalApp.editors.first { $0.bundleID == editorBundleID }?.url
    }

    var editorName: String {
        ExternalApp.editors.first { $0.bundleID == editorBundleID }?.name ?? "编辑器"
    }
}
