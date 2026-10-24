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
        for scene in ["demo", "palette", "compare", "sync", "text", "photos", "stress", "narrow", "toggles", "space", "newfolder", "eject", "shelf", "columnsempty", "update", "update-install", "marquee", "settings"] where args.contains("--" + scene) {
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
            let settings = args.contains("--settings")
                ? NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }) : nil
            guard let window = settings
                    ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.className.contains("AppKitWindow") })
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
