import AppKit
import UniformTypeIdentifiers

/// Making Arbor the app that opens folders (Settings › 通用). It changes the system's default handler
/// for folders, so folders opened from Spotlight, `open` in Terminal or other apps come to Arbor.
/// The desktop, the Dock and "Show in Finder" stay with Finder: they're Finder itself, not a handler choice.
@MainActor
enum DefaultFolderApp {
    static let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    static var isArbor: Bool {
        guard let current = NSWorkspace.shared.urlForApplication(toOpen: .folder),
              let id = Bundle(url: current)?.bundleIdentifier else { return false }
        return id == Bundle.main.bundleIdentifier
    }

    /// Hands folders to Arbor (on) or back to Finder (off). macOS may ask the user to confirm.
    static func set(_ arbor: Bool, completion: @escaping (Error?) -> Void) {
        let app = arbor ? Bundle.main.bundleURL : finder
        NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .folder) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }
}
