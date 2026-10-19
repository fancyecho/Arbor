import AppKit
import SwiftUI

/// Each workspace has its own color: the glass, selections and highlights all take it on,
/// so switching workspaces feels like walking into another room.
enum WorkspaceTint: String, Codable, CaseIterable, Identifiable {
    case indigo, coral, teal, violet, amber, rose, graphite

    var id: Self { self }

    var title: String {
        switch self {
        case .indigo: "靛蓝"
        case .coral: "珊瑚"
        case .teal: "青绿"
        case .violet: "紫罗兰"
        case .amber: "琥珀"
        case .rose: "玫瑰"
        case .graphite: "石墨"
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

/// Glass surfaces shared by the window: a translucent, blurred backdrop and the floating pane cards.
enum Glass {
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
