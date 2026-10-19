import AppKit
import SwiftUI

/// A slim, rounded scroll bar in the workspace color, with no track. It widens a little while the
/// pointer is over it, and fades with the system's overlay scrollers.
final class SlimScroller: NSScroller {
    var tint: NSColor = .labelColor {
        didSet { if tint != oldValue { needsDisplay = true } }
    }

    private var hovering = false
    private var trackingArea: NSTrackingArea?

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovering = false
        needsDisplay = true
    }

    /// No gray track: the bar floats over the glass.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard knob.width > 0, knob.height > 0 else { return }
        let vertical = knob.height >= knob.width
        let thickness: CGFloat = hovering ? 7 : 5
        var bar = knob.insetBy(dx: vertical ? 0 : 3, dy: vertical ? 3 : 0)
        if vertical {
            bar.origin.x = knob.maxX - thickness - 2
            bar.size.width = thickness
        } else {
            bar.origin.y = knob.maxY - thickness - 2
            bar.size.height = thickness
        }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        tint.withAlphaComponent(hovering ? 0.75 : (dark ? 0.6 : 0.5)).setFill()
        NSBezierPath(roundedRect: bar, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }

    /// Puts slim scrollers on a scroll view (once) and keeps their color current.
    static func install(on scrollView: NSScrollView, tint: NSColor) {
        scrollView.scrollerStyle = .overlay
        if scrollView.hasVerticalScroller {
            if let slim = scrollView.verticalScroller as? SlimScroller {
                slim.tint = tint
            } else {
                let slim = SlimScroller()
                slim.tint = tint
                scrollView.verticalScroller = slim
            }
        }
        if scrollView.hasHorizontalScroller {
            if let slim = scrollView.horizontalScroller as? SlimScroller {
                slim.tint = tint
            } else {
                let slim = SlimScroller()
                slim.tint = tint
                scrollView.horizontalScroller = slim
            }
        }
    }
}

/// Place inside a SwiftUI ScrollView's content (or a List row) to give that scroll view slim scrollers.
struct SlimScrollers: NSViewRepresentable {
    let tint: Color

    func makeNSView(context: Context) -> Finder { Finder() }

    func updateNSView(_ view: Finder, context: Context) {
        view.tint = NSColor(tint)
        view.apply()
    }

    final class Finder: NSView {
        var tint: NSColor = .labelColor

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            // Deferred so it never changes the scroll view in the middle of a layout pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = self.enclosingScrollView else { return }
                SlimScroller.install(on: scroll, tint: self.tint)
            }
        }
    }
}

extension View {
    /// Slim workspace-colored scroll bars for the scroll view this view sits in.
    func slimScrollers(_ tint: Color) -> some View {
        background(SlimScrollers(tint: tint).frame(width: 0, height: 0).allowsHitTesting(false))
    }
}
