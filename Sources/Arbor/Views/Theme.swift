import AppKit
import SwiftUI

/// Each workspace has its own color: the glass, selections and highlights all take it on,
/// so switching workspaces feels like walking into another room.
enum WorkspaceTint: String, Codable, CaseIterable, Identifiable {
    case indigo, coral, teal, violet, amber, rose, graphite

    var id: Self { self }

    var title: String {
        switch self {
        case .indigo: L("靛蓝")
        case .coral: L("珊瑚")
        case .teal: L("青绿")
        case .violet: L("紫罗兰")
        case .amber: L("琥珀")
        case .rose: L("玫瑰")
        case .graphite: L("石墨")
        }
    }

    var nsColor: NSColor {
        switch self {
        case .indigo: NSColor(srgbRed: 0.31, green: 0.36, blue: 0.94, alpha: 1)
        case .coral: NSColor(srgbRed: 0.89, green: 0.45, blue: 0.31, alpha: 1)
        case .teal: NSColor(srgbRed: 0.16, green: 0.62, blue: 0.56, alpha: 1)
        case .violet: NSColor(srgbRed: 0.60, green: 0.36, blue: 0.88, alpha: 1)
        case .amber: NSColor(srgbRed: 0.85, green: 0.58, blue: 0.13, alpha: 1)
        case .rose: NSColor(srgbRed: 0.88, green: 0.32, blue: 0.52, alpha: 1)
        case .graphite: NSColor(srgbRed: 0.42, green: 0.46, blue: 0.53, alpha: 1)
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

extension Color {
    /// A workspace color used as text or icon on the sidebar. On dark Liquid Glass, which itself takes on
    /// the workspace color from the backdrop, the color is lifted toward white so it stays readable.
    func onSidebarGlass(_ scheme: ColorScheme) -> Color {
        if #available(macOS 26.0, *), scheme == .dark { return mix(with: .white, by: 0.45) }
        return self
    }
}

private struct ArborTintKey: EnvironmentKey {
    static let defaultValue: Color = WorkspaceTint.indigo.color
}

extension EnvironmentValues {
    /// The window's workspace color (use instead of `Color.accentColor`).
    var arborTint: Color {
        get { self[ArborTintKey.self] }
        set { self[ArborTintKey.self] = newValue }
    }
}

/// Content-layer surfaces: the floating pane and inspector cards over the blurred backdrop.
/// (Not `Glass`: that name is SwiftUI's Liquid Glass material, used for controls and the sidebar.)
enum Surface {
    /// Card fill that reads well over the blurred backdrop in light and dark mode.
    static func card(active: Bool) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark
                ? NSColor(white: 0.11, alpha: active ? 0.82 : 0.6)
                : NSColor(white: 1.0, alpha: active ? 0.88 : 0.62)
        })
    }

    static let hairline = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 1, alpha: 0.65)
    })
}

/// NSVisualEffectView for SwiftUI: blurs whatever is behind the window (the desktop).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// The window backdrop: desktop blur washed with the workspace color, brighter toward the top-left.
struct WorkspaceBackdrop: View {
    let tint: Color

    var body: some View {
        ZStack {
            VisualEffectBackground()
            tint.opacity(0.10)
            RadialGradient(colors: [tint.opacity(0.28), tint.opacity(0)], center: .topLeading, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [tint.opacity(0.14), tint.opacity(0)], center: .bottomTrailing, startRadius: 0, endRadius: 600)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.45), value: tint)
    }
}

// MARK: - Controls in the glass style

/// Capsule tabs: a faint glass track, and a soft wash of the workspace color that slides under the
/// chosen option — the same language as sidebar selection, instead of the system's solid accent fill.
struct GlassSegmented<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        var symbol: String?
    }

    @Binding var selection: Value
    let options: [Option]
    var compact = false

    @Environment(\.arborTint) private var tint
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var namespace
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.28)) { selection = option.value }
                } label: {
                    HStack(spacing: 4) {
                        if let symbol = option.symbol { Image(systemName: symbol).font(.system(size: compact ? 10 : 11)) }
                        Text(option.title)
                    }
                    .font(.system(size: compact ? 11 : 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
                    .padding(.horizontal, compact ? 10 : 13)
                    .frame(height: compact ? 22 : 26)
                    .background {
                        if selected {
                            selectionPill
                        } else if hovered == option.value {
                            Capsule().fill(Color.primary.opacity(0.05))
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { inside in hovered = inside ? option.value : (hovered == option.value ? nil : hovered) }
            }
        }
        .padding(2)
        .background { Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.045)) }
        .overlay { Capsule().strokeBorder(Surface.hairline) }
        .fixedSize()
    }

    /// A tinted wash, not glass: the control sits on content cards, and glass would bleach the label on it.
    private var selectionPill: some View {
        Capsule()
            .fill(tint.opacity(colorScheme == .dark ? 0.3 : 0.17))
            .overlay { Capsule().strokeBorder(tint.opacity(colorScheme == .dark ? 0.45 : 0.28), lineWidth: 0.75) }
            .matchedGeometryEffect(id: "selection", in: namespace)
    }
}

/// Capsule buttons. Regular ones are real Liquid Glass on macOS 26+ (a hand-drawn approximation before).
/// `.prominent` is the one main action and stays a solid capsule in the workspace color: tinted glass goes
/// gray whenever its window isn't key, leaving white text on pale glass.
/// (Not `GlassButtonStyle`: SwiftUI has its own type by that name.)
struct CapsuleButtonStyle: ButtonStyle {
    enum Kind { case regular, prominent }
    var kind: Kind = .regular
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        CapsuleButtonBody(configuration: configuration, kind: kind, compact: compact)
    }

    private struct CapsuleButtonBody: View {
        let configuration: Configuration
        let kind: Kind
        let compact: Bool
        @Environment(\.arborTint) private var tint
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        private var prominent: Bool { kind == .prominent }

        var body: some View {
            let label = configuration.label
                .labelStyle(.titleAndIcon)
                .font(.system(size: compact ? 11.5 : 13, weight: prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
                .padding(.horizontal, compact ? 10 : 18)
                .frame(height: compact ? 24 : 32)
                .contentShape(Capsule())
            if #available(macOS 26.0, *), !prominent {
                // Interactive glass does its own hover, press and lensing; no drawn fills on top.
                // Disabled dims the label only: faded glass loses its lensing and turns muddy.
                label
                    .opacity(isEnabled ? 1 : 0.45)
                    .glassEffect(.regular.interactive(), in: Capsule())
            } else {
                label
                    .background {
                        if prominent {
                            Capsule().fill(tint.gradient).brightness(hovering ? 0.06 : 0)
                        } else {
                            Capsule().fill(Color.primary.opacity(hovering ? 0.1 : 0.06))
                        }
                    }
                    .overlay { Capsule().strokeBorder(prominent ? Color.white.opacity(0.22) : Surface.hairline, lineWidth: 0.75) }
                    .shadow(color: prominent ? tint.opacity(0.35) : .clear, radius: 10, y: 4)
                    .scaleEffect(configuration.isPressed ? 0.97 : 1)
                    .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
                    .animation(.easeOut(duration: 0.12), value: hovering)
                    .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                    .onHover { hovering = $0 }
            }
        }
    }
}

/// Text links in the workspace color (the system's link style is always blue).
struct TintLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TintLinkBody(configuration: configuration)
    }

    private struct TintLinkBody: View {
        let configuration: Configuration
        @Environment(\.arborTint) private var tint
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(tint)
                .underline(hovering)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    static var glass: CapsuleButtonStyle { CapsuleButtonStyle() }
    static var glassCompact: CapsuleButtonStyle { CapsuleButtonStyle(compact: true) }
    static var glassProminent: CapsuleButtonStyle { CapsuleButtonStyle(kind: .prominent) }
    static var glassProminentCompact: CapsuleButtonStyle { CapsuleButtonStyle(kind: .prominent, compact: true) }
}

extension View {
    /// Liquid Glass in `shape` on macOS 26+; on earlier systems, the `fallback` fill and a hairline.
    /// The glass is a layer behind the view rather than wrapping it: wrapped content gets the glass's
    /// vibrancy, which bleaches colored text and the list's template icons.
    @ViewBuilder
    func floatingGlass(in shape: some Shape, fallback: some ShapeStyle) -> some View {
        if #available(macOS 26.0, *) {
            background { Color.clear.glassEffect(.regular, in: shape) }
        } else {
            background(fallback, in: shape)
                .overlay { shape.stroke(Surface.hairline, lineWidth: 1) }
        }
    }
}

extension ButtonStyle where Self == TintLinkStyle {
    static var tintLink: TintLinkStyle { TintLinkStyle() }
}
