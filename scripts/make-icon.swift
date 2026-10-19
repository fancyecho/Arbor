// Draws the development-preview app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift <project root>
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let size: CGFloat = 1024

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS icon grid: 824pt body centered in 1024, continuous-corner radius ~185.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    rgb(60, 62, 160).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(colors: [rgb(124, 118, 255), rgb(79, 93, 240), rgb(52, 38, 150)])!.draw(in: body, angle: -65)
    // Soft glows, like the tinted glass backdrop.
    NSGradient(colors: [rgb(255, 190, 160, 0.55), rgb(255, 190, 160, 0)])!
        .draw(fromCenter: NSPoint(x: 260, y: 820), radius: 0, toCenter: NSPoint(x: 260, y: 820), radius: 420, options: [])
    NSGradient(colors: [rgb(120, 230, 215, 0.45), rgb(120, 230, 215, 0)])!
        .draw(fromCenter: NSPoint(x: 820, y: 230), radius: 0, toCenter: NSPoint(x: 820, y: 230), radius: 380, options: [])

    // Two floating glass cards (the window's panes).
    func card(_ rect: NSRect, alpha: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.25)
        s.shadowBlurRadius = 30
        s.shadowOffset = NSSize(width: 0, height: -12)
        s.set()
        let path = NSBezierPath(roundedRect: rect, xRadius: 56, yRadius: 56)
        NSColor.white.withAlphaComponent(alpha).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        let rim = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 54, yRadius: 54)
        rim.lineWidth = 4
        NSColor.white.withAlphaComponent(0.7).setStroke()
        rim.stroke()
    }
    card(NSRect(x: 230, y: 300, width: 380, height: 470), alpha: 0.32)
    card(NSRect(x: 400, y: 230, width: 400, height: 500), alpha: 0.92)

    // A branching tree ("arbor") on the front card.
    let ink = rgb(79, 93, 240)
    ink.setStroke()
    let trunk = NSBezierPath()
    trunk.lineWidth = 30
    trunk.lineCapStyle = .round
    trunk.lineJoinStyle = .round
    trunk.move(to: NSPoint(x: 600, y: 300))
    trunk.line(to: NSPoint(x: 600, y: 470))
    trunk.move(to: NSPoint(x: 600, y: 470))
    trunk.curve(to: NSPoint(x: 500, y: 590), controlPoint1: NSPoint(x: 600, y: 530), controlPoint2: NSPoint(x: 520, y: 540))
    trunk.move(to: NSPoint(x: 600, y: 470))
    trunk.curve(to: NSPoint(x: 700, y: 590), controlPoint1: NSPoint(x: 600, y: 530), controlPoint2: NSPoint(x: 680, y: 540))
    trunk.move(to: NSPoint(x: 600, y: 420))
    trunk.line(to: NSPoint(x: 600, y: 640))
    trunk.stroke()
    for (center, color) in [(NSPoint(x: 500, y: 600), rgb(255, 150, 110)), (NSPoint(x: 600, y: 655), rgb(79, 93, 240)),
                            (NSPoint(x: 700, y: 600), rgb(42, 180, 160))] {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 38, y: center.y - 38, width: 76, height: 76)).fill()
    }

    // "DEV" ribbon across the bottom-right corner.
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: 720, yBy: 250)
    transform.rotate(byDegrees: 45)
    transform.concat()
    let ribbon = NSRect(x: -330, y: -52, width: 660, height: 104)
    NSGradient(colors: [rgb(255, 196, 64), rgb(245, 150, 30)])!.draw(in: ribbon, angle: 90)
    let text = NSAttributedString(string: "DEV", attributes: [
        .font: NSFont.systemFont(ofSize: 64, weight: .heavy),
        .foregroundColor: rgb(60, 36, 10),
        .kern: 10,
    ])
    let textSize = text.size()
    text.draw(at: NSPoint(x: -textSize.width / 2 + 5, y: -textSize.height / 2 + 2))
    NSGraphicsContext.restoreGraphicsState()

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
try? fm.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"),
                 to: root.appendingPathComponent("Resources/AppIcon-preview.png"))
print(task.terminationStatus == 0 ? "wrote \(output.path)" : "iconutil failed")
