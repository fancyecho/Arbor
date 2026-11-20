import AppKit

/// Development aid: `Arbor --snapshot out.png [--grid] [--dark]` renders the main window to a PNG
/// and quits. Uses the view's own drawing, so no screen-recording permission is needed.
enum Snapshot {
    static let gridRequest = Notification.Name("ArborSnapshotGrid")
    static let demoRequest = Notification.Name("ArborSnapshotDemo")
    static var isActive: Bool { CommandLine.arguments.contains("--snapshot") }

    static func scheduleIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else { return }
        let output = URL(fileURLWithPath: args[index + 1])
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if args.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        for scene in ["demo", "palette", "compare", "sync", "text", "photos", "stress", "narrow", "toggles", "space", "newfolder", "eject", "shelf", "columnsempty", "contextmenu", "update", "update-install", "marquee", "settings", "tree", "timeline", "git", "devcaches", "aiglow", "agent"] where args.contains("--" + scene) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: demoRequest, object: scene)
            }
        }
        for mode in ["grid", "columns"] where args.contains("--" + mode) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NotificationCenter.default.post(name: gridRequest, object: mode)
            }
        }

        let delay = args.firstIndex(of: "--delay").flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil } ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if ProcessInfo.processInfo.environment["ARBOR_SNAPSHOT_DEBUG"] != nil, let ws = WorkspaceRegistry.shared.current {
                MainActor.assumeIsolated {
                    for pane in ws.visiblePanes {
                        let line = pane.tabs.map { "\($0.title)[ai=\($0.aiQuery != nil) tmp=\($0.isTemporary) active=\($0.id == pane.activeTabID)]" }
                        FileHandle.standardError.write(Data(("pane: " + line.joined(separator: ", ") + "\n").utf8))
                    }
                }
            }
            if ProcessInfo.processInfo.environment["ARBOR_SNAPSHOT_DEBUG"] != nil {
                for window in NSApp.windows {
                    FileHandle.standardError.write(Data("window \(window.className) visible=\(window.isVisible) frame=\(window.frame)\n".utf8))
                }
            }
            let settings = args.contains("--settings")
                ? NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }) : nil
            guard let window = settings
                    // The biggest one: popovers and HUDs are windows too.
                    ?? NSApp.windows.filter({ $0.isVisible && $0.contentView != nil && $0.className.contains("AppKitWindow") })
                        .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
                    ?? NSApp.windows.first(where: \.isVisible),
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                NSApp.terminate(nil)
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: output)
            MainActor.assumeIsolated { AppActions.quit() }
        }
    }
}

/// Persistent settings live in the standard defaults, except in snapshot mode, which uses a
/// scratch domain (wiped on every run) so screenshots never touch the user's real session.
enum AppDefaults {
    static let store: UserDefaults = {
        guard Snapshot.isActive else { return .standard }
        let name = "app.arbor.snapshot"
        UserDefaults.standard.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name) ?? .standard
    }()
}
