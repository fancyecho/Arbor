import AppKit

/// The menu bar icon: the app icon's folder (scripts/make-icon.swift) as a template image, so the menu bar
/// tints it for light, dark and highlighted states. One color can't show layers, so thin cut-out gaps do:
/// the back with its tab, a sheet peeking out, and the front. (At 18 pt the icon's three colored sheets
/// would only be noise; one sheet reads as "a folder with things in it".)
enum MenuBarIcon {
    static let image: NSImage = {
        // Drawn on demand, so it's sharp at whatever scale the menu bar uses.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            drawFolder()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Arbor"
        return image
    }()

    /// Width of the gaps that separate the layers.
    private static let gap: CGFloat = 0.9

    private static func drawFolder() {
        guard let context = NSGraphicsContext.current else { return }
        NSColor.black.set()
        back().fill()
        // Each layer first erases a margin around itself, so it stands apart from what's behind it. The sheet
        // is narrower than the back, so its margin never cuts into the folder's outline.
        layer(sheet(from: 3.2, to: 14.8, top: 5.5, angle: -2.5), in: context)
        layer(NSBezierPath(roundedRect: NSRect(x: 1.5, y: 7.8, width: 15, height: 7.9), xRadius: 2.4, yRadius: 2.4),
              in: context)
    }

    private static func layer(_ shape: NSBezierPath, in context: NSGraphicsContext) {
        context.compositingOperation = .clear
        shape.lineWidth = gap * 2
        shape.stroke()
        context.compositingOperation = .sourceOver
        shape.fill()
    }

    /// The back panel with its tab, a third of the width, like the app icon.
    private static func back() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 1.5, y: 4.6))
        path.curve(to: NSPoint(x: 3.0, y: 2.9), controlPoint1: NSPoint(x: 1.5, y: 3.6), controlPoint2: NSPoint(x: 2.1, y: 2.9))
        path.line(to: NSPoint(x: 5.6, y: 2.9))
        path.curve(to: NSPoint(x: 6.6, y: 3.4), controlPoint1: NSPoint(x: 6.0, y: 2.9), controlPoint2: NSPoint(x: 6.3, y: 3.1))
        path.line(to: NSPoint(x: 7.2, y: 4.0))
        path.line(to: NSPoint(x: 15.1, y: 4.0))
        path.curve(to: NSPoint(x: 16.5, y: 5.4), controlPoint1: NSPoint(x: 15.9, y: 4.0), controlPoint2: NSPoint(x: 16.5, y: 4.6))
        path.line(to: NSPoint(x: 16.5, y: 13.3))
        path.curve(to: NSPoint(x: 14.1, y: 15.7), controlPoint1: NSPoint(x: 16.5, y: 14.6), controlPoint2: NSPoint(x: 15.4, y: 15.7))
        path.line(to: NSPoint(x: 3.9, y: 15.7))
        path.curve(to: NSPoint(x: 1.5, y: 13.3), controlPoint1: NSPoint(x: 2.6, y: 15.7), controlPoint2: NSPoint(x: 1.5, y: 14.6))
        path.close()
        return path
    }

    /// A sheet tucked into the folder, tilted a little; only its top shows above the front.
    private static func sheet(from x0: CGFloat, to x1: CGFloat, top: CGFloat, angle: CGFloat) -> NSBezierPath {
        let path = NSBezierPath(roundedRect: NSRect(x: x0, y: top, width: x1 - x0, height: 7), xRadius: 1.2, yRadius: 1.2)
        var transform = AffineTransform(translationByX: (x0 + x1) / 2, byY: 11)
        transform.rotate(byDegrees: angle)
        transform.translate(x: -(x0 + x1) / 2, y: -11)
        path.transform(using: transform)
        return path
    }
}
