import AppKit

/// Spring-loaded folders: holding a drag over a folder for a moment opens it, so files can be dropped
/// deep inside without letting go. Follows the system setting (Accessibility › Pointer Control).
@MainActor
final class SpringLoader {
    /// What springing open does (navigate the tab, select the folder in a column…).
    var open: ((URL) -> Void)?
    private var target: URL?
    private var timer: Timer?

    init(open: ((URL) -> Void)? = nil) {
        self.open = open
    }

    /// The drag is over `folder` (nil: over nothing that springs). Starts the countdown when the folder
    /// changes; staying over the same one keeps it running.
    func hover(_ folder: URL?) {
        if let folder, let target, folder.isSameFile(as: target) { return }
        cancel()
        guard let folder, Self.isEnabled else { return }
        target = folder
        // Common modes: a drag runs the event-tracking run loop mode, where a default timer never fires.
        let timer = Timer(timeInterval: Self.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking) // in case it isn't one of the common modes
        self.timer = timer
    }

    /// The drag left `folder`; a countdown for a different folder keeps going.
    func leave(_ folder: URL) {
        if let target, target.isSameFile(as: folder) { cancel() }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        target = nil
    }

    private func fire() {
        guard let target else { return }
        cancel()
        open?(target)
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "com.apple.springing.enabled") as? Bool ?? true
    }

    /// The system's spring-loading delay (the Finder default is half a second).
    static var delay: TimeInterval {
        let value = UserDefaults.standard.object(forKey: "com.apple.springing.delay") as? Double ?? 0.5
        return min(max(value, 0.2), 2)
    }
}
