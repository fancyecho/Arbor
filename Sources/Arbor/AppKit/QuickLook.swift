import AppKit
import Quartz
import QuickLookThumbnailing

/// Data source for the shared Quick Look panel. The app delegate claims panel control
/// (it sits at the end of every responder chain), so this works from any view.
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private(set) var urls: [URL] = []

    /// Forwarded arrow keys so selection can move while the panel is key.
    var keyHandler: ((NSEvent) -> Bool)?

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func toggle(_ urls: [URL]) {
        if isVisible {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        self.urls = urls
        let panel = QLPreviewPanel.shared()!
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    /// Keeps an open panel in sync with the selection.
    func selectionChanged(_ urls: [URL]) {
        guard isVisible, !urls.isEmpty, urls != self.urls else { return }
        self.urls = urls
        QLPreviewPanel.shared().reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return keyHandler?(event) ?? false
    }
}

/// Async thumbnail generation with an in-memory cache.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 2000 }

    func cached(_ url: URL, size: CGFloat, modified: Date?) -> NSImage? {
        cache.object(forKey: key(url, size, modified))
    }

    func thumbnail(for url: URL, size: CGFloat, modified: Date?, scale: CGFloat) async -> NSImage? {
        let key = key(url, size, modified)
        if let hit = cache.object(forKey: key) { return hit }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = representation.nsImage
        cache.setObject(image, forKey: key)
        return image
    }

    private func key(_ url: URL, _ size: CGFloat, _ modified: Date?) -> NSString {
        "\(url.path)|\(Int(size))|\(modified?.timeIntervalSince1970 ?? 0)" as NSString
    }
}
