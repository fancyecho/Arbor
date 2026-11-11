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
            case .system: L("跟随系统")
            case .light: L("浅色")
            case .dark: L("深色")
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

    /// How the space view colors its rings.
    var spaceColoring: SpaceColoring {
        didSet { defaults.set(spaceColoring.rawValue, forKey: "spaceColoring") }
    }

    /// Panes in a new window: 1–3, or 0 to match the window that was closed or focused last.
    var newWindowPaneCount: Int {
        didSet { defaults.set(newWindowPaneCount, forKey: "newWindowPaneCount") }
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

    /// Git badges in lists, the branch in the path bar and diffs in the inspector.
    var showGitStatus: Bool {
        didSet {
            defaults.set(showGitStatus, forKey: "showGitStatus")
            GitIndex.shared.reset()
        }
    }

    /// Which Settings tab is showing (not saved; lets other places open a specific tab).
    var settingsTab = "general"

    // MARK: AI

    var aiProvider: AIProvider {
        didSet {
            defaults.set(aiProvider.rawValue, forKey: "aiProvider")
            loadAIProviderFields()
            loadAIKey()
        }
    }

    var aiBaseURL: String {
        didSet { defaults.set(aiBaseURL, forKey: "aiBaseURL.\(aiProvider.rawValue)") }
    }

    var aiModel: String {
        didSet { defaults.set(aiModel, forKey: "aiModel.\(aiProvider.rawValue)") }
    }

    /// Kept in the Keychain, one per provider.
    var aiAPIKey: String {
        didSet {
            guard aiAPIKey != oldValue, !loadingKey, !Snapshot.isActive else { return }
            let key = aiAPIKey, account = aiProvider.rawValue
            DispatchQueue.global(qos: .userInitiated).async { AIKeychain.save(key, account: account) }
        }
    }

    @ObservationIgnored private var loadingKey = false

    /// Reads the provider's key off the main thread: the Keychain can stop to ask for permission, and the
    /// app must keep running meanwhile. Snapshots never touch the real Keychain.
    func loadAIKey() {
        guard !Snapshot.isActive else { return }
        let account = aiProvider.rawValue
        DispatchQueue.global(qos: .userInitiated).async {
            let stored = AIKeychain.load(account: account)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.aiProvider.rawValue == account else { return }
                self.loadingKey = true
                self.aiAPIKey = stored
                self.loadingKey = false
            }
        }
    }

    /// How the glow around the window looks while the model works.
    var aiGlow: AIGlowStyle {
        didSet { defaults.set(aiGlow.rawValue, forKey: "aiGlow") }
    }

    var aiConfig: AIConfig {
        AIConfig(provider: aiProvider, baseURL: aiBaseURL, model: aiModel, apiKey: aiAPIKey)
    }

    /// Reloads the URL and model saved for the provider just picked.
    func loadAIProviderFields() {
        aiBaseURL = defaults.string(forKey: "aiBaseURL.\(aiProvider.rawValue)") ?? aiProvider.defaultBaseURL
        aiModel = defaults.string(forKey: "aiModel.\(aiProvider.rawValue)") ?? aiProvider.defaultModel
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
        defaults.register(defaults: ["showMenuBarIcon": true, "showListInsights": true, "autoSaveWorkspaces": true,
                                     "showGitStatus": true])
        showGitStatus = defaults.bool(forKey: "showGitStatus")
        let provider = AIProvider(rawValue: defaults.string(forKey: "aiProvider") ?? "") ?? .anthropic
        aiProvider = provider
        aiBaseURL = defaults.string(forKey: "aiBaseURL.\(provider.rawValue)") ?? provider.defaultBaseURL
        aiModel = defaults.string(forKey: "aiModel.\(provider.rawValue)") ?? provider.defaultModel
        aiAPIKey = ""
        aiGlow = AIGlowStyle(rawValue: defaults.string(forKey: "aiGlow") ?? "") ?? .rainbow
        autoSaveWorkspaces = defaults.bool(forKey: "autoSaveWorkspaces")
        newWindowPaneCount = min(max(defaults.integer(forKey: "newWindowPaneCount"), 0), 3)
        spaceColoring = SpaceColoring(rawValue: defaults.string(forKey: "spaceColoring") ?? "") ?? .folders
        // Stable releases by default; previews only for people who opt in.
        defaults.register(defaults: ["autoCheckUpdates": true, "includePreviewUpdates": false])
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
        loadAIKey()
    }

    var terminalURL: URL {
        ExternalApp.terminals.first { $0.bundleID == terminalBundleID }?.url
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    }

    var editorURL: URL? {
        ExternalApp.editors.first { $0.bundleID == editorBundleID }?.url
    }

    var editorName: String {
        ExternalApp.editors.first { $0.bundleID == editorBundleID }?.name ?? L("编辑器")
    }
}
