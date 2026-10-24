import AppKit

/// "Use Arbor instead of Finder to show files" (Settings › 通用).
///
/// What macOS allows: the global `NSFileViewer` preference names the app that other apps use when they
/// "show in Finder" through NSWorkspace (a browser's downloads, Raycast's Show in Finder, Xcode…). That
/// app is sent an ordinary open event for the item, which Arbor turns into a tab with the item selected.
///
/// What it doesn't: opening a folder itself (Spotlight, Raycast, Dock) always goes to Finder. Changing
/// the folder handler fails with paramErr (-50) through every API, and an entry written into LaunchServices'
/// handler list is dropped by the system — the same limit QSpace, Path Finder and ForkLift live with.
@MainActor
enum DefaultFolderApp {
    static let finderID = "com.apple.finder"
    static var arborID: String { Bundle.main.bundleIdentifier ?? "app.arbor.Arbor" }
    private static let fileViewerKey = "NSFileViewer" as CFString

    /// The file viewer named in the global preference (QSpace, Path Finder… or Arbor); nil means Finder.
    static var fileViewer: String? {
        CFPreferencesCopyValue(fileViewerKey, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                               kCFPreferencesAnyHost) as? String
    }

    static var isArbor: Bool { fileViewer?.lowercased() == arborID.lowercased() }

    /// A readable name for the app that shows files for other apps.
    static var currentName: String {
        guard let id = fileViewer, id.lowercased() != finderID else { return L("访达") }
        if id.lowercased() == arborID.lowercased() { return "Arbor" }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return id
    }

    /// Arbor (on) or Finder (off) shows files for other apps. Returns a readable problem, or nil.
    static func set(_ arbor: Bool) -> String? {
        CFPreferencesSetValue(fileViewerKey, arbor ? arborID as CFString : nil, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let saved = CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return saved && isArbor == arbor ? nil : L("没能写入系统偏好设置。")
    }
}
