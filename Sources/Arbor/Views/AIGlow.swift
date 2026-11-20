import AppKit
import SwiftUI

/// The light that runs around the edge while the model is working.
enum AIGlowStyle: String, CaseIterable, Identifiable {
    /// Soft colors that flow around the edge.
    case rainbow
    /// A monochrome sheen running over glass.
    case mono

    var id: Self { self }

    var title: String {
        switch self {
        case .rainbow: L("流光彩虹")
        case .mono: L("黑白玻璃")
        }
    }

    /// A closed loop (first color = last) for an angular gradient. The rainbow is a step softer than
    /// full-strength hues, in the same family as the workspace colors: violet, blue, aqua, rose, peach.
    /// On white it is a shade deeper, or the fine line would vanish into the card.
    func colors(dark: Bool) -> [Color] {
        switch self {
        case .rainbow where dark:
            return [
                Color(red: 0.69, green: 0.55, blue: 1.00), // violet
                Color(red: 0.45, green: 0.62, blue: 1.00), // blue
                Color(red: 0.47, green: 0.82, blue: 0.98), // aqua
                Color(red: 0.69, green: 0.55, blue: 1.00), // violet
                Color(red: 1.00, green: 0.50, blue: 0.69), // rose
                Color(red: 1.00, green: 0.72, blue: 0.47), // peach
                Color(red: 0.69, green: 0.55, blue: 1.00), // violet
            ]
        case .rainbow:
            return [
                Color(red: 0.56, green: 0.42, blue: 1.00), // violet
                Color(red: 0.31, green: 0.49, blue: 1.00), // blue
                Color(red: 0.20, green: 0.68, blue: 0.90), // aqua
                Color(red: 0.56, green: 0.42, blue: 1.00), // violet
                Color(red: 0.94, green: 0.36, blue: 0.58), // rose
                Color(red: 0.96, green: 0.60, blue: 0.30), // peach
                Color(red: 0.56, green: 0.42, blue: 1.00), // violet
            ]
        case .mono:
            let ink: Color = dark ? .white : .black
            let peak = dark ? 0.95 : 0.6
            return [ink.opacity(peak), ink.opacity(0.06), ink.opacity(peak * 0.45), ink.opacity(peak), ink.opacity(0.04),
                    ink.opacity(peak * 0.6), ink.opacity(peak)]
        }
    }
}

/// The edge light for a rounded shape: a crisp line on the edge, a soft light that fades inward from it
/// and, around floating controls, a faint halo outside. `active` (the model is working) brightens it and
/// lets it breathe; idle it is just the line, dimmed.
///
/// The falloff is drawn once, as a still mask; only the colors under it turn (a rotation, done by the GPU),
/// so the light costs almost nothing per frame, even around the whole window.
struct AIGlowBorder: View {
    var cornerRadius: CGFloat
    /// The crisp line on the edge.
    var lineWidth: CGFloat = 1
    /// How far the soft light reaches in from the edge.
    var glow: CGFloat = 10
    /// How far a faint light spreads outside the edge (0 for none).
    var halo: CGFloat = 0
    /// Scales the soft light (the window's edge wants a little more than a control's).
    var strength: Double = 1
    var active: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    private let style = AppSettings.shared.aiGlow

    var body: some View {
        let dark = colorScheme == .dark
        let colors = style.colors(dark: dark)
        let glowPeak = (dark ? 0.42 : 0.34) * strength
        ZStack {
            FlowingColors(colors: colors, spins: !reduceMotion)
                .mask { GlowMask(cornerRadius: cornerRadius, glow: glow, halo: halo, part: .light) }
                .opacity(active ? glowPeak * (breathing ? 1 : 0.62) : 0)
            FlowingColors(colors: colors, spins: !reduceMotion)
                .mask { GlowMask(cornerRadius: cornerRadius, lineWidth: lineWidth, halo: halo, part: .line) }
                .opacity(active ? 1 : 0.5)
        }
        .padding(-halo)
        .animation(.easeInOut(duration: 0.5), value: active)
        .animation(reduceMotion || !active ? .easeOut(duration: 0.4) : .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                   value: breathing)
        .onChange(of: active, initial: true) { _, isActive in breathing = isActive && !reduceMotion }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// An angular gradient centered on the view, turning slowly. It is drawn once as a square large enough to
/// cover the view at any angle and rotated, so turning never redraws it.
private struct FlowingColors: View {
    let colors: [Color]
    let spins: Bool
    /// One slow turn: calm enough to sit at the edge of attention.
    private let period: Double = 8

    @State private var turned = false

    var body: some View {
        GeometryReader { proxy in
            let side = hypot(proxy.size.width, proxy.size.height)
            AngularGradient(colors: colors, center: .center)
                .frame(width: side, height: side)
                .rotationEffect(.degrees(turned ? 360 : 0))
                .animation(spins ? .linear(duration: period).repeatForever(autoreverses: false) : .default, value: turned)
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onAppear { turned = spins }
        .onChange(of: spins) { _, value in turned = value }
    }
}

/// Where the light shows, as alpha: the line on the edge, or the soft light that falls off inward (and
/// outward into the halo). Stepped rings with a smooth falloff instead of a blur: drawn once, no seams.
private struct GlowMask: View {
    enum Part { case line, light }

    var cornerRadius: CGFloat
    var lineWidth: CGFloat = 1
    var glow: CGFloat = 0
    var halo: CGFloat
    let part: Part

    var body: some View {
        Canvas { context, size in
            // The shape's own rect: the canvas is `halo` larger on every side.
            let shape = CGRect(origin: .zero, size: size).insetBy(dx: halo, dy: halo)
            /// A band from the edge to `depth` (inward when positive, outward when negative).
            func band(depth: CGFloat, alpha: Double) {
                let inset = depth / 2
                let rect = shape.insetBy(dx: inset, dy: inset)
                guard rect.width > 0, rect.height > 0, alpha > 0.001 else { return }
                let path = Path(roundedRect: rect, cornerRadius: max(cornerRadius - inset, 0), style: .continuous)
                context.stroke(path, with: .color(.white.opacity(alpha)), lineWidth: abs(depth))
            }
            /// A smooth falloff over `reach`, built from nested bands that all start at the edge: each band's
            /// alpha is chosen so the stack composes to the curve, and no two bands meet along a seam.
            func falloff(reach: CGFloat, peak: Double, outward: Bool) {
                let steps = max(Int(reach.rounded()), 1)
                func target(_ index: Int) -> Double {
                    guard index < steps else { return 0 }
                    let t = (Double(index) + 0.5) / Double(steps)
                    return peak * pow(1 - t, 2.4)
                }
                for index in stride(from: steps - 1, through: 0, by: -1) {
                    let alpha = 1 - (1 - target(index)) / (1 - target(index + 1))
                    let depth = reach * CGFloat(index + 1) / CGFloat(steps)
                    band(depth: outward ? -depth : depth, alpha: alpha)
                }
            }
            switch part {
            case .line:
                band(depth: lineWidth, alpha: 1)
            case .light:
                falloff(reach: glow, peak: 1, outward: false)
                // A fainter halo outside, for controls that float.
                if halo > 0 { falloff(reach: halo, peak: 0.5, outward: true) }
            }
        }
    }
}

/// While the model works, the window's edge lights up, like Siri on iPhone: a fine line along the edge
/// and a soft light that fades a short way in, never over the content.
struct WindowGlowOverlay: View {
    let active: Bool

    /// The window's own corner, read from the window itself so the line runs exactly along its edge.
    @State private var corner = WindowCorner.fallback

    var body: some View {
        ZStack {
            if active {
                AIGlowBorder(cornerRadius: corner, lineWidth: 1.5, glow: 40, strength: 1.25, active: true)
                    .transition(.opacity.animation(.easeInOut(duration: 0.45)))
            }
        }
        .ignoresSafeArea()
        .background { WindowCorner.Reader { corner = $0 }.frame(width: 0, height: 0) }
        .allowsHitTesting(false)
    }
}

/// The radius of a window's corners. AppKit doesn't publish it, and it changes between macOS versions
/// (16 pt on macOS 27, with continuous curvature), so it is asked of the window, with 16 as the fallback.
enum WindowCorner {
    static let fallback: CGFloat = 16

    static func radius(of window: NSWindow) -> CGFloat {
        let selector = NSSelectorFromString("_cornerRadius")
        guard window.responds(to: selector), let value = window.value(forKey: "_cornerRadius") as? CGFloat,
              value > 0, value < 60 else { return fallback }
        return value
    }

    /// Reports the corner radius of the window it's in once it's on screen, and again if it changes
    /// (entering full screen squares the corners off).
    struct Reader: NSViewRepresentable {
        let onChange: (CGFloat) -> Void

        func makeNSView(context: Context) -> ReaderView {
            let view = ReaderView()
            view.onChange = onChange
            return view
        }

        func updateNSView(_ view: ReaderView, context: Context) { view.onChange = onChange }

        final class ReaderView: NSView {
            var onChange: ((CGFloat) -> Void)?
            private var observers: [NSObjectProtocol] = []

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                observers.forEach(NotificationCenter.default.removeObserver)
                observers = []
                guard let window else { return }
                for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.report() }
                    })
                }
                DispatchQueue.main.async { [weak self] in self?.report() }
            }

            private func report() {
                guard let window else { return }
                onChange?(window.styleMask.contains(.fullScreen) ? 0 : WindowCorner.radius(of: window))
            }

            deinit { observers.forEach(NotificationCenter.default.removeObserver) }
        }
    }
}
