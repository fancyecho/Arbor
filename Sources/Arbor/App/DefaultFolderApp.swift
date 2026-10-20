import AppKit
import CoreServices
import UniformTypeIdentifiers

/// Making Arbor the app that opens folders (Settings › 通用). It changes the system's default handler
/// for folders, so folders opened from Spotlight, `open` in Terminal or other apps come to Arbor.
/// The desktop, the Dock and "Show in Finder" stay with Finder: they're Finder itself, not a handler choice.
@MainActor
enum DefaultFolderApp {
    static let finderID = "com.apple.finder"

    /// Bundle id of the app that currently opens folders. (Asked of NSWorkspace, which answers with what
    /// actually happens: Finder doesn't register for folders the usual way, so the lower-level
    /// LaunchServices query names some other app when Finder is in charge.)
    static var currentHandler: String? {
        NSWorkspace.shared.urlForApplication(toOpen: .folder).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    static var isArbor: Bool {
        currentHandler?.lowercased() == Bundle.main.bundleIdentifier?.lowercased()
    }

    /// Hands folders to Arbor (on) or back to Finder (off). Reports a readable reason if the system said no.
    static func set(_ arbor: Bool, completion: @escaping (String?) -> Void) {
        let target = arbor ? (Bundle.main.bundleIdentifier ?? "app.arbor.Arbor") : finderID
        if arbor {
            // Make sure LaunchServices knows this copy of Arbor and that it can open folders — after an
            // in-place update it may still have an older registration on file.
            LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        }
        // The long-standing LaunchServices call (what other file managers use for folders)…
        let status = LSSetDefaultRoleHandlerForContentType(UTType.folder.identifier as CFString, .all, target as CFString)
        if status == noErr, currentHandler?.lowercased() == target.lowercased() {
            completion(nil)
            return
        }
        // …and the modern one as a fallback.
        let appURL = arbor ? Bundle.main.bundleURL : URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: .folder) { error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if currentHandler?.lowercased() == target.lowercased() {
                        completion(nil)
                    } else if let error {
                        completion("系统没有接受这个更改（\(error.localizedDescription)，代码 \(status)）。")
                    } else {
                        completion("系统没有接受这个更改（代码 \(status)）。")
                    }
                }
            }
        }
    }
}
