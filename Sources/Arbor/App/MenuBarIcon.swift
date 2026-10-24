import AppKit

/// The menu bar icon: the olive sprig from the app icon (scripts/make-icon.swift), as a template image so
/// the menu bar tints it for light, dark and highlighted states. Simplified for 18 pt: three leaves and a
/// tip leaf, with strokes heavy enough to stay crisp.
enum MenuBarIcon {
    static let image: NSImage = {
        // Drawn on demand, so it's sharp at whatever scale the menu bar uses.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            drawSprig()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Arbor"
        return image
    }()

    private static let stem = [NSPoint(x: 3.4, y: 15.4), NSPoint(x: 5.2, y: 12.0),
                               NSPoint(x: 8.0, y: 8.0), NSPoint(x: 12.6, y: 4.9)]

    private static func drawSprig() {
        NSColor.black.set()
        let path = NSBezierPath()
        path.move(to: stem[0])
        path.curve(to: stem[3], controlPoint1: stem[1], controlPoint2: stem[2])
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        path.stroke()

        // Alternating sides, smaller toward the tip, like the app icon.
        for (t, turn, length, width) in [(0.24, -50.0, 5.2, 2.0), (0.50, 50.0, 5.0, 1.9), (0.76, -50.0, 4.4, 1.7)] {
            let (point, heading) = onStem(t)
            leaf(at: point, heading: heading + turn, length: length, width: width)
        }
        let (tip, heading) = onStem(1)
        leaf(at: tip, heading: heading + 4, length: 3.8, width: 1.55)
    }

    /// A point on the stem and the direction it grows there (0° is straight up, positive leans right).
    private static func onStem(_ t: CGFloat) -> (NSPoint, CGFloat) {
        let (p0, p1, p2, p3) = (stem[0], stem[1], stem[2], stem[3])
        let u = 1 - t
        let x = u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x
        let y = u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
        let dx = 3 * u * u * (p1.x - p0.x) + 6 * u * t * (p2.x - p1.x) + 3 * t * t * (p3.x - p2.x)
        let dy = 3 * u * u * (p1.y - p0.y) + 6 * u * t * (p2.y - p1.y) + 3 * t * t * (p3.y - p2.y)
        return (NSPoint(x: x, y: y), atan2(dx, -dy) * 180 / .pi)
    }

    /// An olive leaf from `base` along `heading`: fullest near the stem, tapering to a soft tip.
    private static func leaf(at base: NSPoint, heading: CGFloat, length l: CGFloat, width w: CGFloat) {
        let shape = NSBezierPath()
        shape.move(to: .zero)
        shape.curve(to: NSPoint(x: 0, y: -l), controlPoint1: NSPoint(x: w, y: -l * 0.18),
                    controlPoint2: NSPoint(x: w * 0.85, y: -l * 0.82))
        shape.curve(to: .zero, controlPoint1: NSPoint(x: -w * 0.85, y: -l * 0.82),
                    controlPoint2: NSPoint(x: -w, y: -l * 0.18))
        shape.close()
        var transform = AffineTransform(translationByX: base.x, byY: base.y)
        transform.rotate(byDegrees: heading)
        shape.transform(using: transform)
        shape.lineWidth = 0.6
        shape.lineJoinStyle = .round
        shape.fill()
        shape.stroke()
    }
}
