import AppKit
import SwiftUI

/// New windows open where you left off: after closing every window, the next one comes back at the
/// same place and size; with windows open (⌘N) it takes their size and the system cascades it.
/// The first window of a launch is left to macOS, which restores it on its own.
@MainActor
enum WindowFrameMemory {
    private static let key = "lastWindowFrame"
    private static var placedFirstWindow = false

    static var saved: NSRect? {
        AppDefaults.store.string(forKey: key).map(NSRectFromString).flatMap { $0.width >= 400 && $0.height >= 300 ? $0 : nil }
    }

    static func remember(_ window: NSWindow) {
        guard !window.isMiniaturized, !window.styleMask.contains(.fullScreen) else { return }
        AppDefaults.store.set(NSStringFromRect(window.frame), forKey: key)
    }

    static func place(_ window: NSWindow) {
        defer { placedFirstWindow = true }
        guard placedFirstWindow, let frame = saved else { return }
        let othersOpen = NSApp.windows.contains {
            $0 !== window && $0.isVisible && ($0.identifier?.rawValue.hasPrefix("browser") ?? false)
        }
        var target = window.frame
        target.size = frame.size
        if othersOpen {
            target.origin.y = window.frame.maxY - frame.height // keep the cascaded top-left corner
        } else {
            target.origin = frame.origin
        }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? target
        guard screen.intersects(target) else { return }
        window.setFrame(target, display: true)
    }
}

/// How wide a window must be for what it shows: every pane keeps 240pt, plus the sidebar and inspector.
/// Below that, three panes and the inspector simply aren't offered — the window grows or refuses to shrink.
enum WindowLayout {
    static let sidebar: CGFloat = 230    // 220pt card + its leading margin
    static let inspector: CGFloat = 270  // 260pt card at its narrowest + its trailing margin
    /// Toolbar and an empty single pane still need some room.
    static let floor: CGFloat = 560

    static func minimumWidth(panes: Int, sidebar showSidebar: Bool, inspector showInspector: Bool) -> CGFloat {
        let width = PanesView.preferredWidth(count: panes) + (showSidebar ? sidebar : 0) + (showInspector ? inspector : 0)
        return max(floor, width)
    }

    /// The frame after widening `frame` to `width`: it grows to the right, slides left at the screen edge,
    /// and never exceeds the screen.
    static func widened(_ frame: NSRect, to width: CGFloat, within screen: NSRect) -> NSRect {
        guard frame.width < width else { return frame }
        var result = frame
        result.size.width = min(width, screen.width)
        if result.maxX > screen.maxX { result.origin.x = screen.maxX - result.width }
        result.origin.x = max(result.origin.x, screen.minX)
        return result
    }
}

/// Zero-size helper in the window's view tree: places the window once, keeps its frame remembered,
/// and holds it at least `minimumWidth` wide.
struct WindowFrameKeeper: NSViewRepresentable {
    let minimumWidth: CGFloat

    func makeNSView(context: Context) -> KeeperView { KeeperView() }

    func updateNSView(_ view: KeeperView, context: Context) {
        view.minimumWidth = minimumWidth
    }

    final class KeeperView: NSView {
        private var observers: [NSObjectProtocol] = []
        private var placed = false

        var minimumWidth: CGFloat = 0 {
            didSet { if minimumWidth != oldValue { enforceMinimum() } }
        }

        private func enforceMinimum() {
            // Deferred: never resize a window in the middle of SwiftUI's layout pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                var minSize = window.contentMinSize
                minSize.width = self.minimumWidth
                window.contentMinSize = minSize
                guard !window.styleMask.contains(.fullScreen),
                      let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
                let target = WindowLayout.widened(window.frame, to: self.minimumWidth, within: screen)
                if target != window.frame { window.setFrame(target, display: true, animate: true) }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            enforceMinimum()
            if !placed {
                placed = true
                // Deferred: never resize a window in the middle of SwiftUI's layout pass.
                DispatchQueue.main.async { [weak window] in
                    guard let window else { return }
                    MainActor.assumeIsolated { WindowFrameMemory.place(window) }
                }
            }
            for name in [NSWindow.didEndLiveResizeNotification, NSWindow.didMoveNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { note in
                    guard let window = note.object as? NSWindow else { return }
                    MainActor.assumeIsolated { WindowFrameMemory.remember(window) }
                })
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
