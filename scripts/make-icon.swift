// Draws the app icon and writes Resources/AppIcon.icns (and a 1024px preview PNG).
// Usage: swift scripts/make-icon.swift <project root>
//
// The idea: a three-branched tree ("arbor") on a frosted glass card, a second card behind it, floating over
// the indigo glass of the window — the app's panes on its tinted backdrop.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let size: CGFloat = 1024

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func hsb(_ h: CGFloat, _ s: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(hue: h, saturation: s, brightness: b, alpha: a)
}

/// The macOS icon shape: a superellipse (continuous corners), not a rounded rectangle.
func squircle(in rect: NSRect, exponent n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let cx = rect.midX, cy = rect.midY, a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

func withShadow(_ color: NSColor, blur: CGFloat, offset: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: -offset)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icon grid: an 824pt body centered in 1024, with room for its shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(in: body)

    withShadow(NSColor.black.withAlphaComponent(0.32), blur: 26, offset: 12) {
        rgb(58, 56, 168).setFill()
        shape.fill()
    }

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // The window's tinted glass: indigo deepening to violet, warm and cool light at opposite corners.
    NSGradient(colors: [rgb(138, 128, 255), rgb(88, 98, 242), rgb(52, 42, 164)])!.draw(in: body, angle: -62)
    NSGradient(colors: [rgb(255, 176, 150, 0.55), rgb(255, 176, 150, 0)])!
        .draw(fromCenter: NSPoint(x: 230, y: 840), radius: 0, toCenter: NSPoint(x: 230, y: 840), radius: 430, options: [])
    NSGradient(colors: [rgb(110, 228, 210, 0.42), rgb(110, 228, 210, 0)])!
        .draw(fromCenter: NSPoint(x: 860, y: 200), radius: 0, toCenter: NSPoint(x: 860, y: 200), radius: 400, options: [])
    // A sheen across the top, like light on glass.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 620, width: 824, height: 304), angle: -90)

    // Back card: a second pane, frosted.
    let back = NSRect(x: 226, y: 300, width: 384, height: 474)
    withShadow(NSColor.black.withAlphaComponent(0.2), blur: 30, offset: 12) {
        NSColor.white.withAlphaComponent(0.26).setFill()
        NSBezierPath(roundedRect: back, xRadius: 58, yRadius: 58).fill()
    }
    NSColor.white.withAlphaComponent(0.6).setStroke()
    let backRim = NSBezierPath(roundedRect: back.insetBy(dx: 2, dy: 2), xRadius: 56, yRadius: 56)
    backRim.lineWidth = 3.5
    backRim.stroke()

    // Front card: bright glass, lit from above.
    let front = NSRect(x: 398, y: 226, width: 404, height: 506)
    let frontPath = NSBezierPath(roundedRect: front, xRadius: 60, yRadius: 60)
    withShadow(NSColor.black.withAlphaComponent(0.3), blur: 40, offset: 16) {
        rgb(246, 246, 255).setFill()
        frontPath.fill()
    }
    NSGraphicsContext.saveGraphicsState()
    frontPath.addClip()
    NSGradient(colors: [rgb(255, 255, 255), rgb(234, 236, 252)])!.draw(in: front, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.setStroke()
    let frontRim = NSBezierPath(roundedRect: front.insetBy(dx: 2, dy: 2), xRadius: 58, yRadius: 58)
    frontRim.lineWidth = 4
    frontRim.stroke()

    // The tree: a tapered trunk that forks into three branches, each ending in a fruit.
    let x = front.midX
    let inkDark = rgb(64, 72, 214), inkLight = rgb(98, 110, 250)
    // Trunk, wider at the root with a slight flare, narrowing to the fork.
    let trunk = NSBezierPath()
    trunk.move(to: NSPoint(x: x - 34, y: 300))
    trunk.curve(to: NSPoint(x: x - 17, y: 340), controlPoint1: NSPoint(x: x - 20, y: 302), controlPoint2: NSPoint(x: x - 17, y: 318))
    trunk.line(to: NSPoint(x: x - 13, y: 476))
    trunk.line(to: NSPoint(x: x + 13, y: 476))
    trunk.line(to: NSPoint(x: x + 17, y: 340))
    trunk.curve(to: NSPoint(x: x + 34, y: 300), controlPoint1: NSPoint(x: x + 17, y: 318), controlPoint2: NSPoint(x: x + 20, y: 302))
    trunk.close()
    NSGraphicsContext.saveGraphicsState()
    trunk.addClip()
    NSGradient(colors: [inkDark, inkLight])!.draw(in: trunk.bounds, angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    // Branches: smooth curves from the fork, a little thinner than the trunk.
    let branches = NSBezierPath()
    branches.lineWidth = 25
    branches.lineCapStyle = .round
    branches.lineJoinStyle = .round
    branches.move(to: NSPoint(x: x, y: 462))
    branches.curve(to: NSPoint(x: x - 100, y: 592), controlPoint1: NSPoint(x: x, y: 528), controlPoint2: NSPoint(x: x - 80, y: 536))
    branches.move(to: NSPoint(x: x, y: 462))
    branches.curve(to: NSPoint(x: x + 100, y: 592), controlPoint1: NSPoint(x: x, y: 528), controlPoint2: NSPoint(x: x + 80, y: 536))
    branches.move(to: NSPoint(x: x, y: 450))
    branches.line(to: NSPoint(x: x, y: 640))
    inkLight.blended(withFraction: 0.25, of: inkDark)!.setStroke()
    branches.stroke()

    // Fruits: glossy spheres in the app's colors, each with a soft shadow of its own color.
    func fruit(_ center: NSPoint, _ light: NSColor, _ dark: NSColor) {
        let radius: CGFloat = 42
        let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        withShadow(dark.withAlphaComponent(0.45), blur: 18, offset: 7) {
            dark.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
        NSGradient(colors: [light, dark])!.draw(in: NSBezierPath(ovalIn: rect),
                                                 relativeCenterPosition: NSPoint(x: -0.35, y: 0.4))
        // A small specular highlight, upper left.
        NSColor.white.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 22, y: center.y + 8, width: 18, height: 14)).fill()
    }
    fruit(NSPoint(x: x - 100, y: 602), rgb(255, 184, 150), rgb(246, 120, 86))
    fruit(NSPoint(x: x + 100, y: 602), rgb(120, 226, 204), rgb(32, 164, 144))
    fruit(NSPoint(x: x, y: 656), rgb(132, 144, 255), rgb(66, 76, 226))

    NSGraphicsContext.restoreGraphicsState()
    return true
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! task.run()
task.waitUntilExit()
let preview = root.appendingPathComponent("Resources/AppIcon-preview.png")
try? fm.removeItem(at: preview)
try? fm.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"), to: preview)
// A strip of the small sizes, to check the icon still reads in the Dock and in Finder lists.
if CommandLine.arguments.count > 2 {
    try? fm.removeItem(atPath: CommandLine.arguments[2])
    try? fm.copyItem(at: iconset, to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
print(task.terminationStatus == 0 ? "wrote \(output.path)" : "iconutil failed")
