import SwiftUI

/// The light that runs around the edge while the model is working.
enum AIGlowStyle: String, CaseIterable, Identifiable {
    /// Apple Intelligence-style colors that flow around the edge.
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

    func colors(dark: Bool) -> [Color] {
        switch self {
        case .rainbow:
            return [
                Color(red: 0.74, green: 0.51, blue: 0.95), Color(red: 0.96, green: 0.73, blue: 0.92),
                Color(red: 0.55, green: 0.62, blue: 1.00), Color(red: 1.00, green: 0.40, blue: 0.47),
                Color(red: 1.00, green: 0.73, blue: 0.44), Color(red: 0.78, green: 0.53, blue: 1.00),
                Color(red: 0.74, green: 0.51, blue: 0.95),
            ]
        case .mono:
            let ink: Color = dark ? .white : .black
            return [ink.opacity(0.95), ink.opacity(0.08), ink.opacity(0.45), ink.opacity(0.9), ink.opacity(0.04),
                    ink.opacity(0.6), ink.opacity(0.95)]
        }
    }
}

/// A glowing border for any rounded shape. `active` speeds it up and makes it brighter (the model is
/// working); otherwise it idles slowly and softly.
struct AIGlowBorder: View {
    var cornerRadius: CGFloat
    var lineWidth: CGFloat = 1.5
    /// How far the soft light spreads past the edge.
    var spread: CGFloat = 1
    var active: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let style = AppSettings.shared.aiGlow

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let colors = style.colors(dark: colorScheme == .dark)
        SwiftUI.TimelineView(.animation(minimumInterval: active ? nil : 1.0 / 24, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let speed = active ? 110.0 : 28.0
            let base = (t * speed).truncatingRemainder(dividingBy: 360)
            // Layers turn at slightly different speeds and breathe, so the light looks alive, not spun.
            let breathe = active ? (sin(t * 2.6) + 1) / 2 : 0.3
            ZStack {
                shape
                    .stroke(AngularGradient(colors: colors, center: .center, angle: .degrees(-base * 0.8)),
                            lineWidth: lineWidth * (8 + 4 * breathe))
                    .blur(radius: 16 * spread)
                    .opacity(active ? 0.55 : 0.25)
                shape
                    .stroke(AngularGradient(colors: colors, center: .center, angle: .degrees(base + 40)),
                            lineWidth: lineWidth * (3.5 + 2 * breathe))
                    .blur(radius: 6 * spread)
                    .opacity(active ? 0.85 : 0.45)
                shape
                    .stroke(AngularGradient(colors: colors, center: .center, angle: .degrees(base)),
                            lineWidth: lineWidth)
                    .opacity(active ? 1 : 0.8)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The whole window's edge lights up while the model works, like Siri on iPhone.
struct WindowGlowOverlay: View {
    let active: Bool

    var body: some View {
        if active {
            AIGlowBorder(cornerRadius: 16, lineWidth: 2.5, spread: 1.6, active: true)
                .padding(1)
                .mask {
                    // Only the edge glows: the content stays readable.
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(lineWidth: 70)
                }
                .ignoresSafeArea()
                .transition(.opacity.animation(.easeInOut(duration: 0.45)))
                .allowsHitTesting(false)
        }
    }
}
