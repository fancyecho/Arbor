import AppKit

/// Copying or moving to the other pane: the files' icons arc across the window and drop into the
/// list they're going to. Purely decorative; skipped when either list isn't showing or motion is reduced.
@MainActor
enum FlyAnimation {
    static func run(items: [URL], from source: UUID, to target: UUID, move: Bool, tint: NSColor = .controlAccentColor) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let window = NSApp.keyWindow, let content = window.contentView else { return }
        let tables = allTables(in: content)
        guard let from = tables.first(where: { $0.paneID == source }),
              let to = tables.first(where: { $0.paneID == target }) else { return }

        let overlay = PassThroughView(frame: content.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        content.addSubview(overlay)

        // Land near the top of what the destination shows, where new rows appear when sorted by name.
        let landing = to.convert(NSPoint(x: to.visibleRect.midX, y: to.visibleRect.minY + 60), to: overlay)
        let selectedRows = from.selectedRowIndexes.filter { from.rect(ofRow: $0).intersects(from.visibleRect) }
        var starts: [NSPoint] = selectedRows.prefix(6).map { row in
            let rect = from.rect(ofRow: row)
            return from.convert(NSPoint(x: rect.minX + 30, y: rect.midY), to: overlay)
        }
        if starts.isEmpty {
            starts = [from.convert(NSPoint(x: from.visibleRect.midX, y: from.visibleRect.midY), to: overlay)]
        }

        let duration = 0.62
        for (index, start) in starts.enumerated() {
            let url = items[min(index, items.count - 1)]
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let layer = CALayer()
            layer.contents = icon
            layer.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
            layer.position = start
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.3
            layer.shadowRadius = 6
            layer.shadowOffset = CGSize(width: 0, height: -3)
            layer.opacity = 0
            overlay.layer?.addSublayer(layer)

            // An arc that rises over the gap between the panes, then drops in.
            let end = CGPoint(x: landing.x + CGFloat(index) * 6, y: landing.y + CGFloat(index) * 4)
            let lift = max(60, abs(end.x - start.x) * 0.22)
            let control = CGPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + (overlay.isFlipped ? -lift : lift))
            let path = CGMutablePath()
            path.move(to: start)
            path.addQuadCurve(to: end, control: control)

            let position = CAKeyframeAnimation(keyPath: "position")
            position.path = path
            position.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)

            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.8, 1.25, 1.05, 0.55]
            scale.keyTimes = [0, 0.3, 0.75, 1]

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0, 1, 1, 0]
            opacity.keyTimes = [0, 0.1, 0.8, 1]

            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = (end.x > start.x ? -1 : 1) * 0.35

            let group = CAAnimationGroup()
            group.animations = [position, scale, opacity, spin]
            group.duration = duration
            group.beginTime = CACurrentMediaTime() + Double(index) * 0.05
            group.fillMode = .backwards
            layer.add(group, forKey: "fly")
        }

        // A soft ring where they land.
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -18, y: -18, width: 36, height: 36), transform: nil)
        ring.position = landing
        ring.fillColor = nil
        ring.strokeColor = tint.withAlphaComponent(0.75).cgColor
        ring.lineWidth = 2
        ring.opacity = 0
        overlay.layer?.addSublayer(ring)
        let ringScale = CABasicAnimation(keyPath: "transform.scale")
        ringScale.fromValue = 0.4
        ringScale.toValue = 1.8
        let ringFade = CAKeyframeAnimation(keyPath: "opacity")
        ringFade.values = [0, 0.9, 0]
        ringFade.keyTimes = [0, 0.2, 1]
        let ringGroup = CAAnimationGroup()
        ringGroup.animations = [ringScale, ringFade]
        ringGroup.duration = 0.45
        ringGroup.beginTime = CACurrentMediaTime() + duration * 0.85
        ringGroup.fillMode = .backwards
        ring.add(ringGroup, forKey: "ring")

        let total = duration + Double(starts.count) * 0.05 + 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + total) { overlay.removeFromSuperview() }
    }

    private static func allTables(in view: NSView) -> [FileTableView] {
        var found: [FileTableView] = []
        if let table = view as? FileTableView { found.append(table) }
        for subview in view.subviews { found += allTables(in: subview) }
        return found
    }
}

/// Draws on top of the window without catching clicks.
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
