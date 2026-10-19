import AppKit
import CoreImage
import SwiftUI

/// The average color of an image (from a small thumbnail), slightly saturated, for tinting the pane
/// around a selected photo.
@MainActor
enum AmbientColor {
    private static var cache: [String: NSColor] = [:]
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    static func color(for url: URL, modified: Date?) async -> Color? {
        let key = "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)"
        if let hit = cache[key] { return Color(nsColor: hit) }
        guard let image = await ThumbnailCache.shared.thumbnail(for: url, size: 48, modified: modified, scale: 1),
              let color = mood(of: image) else { return nil }
        if cache.count > 500 { cache.removeAll() }
        cache[key] = color
        return Color(nsColor: color)
    }

    /// Average color of an image with its saturation lifted, so a wash reads as the picture's mood.
    static func mood(of image: NSImage) -> NSColor? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)]),
              let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        let average = NSColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                              blue: CGFloat(pixel[2]) / 255, alpha: 1)
        // Averages come out muddy; lift saturation so the wash reads as the photo's mood.
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        average.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, s * 1.5 + 0.1), brightness: max(0.55, min(0.95, b * 1.1)), alpha: 1)
    }
}
