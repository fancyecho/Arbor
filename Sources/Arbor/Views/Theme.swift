import AppKit
import UniformTypeIdentifiers
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

    /// Light and dark values: one step less saturated than a system accent, and lifted in dark mode so the
    /// color still reads on near-black cards.
    private var values: (light: UInt32, dark: UInt32) {
        switch self {
        case .indigo: (0x5B5FD6, 0x8387F0)
        case .coral: (0xD9694A, 0xF08A6C)
        case .teal: (0x1F9D8E, 0x5ACFC5)
        case .violet: (0x8A5BD6, 0xAD86F0)
        case .amber: (0xC98A1C, 0xE8AB45)
        case .rose: (0xD24C78, 0xEE7499)
        case .graphite: (0x687080, 0x9AA1B0)
        }
    }

    /// One shared color object per tint (lists ask for it for every row they draw).
    var nsColor: NSColor { Self.colors[self]! }

    private static let colors: [WorkspaceTint: NSColor] = Dictionary(uniqueKeysWithValues: allCases.map { tint in
        let (light, dark) = tint.values
        return (tint, NSColor(name: nil) { appearance in NSColor(hex: appearance.isDark ? dark : light) })
    })

    /// The tint whose shared color object `color` is, if any.
    static func matching(_ color: NSColor) -> WorkspaceTint? {
        allCases.first { colors[$0] === color }
    }

    var color: Color { Color(nsColor: nsColor) }
}

extension Color {
    /// A workspace color used as text or icon on the sidebar. The sidebar is opaque now and the tint already
    /// has a lifted dark variant, so this is the color itself (kept so call sites read the same).
    func onSidebarGlass(_ scheme: ColorScheme) -> Color { self }
}

private struct ArborTintKey: EnvironmentKey {
    static let defaultValue: Color = WorkspaceTint.indigo.color
}

private struct ArborTintNSColorKey: EnvironmentKey {
    static let defaultValue: NSColor = WorkspaceTint.indigo.nsColor
}

extension EnvironmentValues {
    /// The window's workspace color (use instead of `Color.accentColor`).
    var arborTint: Color {
        get { self[ArborTintKey.self] }
        set { self[ArborTintKey.self] = newValue }
    }

    /// The same color for AppKit drawing (folder icons).
    var arborTintNSColor: NSColor {
        get { self[ArborTintNSColorKey.self] }
        set { self[ArborTintNSColorKey.self] = newValue }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// A color with a light and a dark value.
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.isDark ? dark : light }
    }
}

/// The design scale: every size in the window comes from these few values, so spacing, corners and type
/// stay consistent from view to view.
enum Metrics {
    /// Spacing steps.
    static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24
    /// Cards (panes, inspector).
    static let cardRadius: CGFloat = 16
    /// Wells and previews inside a card.
    static let wellRadius: CGFloat = 10
    /// Rows, chips and small controls.
    static let controlRadius: CGFloat = 8
}

/// Five type sizes, no more.
enum TypeScale {
    /// The folder's name at the top of a pane.
    static let title = Font.system(size: 20, weight: .semibold)
    /// The inspector's file name.
    static let emphasis = Font.system(size: 15, weight: .semibold)
    /// File names, sidebar rows.
    static let body = Font.system(size: 13)
    /// Dates, sizes, kinds, breadcrumbs.
    static let secondary = Font.system(size: 12)
    /// Section titles, status bar.
    static let caption = Font.system(size: 11, weight: .semibold)
}

/// The window is built in three layers, each with one material:
/// - the **base** (window background and sidebar): opaque neutral, with a trace of the workspace color;
/// - **content** cards (panes, inspector): opaque, separated by a hairline and a soft shadow, not by translucency;
/// - **accents** (toolbar groups, floating HUDs, the command palette): Liquid Glass, and only those.
/// (Not `Glass`: that name is SwiftUI's Liquid Glass material.)
enum Surface {
    /// The window's own background, under the sidebar and between the cards.
    static let base = Color(nsColor: .adaptive(light: NSColor(hex: 0xECECF0), dark: NSColor(hex: 0x0F1013)))

    /// Content card fill. The pane receiving commands is a shade brighter in dark mode.
    static func card(active: Bool) -> Color {
        active ? activeCard : inactiveCard
    }

    private static let activeCard = Color(nsColor: .adaptive(light: .white, dark: NSColor(hex: 0x1A1B1F)))
    private static let inactiveCard = Color(nsColor: .adaptive(light: NSColor(hex: 0xFBFBFC), dark: NSColor(hex: 0x15161A)))

    /// The edge of a card against the base.
    static let hairline = Color(nsColor: .adaptive(light: NSColor(hex: 0x1C1C34, alpha: 0.10),
                                                   dark: NSColor(white: 1, alpha: 0.08)))

    /// Separators inside a card.
    static let divider = Color(nsColor: .adaptive(light: NSColor(hex: 0x1C1C34, alpha: 0.07),
                                                  dark: NSColor(white: 1, alpha: 0.06)))

    /// Card shadow: barely there in light mode, deeper on the dark base.
    static let shadow = Color(nsColor: .adaptive(light: NSColor(hex: 0x1C1C34, alpha: 0.06),
                                                 dark: NSColor(white: 0, alpha: 0.38)))

    /// The selected sidebar row: a small solid chip raised off the base.
    static let raised = Color(nsColor: .adaptive(light: .white, dark: NSColor(white: 1, alpha: 0.09)))

    /// Small neutral fills (chips, hover).
    static let chip = Color(nsColor: .adaptive(light: NSColor(hex: 0xF1F1F4), dark: NSColor(white: 1, alpha: 0.06)))
}

extension View {
    /// A content card: opaque fill, hairline edge and a soft shadow, in `shape`.
    func card(_ fill: Color, in shape: some Shape) -> some View {
        background { shape.fill(fill) }
            .clipShape(shape)
            .overlay { shape.stroke(Surface.hairline, lineWidth: 1) }
            .shadow(color: Surface.shadow, radius: 12, y: 4)
    }
}

/// NSVisualEffectView for SwiftUI (still used by a few floating panels).
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

/// The window base: an opaque neutral with a trace of the workspace color, the same whatever the wallpaper.
struct WorkspaceBackdrop: View {
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Surface.base
            tint.opacity(colorScheme == .dark ? 0.025 : 0.04)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.45), value: tint)
    }
}

/// Folders drawn in a soft version of the workspace color: switching workspaces recolors every folder on
/// screen. Every folder gets the same shape, so a list reads as one family; the system's special folders
/// (Desktop, Downloads…) keep their meaning as a glyph on the front, the way Finder marks them.
/// Folders with a custom icon and packages keep their own icon.
@MainActor
enum FolderIcon {
    private static var images: [String: NSImage] = [:]
    private static var customIcons: [String: Bool] = [:]

    static func image(tint: NSColor, glyph: String? = nil) -> NSImage {
        // The workspace colors are shared objects, so their key is just the name: no color conversion
        // on the way to a cached image (this runs for every folder row drawn).
        let colorKey: String
        if let known = WorkspaceTint.matching(tint) {
            colorKey = known.rawValue
        } else {
            colorKey = "\(tint.resolved(dark: false).hexString)-\(tint.resolved(dark: true).hexString)"
        }
        let key = colorKey + "|" + (glyph ?? "")
        if let image = images[key] { return image }
        let (light, dark) = (tint.resolved(dark: false), tint.resolved(dark: true))
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let scale = rect.width / 18
            func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
                NSBezierPath(roundedRect: NSRect(x: x * scale, y: y * scale, width: w * scale, height: h * scale),
                             xRadius: r * scale, yRadius: r * scale)
            }
            let isDark = NSAppearance.currentDrawing().isDark
            let palette = Palette(tint: isDark ? dark : light, dark: isDark)
            // Back sheet with its tab, a shade deeper than the front.
            palette.back.setFill()
            rounded(1.5, 2.6, 6.6, 3.4, 1.3).fill()
            rounded(1.5, 4.0, 15, 11.2, 1.5).fill()
            // Front: lit from above.
            let front = rounded(1.5, 5.6, 15, 9.6, 1.5)
            NSGradient(starting: palette.frontTop, ending: palette.frontBottom)?.draw(in: front, angle: 90)
            NSColor.white.withAlphaComponent(isDark ? 0.18 : 0.45).setFill()
            NSRect(x: 2.6 * scale, y: 5.6 * scale, width: 12.8 * scale, height: max(0.6 * scale, 0.5)).fill()
            if let glyph, let symbol = NSImage(systemSymbolName: glyph, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7 * scale, weight: .bold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [palette.glyph]))) {
                let size = symbol.size
                let fit = min(7.6 * scale / max(size.width, 1), 6.6 * scale / max(size.height, 1), 1)
                let drawn = NSSize(width: size.width * fit, height: size.height * fit)
                let center = NSPoint(x: 9 * scale, y: 10.5 * scale)
                symbol.draw(in: NSRect(x: center.x - drawn.width / 2, y: center.y - drawn.height / 2,
                                       width: drawn.width, height: drawn.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            return true
        }
        images[key] = image
        return image
    }

    /// The folder's colors, worked out from the workspace color: light enough to sit quietly in a list.
    private struct Palette {
        let back, frontTop, frontBottom, glyph: NSColor

        init(tint: NSColor, dark: Bool) {
            if dark {
                back = tint.mixed(with: .black, 0.42)
                frontTop = tint.mixed(with: .white, 0.25)
                frontBottom = tint.mixed(with: .white, 0.06)
                glyph = tint.mixed(with: .black, 0.6).withAlphaComponent(0.75)
            } else {
                back = tint.mixed(with: .white, 0.5)
                frontTop = tint.mixed(with: .white, 0.6)
                frontBottom = tint.mixed(with: .white, 0.38)
                glyph = tint.mixed(with: .black, 0.1).withAlphaComponent(0.85)
            }
        }
    }

    /// Whether `url` (a folder) is drawn as Arbor's folder rather than with its own icon.
    static func tints(_ url: URL, isDirectory: Bool, isPackage: Bool) -> Bool {
        guard isDirectory, !isPackage, AppSettings.shared.tintedFolders else { return false }
        let path = url.standardizedFileURL.path
        if let known = customIcons[path] { return !known }
        // A custom folder icon lives in a hidden "Icon\r" file inside the folder.
        let custom = FileManager.default.fileExists(atPath: path + "/Icon\r")
        customIcons[path] = custom
        return !custom
    }

    /// The icon to show for an item: Arbor's folder (with a glyph for special folders), or the system's icon.
    static func icon(for url: URL, isDirectory: Bool, isPackage: Bool, tint: NSColor) -> NSImage {
        if !isDirectory, !isPackage { return fileIcon(for: url) }
        guard tints(url, isDirectory: isDirectory, isPackage: isPackage) else { return NSWorkspace.shared.icon(forFile: url.path) }
        return image(tint: tint, glyph: specialFolders[url.standardizedFileURL.path])
    }

    private static var typeIcons: [String: NSImage] = [:]

    /// Plain files share their type's icon, looked up once per extension instead of once per row.
    /// Files without an extension (aliases, scripts…) still ask for their own icon.
    private static func fileIcon(for url: URL) -> NSImage {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return NSWorkspace.shared.icon(forFile: url.path) }
        if let icon = typeIcons[ext] { return icon }
        let icon = NSWorkspace.shared.icon(for: type)
        typeIcons[ext] = icon
        return icon
    }

    /// The system's special folders and the glyph each one wears.
    private static let specialFolders: [String: String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var glyphs: [String: String] = [
            home: "house.fill",
            home + "/Desktop": "menubar.dock.rectangle",
            home + "/Documents": "doc.fill",
            home + "/Downloads": "arrow.down.circle.fill",
            home + "/Movies": "film.fill",
            home + "/Music": "music.note",
            home + "/Pictures": "photo.fill",
            home + "/Public": "person.2.fill",
            home + "/Library": "building.columns.fill",
            home + "/Applications": "square.grid.3x3.fill",
            home + "/Sites": "globe",
            home + "/Library/Mobile Documents/com~apple~CloudDocs": "icloud.fill",
            "/Applications": "square.grid.3x3.fill",
            "/Library": "building.columns.fill",
            "/System": "gearshape.fill",
            "/Users": "person.2.fill",
            "/Volumes": "externaldrive.fill",
        ]
        glyphs[home + "/.Trash"] = "trash.fill"
        return glyphs
    }()
}

private extension NSColor {
    /// This color moved `amount` (0…1) of the way toward `other`, in sRGB.
    func mixed(with other: NSColor, _ amount: CGFloat) -> NSColor {
        blended(withFraction: amount, of: other) ?? self
    }

    func resolved(dark: Bool) -> NSColor {
        var result = self
        (NSAppearance(named: dark ? .darkAqua : .aqua) ?? .currentDrawing()).performAsCurrentDrawingAppearance {
            result = self.usingColorSpace(.sRGB) ?? self
        }
        return result
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
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

/// A quiet secondary action inside a card: a neutral capsule the height of a compact prominent button, so a
/// row of actions reads as one set. (Glass is kept for controls that float; these sit on content.)
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.1 : hovering && isEnabled ? 0.075 : 0.05)))
                .overlay(Capsule().strokeBorder(Surface.hairline, lineWidth: 0.75))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

extension ButtonStyle where Self == ChipButtonStyle {
    static var chip: ChipButtonStyle { ChipButtonStyle() }
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
