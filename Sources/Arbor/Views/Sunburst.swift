import AppKit
import SwiftUI

// MARK: - Layout

/// How the rings are colored: by branch (each top-level folder its own hue, like a color wheel) or by
/// what the files are (videos, apps, caches…).
enum SpaceColoring: String, CaseIterable, Identifiable {
    case folders, types
    var id: Self { self }
    var title: String { self == .folders ? L("文件夹") : L("类型") }
}

struct SunSegment: Identifiable, Equatable {
    let id: Int
    /// nil for the slice that groups children too small to draw.
    let node: SpaceNode?
    /// Ring, from 1 (innermost).
    let depth: Int
    /// Fractions of a full turn, clockwise from 12 o'clock.
    let start: Double
    let end: Double
    /// Index of the innermost ancestor's slice among the first ring's slices (for branch colors).
    let branch: Int
    let category: FileCategory
    let parent: Int?

    static func == (lhs: SunSegment, rhs: SunSegment) -> Bool {
        lhs.id == rhs.id && lhs.node === rhs.node && lhs.start == rhs.start && lhs.end == rhs.end
    }
}

struct SunburstLayout {
    let segments: [SunSegment]
    let branchCount: Int
    let maxDepth: Int
    let total: Int64

    /// Four rings read calmly; deeper levels are a click away.
    static let maxDepth = 4

    /// Smallest slice drawn on its own, as a fraction of a turn. Outer rings ask for more, so the edge of
    /// the chart isn't a fringe of slivers; what's too thin joins one quiet "smaller items" slice.
    static func minFraction(depth: Int) -> Double {
        0.0025 * pow(1.55, Double(depth - 1))
    }

    /// `extra` is shown as an additional first-ring slice (the space a volume reports but the scan can't see).
    static func make(root: SpaceNode, extra: SpaceNode? = nil, maxDepth: Int = maxDepth) -> SunburstLayout {
        var segments: [SunSegment] = []
        let total = root.size + (extra?.size ?? 0)
        guard total > 0 else { return SunburstLayout(segments: [], branchCount: 0, maxDepth: maxDepth, total: 0) }
        var branches = 0

        func place(_ children: [SpaceNode], of size: Int64, depth: Int, start: Double, end: Double,
                   branch: Int, parent: Int?) {
            guard depth <= maxDepth, size > 0 else { return }
            let span = end - start
            let threshold = minFraction(depth: depth)
            var cursor = start
            for (index, child) in children.enumerated() {
                let fraction = span * Double(child.size) / Double(size)
                if fraction < threshold {
                    // Children are largest first: everything from here on is too thin to draw on its own.
                    let rest = children[index...].reduce(Int64(0)) { $0 + $1.size }
                    let restFraction = span * Double(rest) / Double(size)
                    if restFraction >= threshold * 0.5 {
                        segments.append(SunSegment(id: segments.count, node: nil, depth: depth, start: cursor,
                                                   end: cursor + restFraction, branch: branch, category: .other,
                                                   parent: parent))
                    }
                    return
                }
                let ownBranch = depth == 1 ? branches : branch
                if depth == 1 { branches += 1 }
                let id = segments.count
                segments.append(SunSegment(id: id, node: child, depth: depth, start: cursor, end: cursor + fraction,
                                           branch: ownBranch, category: child.dominantCategory, parent: parent))
                if child.isContainer, fraction >= minFraction(depth: depth + 1) * 2 {
                    place(child.children, of: child.size, depth: depth + 1, start: cursor, end: cursor + fraction,
                          branch: ownBranch, parent: id)
                }
                cursor += fraction
            }
        }

        var top = root.children
        if let extra, extra.size > 0 {
            top.append(extra)
            top.sort { $0.size > $1.size }
        }
        place(top, of: total, depth: 1, start: 0, end: 1, branch: 0, parent: nil)
        return SunburstLayout(segments: segments, branchCount: branches, maxDepth: maxDepth, total: total)
    }

    /// The slice for `node` in this layout, if drawn.
    func segment(for node: SpaceNode) -> SunSegment? {
        segments.first { $0.node === node }
    }

    /// Whether `segment` is `ancestor` or lies inside it.
    func isWithin(_ segment: SunSegment, _ ancestor: Int) -> Bool {
        var current: Int? = segment.id
        while let id = current {
            if id == ancestor { return true }
            current = segments[id].parent
        }
        return false
    }
}

// MARK: - Colors

struct SpacePalette {
    struct Tone {
        var hue: Double
        var saturation: Double
        var brightness: Double
        var opacity: Double = 1

        var color: Color { Color(hue: hue, saturation: saturation, brightness: brightness).opacity(opacity) }
        /// A touch lighter and softer: the outer edge of a slice's gradient.
        var light: Color {
            Color(hue: hue, saturation: saturation * 0.82, brightness: min(brightness + 0.07, 1)).opacity(opacity)
        }
    }

    let coloring: SpaceColoring

    init(coloring: SpaceColoring) {
        self.coloring = coloring
    }

    /// Ten hand-picked colors for the first ring's branches, warm and cool taking turns so neighbors
    /// never blur together. The same in every window, whatever its workspace color.
    static let branchColors: [(h: Double, s: Double, b: Double)] = [
        (0.64, 0.56, 0.92), // indigo
        (0.03, 0.52, 0.96), // coral
        (0.46, 0.55, 0.76), // teal
        (0.11, 0.60, 0.98), // amber
        (0.78, 0.44, 0.90), // violet
        (0.56, 0.55, 0.95), // sky
        (0.94, 0.46, 0.93), // rose
        (0.30, 0.48, 0.78), // green
        (0.08, 0.38, 0.88), // apricot
        (0.70, 0.26, 0.82), // lavender gray
    ]

    func color(for segment: SunSegment) -> Color { tone(for: segment)?.color ?? Self.groupColor }

    func color(node: SpaceNode, branch: Int, depth: Int) -> Color {
        tone(node: node, branch: branch, depth: depth)?.color ?? Self.groupColor
    }

    /// "Smaller items" and other groups: barely more than the ring's track, so they recede.
    static let groupColor = Color.primary.opacity(0.085)

    func tone(for segment: SunSegment) -> Tone? {
        segment.node.flatMap { tone(node: $0, branch: segment.branch, depth: segment.depth) }
    }

    /// nil means "draw as a quiet group" (small files, unreadable folders).
    func tone(node: SpaceNode, branch: Int, depth: Int) -> Tone? {
        switch node.kind {
        case .smallFiles, .unreadable: return nil
        case .hidden: return Tone(hue: 0.62, saturation: 0.06, brightness: 0.5, opacity: 0.8)
        default: break
        }
        let fade = pow(0.86, Double(depth - 1))
        let lift = 0.03 * Double(depth - 1)
        if coloring == .types {
            let base = node.dominantCategory.hsb
            return Tone(hue: base.h, saturation: base.s * fade, brightness: min(base.b + lift, 1))
        }
        let colors = Self.branchColors
        let base = colors[branch % colors.count]
        // Past the tenth branch the colors repeat, a shade deeper so repeats don't sit side by side.
        let round = Double(branch / colors.count)
        let leaf = node.kind == .file ? 0.8 : 1
        return Tone(hue: base.h, saturation: base.s * fade * leaf,
                    brightness: min(max(base.b - 0.08 * round, 0.55) + lift, 1))
    }
}

extension FileCategory {
    var hsb: (h: Double, s: Double, b: Double) {
        switch self {
        case .video: (0.97, 0.6, 0.93)
        case .image: (0.07, 0.62, 0.97)
        case .audio: (0.82, 0.46, 0.9)
        case .document: (0.57, 0.56, 0.95)
        case .app: (0.69, 0.5, 0.93)
        case .developer: (0.43, 0.52, 0.8)
        case .archive: (0.12, 0.56, 0.9)
        case .cache: (0.52, 0.3, 0.8)
        case .other: (0.62, 0.08, 0.72)
        }
    }

    var color: Color { Color(hue: hsb.h, saturation: hsb.s, brightness: hsb.b) }
}

// MARK: - Geometry

/// Ring radii: rings get a little thinner further out, like the outer rings of a tree.
struct SunRings {
    let center: CGPoint
    let hole: CGFloat
    let radius: CGFloat
    private let edges: [CGFloat]

    init(size: CGSize, maxDepth: Int) {
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        radius = max(min(size.width, size.height) / 2 - 10, 10)
        hole = radius * 0.36
        let weights = (0..<maxDepth).map { pow(0.8, Double($0)) }
        let total = weights.reduce(0, +)
        var edges = [hole]
        for weight in weights { edges.append(edges.last! + (radius - hole) * CGFloat(weight / total)) }
        self.edges = edges
    }

    /// Inner edge of ring `depth` (1-based); fractional depths interpolate, for the zoom animation.
    func inner(_ depth: Double) -> CGFloat {
        let index = depth - 1
        if index <= 0 {
            let first = edges[1] - edges[0]
            return edges[0] + CGFloat(index) * first
        }
        if index >= Double(edges.count - 1) {
            let last = edges[edges.count - 1] - edges[edges.count - 2]
            return edges[edges.count - 1] + CGFloat(index - Double(edges.count - 1)) * last
        }
        let lower = Int(index)
        let t = CGFloat(index - Double(lower))
        return edges[lower] + (edges[lower + 1] - edges[lower]) * t
    }

    /// Ring and turn-fraction under `point`, or nil outside the rings.
    func locate(_ point: CGPoint, maxDepth: Int) -> (depth: Int, fraction: Double)? {
        let dx = point.x - center.x, dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        guard distance >= hole, distance <= radius else { return nil }
        var depth = 1
        while depth < maxDepth, distance >= inner(Double(depth + 1)) { depth += 1 }
        var angle = atan2(dx, -dy) // 0 at 12 o'clock, clockwise
        if angle < 0 { angle += 2 * .pi }
        return (depth, Double(angle / (2 * .pi)))
    }

    /// A ring slice with softly rounded corners and an even gap to its neighbors on every side.
    static func wedge(center: CGPoint, inner: CGFloat, outer: CGFloat, start: Double, end: Double,
                      corner: CGFloat = 4) -> Path {
        let gap: CGFloat = 1.1 // half the gap between slices, in points
        let ri = inner + 0.9, ro = outer - 0.9
        var path = Path()
        guard ro > ri + 0.5 else { return path }
        let a0 = start * 2 * .pi - .pi / 2, a1 = end * 2 * .pi - .pi / 2
        let padOuter = Double(gap / ro), padInner = Double(gap / ri)
        let o0 = a0 + padOuter, o1 = a1 - padOuter
        let i0 = a0 + padInner, i1 = a1 - padInner
        guard o1 - o0 > 0.0004 else { return path }
        func point(_ radius: CGFloat, _ angle: Double) -> CGPoint {
            CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
        }
        let thickness = ro - ri
        var r = min(corner, thickness / 2 - 0.3, ro * CGFloat(o1 - o0) / 2 - 0.3)
        if i1 - i0 > 0 { r = min(r, ri * CGFloat(i1 - i0) / 2 - 0.3) }
        r = max(r, 0)

        guard i1 - i0 > 0.0004 else {
            // Too narrow at the inner edge: a slim wedge that meets in a point.
            let mid = (a0 + a1) / 2
            path.move(to: point(ro, o0))
            path.addArc(center: center, radius: ro, startAngle: .radians(o0), endAngle: .radians(o1), clockwise: false)
            path.addLine(to: point(ri, mid))
            path.closeSubpath()
            return path
        }
        let dOuter = Double(r / ro), dInner = Double(r / ri)
        path.move(to: point(ro, o0 + dOuter))
        path.addArc(center: center, radius: ro, startAngle: .radians(o0 + dOuter), endAngle: .radians(o1 - dOuter),
                    clockwise: false)
        path.addQuadCurve(to: point(ro - r, o1), control: point(ro, o1))
        path.addLine(to: point(ri + r, i1))
        path.addQuadCurve(to: point(ri, i1 - dInner), control: point(ri, i1))
        path.addArc(center: center, radius: ri, startAngle: .radians(i1 - dInner), endAngle: .radians(i0 + dInner),
                    clockwise: true)
        path.addQuadCurve(to: point(ri + r, i0), control: point(ri, i0))
        path.addLine(to: point(ro - r, o0))
        path.addQuadCurve(to: point(ro, o0 + dOuter), control: point(ro, o0))
        path.closeSubpath()
        return path
    }

    /// A whole ring (the faint track every ring sits on).
    static func annulus(center: CGPoint, inner: CGFloat, outer: CGFloat) -> Path {
        var path = Path()
        let ri = inner + 0.9, ro = outer - 0.9
        guard ro > ri else { return path }
        path.addEllipse(in: CGRect(x: center.x - ro, y: center.y - ro, width: ro * 2, height: ro * 2))
        path.addEllipse(in: CGRect(x: center.x - ri, y: center.y - ri, width: ri * 2, height: ri * 2))
        return path
    }
}

// MARK: - View

/// The rings. Hover lights up a slice and everything inside it; clicking a folder zooms into it (the pane
/// navigates there), clicking the middle goes back up. Rings draw themselves in when the chart appears.
struct SunburstView: View {
    let root: SpaceNode
    let layout: SunburstLayout
    let palette: SpacePalette
    @Binding var hovered: SpaceNode?
    let onActivate: (SpaceNode) -> Void
    let onCenter: () -> Void

    /// The zoom between the previous root and this one.
    @State private var zoom: Zoom?
    /// The rings sweeping in, the first time the chart appears (or after jumping somewhere unrelated).
    @State private var reveal: Date?
    @State private var previous: (root: SpaceNode, layout: SunburstLayout)?
    @State private var size: CGSize = .zero
    /// The highlight moving from one slice to another, cross-faded instead of snapping.
    @State private var focusFade: (from: SpaceNode?, began: Date)?
    @Environment(\.colorScheme) private var colorScheme

    struct Zoom {
        enum Direction { case into, outOf }
        let direction: Direction
        /// The slice (as fractions of a turn) that grows into the whole circle, or shrinks back into.
        let start: Double
        let end: Double
        let began: Date
    }

    private static let revealDuration = 1.1
    private static let focusDuration = 0.16

    var body: some View {
        TimelineView(.animation(paused: zoom == nil && reveal == nil && focusFade == nil)) { context in
            let zoomProgress = zoom.map { Double(DeckGeometry.ease(context.date.timeIntervalSince($0.began) * 0.85)) } ?? 1
            let revealTime = reveal.map { context.date.timeIntervalSince($0) }
            // Clamped: a paused timeline hands back a stale date on its first frame, giving negative time.
            let focusProgress = focusFade.map { min(max(context.date.timeIntervalSince($0.began) / Self.focusDuration, 0), 1) } ?? 1
            Canvas { graphics, size in
                draw(in: &graphics, size: size, zoomProgress: zoomProgress, revealTime: revealTime,
                     focusProgress: focusProgress)
            }
            .onChange(of: zoomProgress >= 0.999) { _, done in if done { zoom = nil } }
            .onChange(of: (revealTime ?? 0) > Self.revealDuration) { _, done in if done { reveal = nil } }
            .onChange(of: focusProgress >= 1) { _, done in if done { focusFade = nil } }
        }
        .onChange(of: hovered.map(ObjectIdentifier.init)) { old, _ in
            let from = old.flatMap { id in layout.segments.first { $0.node.map(ObjectIdentifier.init) == id }?.node }
            focusFade = (from, .now)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hovered = node(at: point)
            case .ended: hovered = nil
            }
        }
        .gesture(SpatialTapGesture().onEnded { value in
            if let node = node(at: value.location) {
                onActivate(node)
            } else if isInHole(value.location) {
                onCenter()
            }
        })
        .onChange(of: ObjectIdentifier(root)) { _, _ in startZoom() }
        .onAppear {
            previous = (root, layout)
            reveal = .now
        }
    }

    private func rings(for size: CGSize) -> SunRings { SunRings(size: size, maxDepth: layout.maxDepth) }

    private func node(at point: CGPoint) -> SpaceNode? {
        guard size != .zero, let hit = rings(for: size).locate(point, maxDepth: layout.maxDepth) else { return nil }
        return layout.segments.first { $0.depth == hit.depth && hit.fraction >= $0.start && hit.fraction < $0.end }?.node
    }

    private func isInHole(_ point: CGPoint) -> Bool {
        let rings = rings(for: size)
        let dx = point.x - rings.center.x, dy = point.y - rings.center.y
        return sqrt(dx * dx + dy * dy) < rings.hole
    }

    private func startZoom() {
        defer { previous = (root, layout) }
        guard let previous else { return }
        if root.parent === previous.root, let slice = previous.layout.segment(for: root), slice.depth == 1 {
            zoom = Zoom(direction: .into, start: slice.start, end: slice.end, began: .now)
        } else if previous.root.parent === root, let slice = layout.segment(for: previous.root), slice.depth == 1 {
            zoom = Zoom(direction: .outOf, start: slice.start, end: slice.end, began: .now)
        } else {
            zoom = nil
            reveal = .now
        }
    }

    /// How strongly `segment` shows while `focus` is under the pointer: the slice itself, what's inside it
    /// and its path back to the middle stay; everything else steps back.
    private func emphasis(of segment: SunSegment, focus: SunSegment?, dimmed: Double) -> Double {
        guard let focus else { return 1 }
        if segment.id == focus.id { return 1 }
        // What's inside the slice and the path back to the middle stay readable, a step below the slice itself.
        if layout.isWithin(segment, focus.id) || layout.isWithin(focus, segment.id) { return colorScheme == .dark ? 0.9 : 0.72 }
        return dimmed
    }

    private func draw(in graphics: inout GraphicsContext, size: CGSize, zoomProgress p: Double, revealTime: Double?,
                      focusProgress: Double) {
        let rings = rings(for: size)
        let dark = colorScheme == .dark

        // The silhouette is always a whole disc: each ring has a faint track, the edge a hairline.
        for depth in 1...layout.maxDepth {
            let track = SunRings.annulus(center: rings.center, inner: rings.inner(Double(depth)),
                                         outer: rings.inner(Double(depth + 1)))
            graphics.fill(track, with: .color(Color.primary.opacity(dark ? 0.05 : 0.04)), style: FillStyle(eoFill: true))
        }
        let edge = rings.radius + 3
        graphics.stroke(Path(ellipseIn: CGRect(x: rings.center.x - edge, y: rings.center.y - edge, width: edge * 2, height: edge * 2)),
                        with: .color(Color.primary.opacity(dark ? 0.08 : 0.07)), lineWidth: 0.75)

        let focus = hovered.flatMap { layout.segment(for: $0) }
        let fadingFrom = focusFade.flatMap { $0.from }.flatMap { layout.segment(for: $0) }
        let fading = focusFade != nil
        let dimmed = dark ? 0.38 : 0.42
        var outlines: [(path: Path, tone: SpacePalette.Tone, strength: Double, inner: CGFloat, outer: CGFloat)] = []

        for segment in layout.segments {
            var start = segment.start, end = segment.end
            var depth = Double(segment.depth)
            if let zoom {
                let width = max(zoom.end - zoom.start, 0.0001)
                switch zoom.direction {
                case .into:
                    // The new root was one slice of the old chart: start there, open up to the full circle.
                    start = mix(zoom.start + start * width, start, p)
                    end = mix(zoom.start + end * width, end, p)
                    depth = mix(depth + 1, depth, p)
                case .outOf:
                    // The old root fills the circle at first, then shrinks back into its slice.
                    start = max(mix((start - zoom.start) / width, start, p), 0)
                    end = min(mix((end - zoom.start) / width, end, p), 1)
                    depth = mix(depth - 1, depth, p)
                    if end <= start { continue }
                }
            } else if let revealTime {
                // Sweep clockwise, each ring a beat after the one inside it.
                let sweep = Double(DeckGeometry.ease((revealTime - 0.08 * Double(segment.depth - 1)) * 0.75))
                if start >= sweep { continue }
                end = min(end, sweep)
            }
            let inner = max(rings.inner(depth), rings.hole)
            let outer = rings.inner(depth + 1)
            guard outer > inner + 1 else { continue }

            // Cross-fade between the previous highlight and the current one.
            let now = emphasis(of: segment, focus: focus, dimmed: dimmed)
            let before = fading ? emphasis(of: segment, focus: fadingFrom, dimmed: dimmed) : now
            let opacity = mix(before, now, focusProgress)

            let path = SunRings.wedge(center: rings.center, inner: inner, outer: outer, start: start, end: end)
            if var tone = palette.tone(for: segment) {
                let isFocus = segment.id == focus?.id
                let wasFocus = fading && segment.id == fadingFrom?.id
                let highlight = (isFocus ? focusProgress : 0) + (wasFocus ? 1 - focusProgress : 0)
                if highlight > 0 {
                    // The slice itself takes on a deeper, richer version of its color (light pastels need it most).
                    if dark {
                        tone.brightness = min(tone.brightness + 0.05 * highlight, 1)
                        tone.saturation = min(tone.saturation * (1 + 0.12 * highlight), 1)
                    } else {
                        tone.saturation = min(tone.saturation * (1 + 0.45 * highlight), 1)
                        tone.brightness = tone.brightness - 0.06 * highlight
                    }
                    outlines.append((path, tone, highlight, inner, outer))
                }
                let shading = GraphicsContext.Shading.radialGradient(
                    Gradient(colors: [tone.color.opacity(opacity), tone.light.opacity(opacity)]),
                    center: rings.center, startRadius: inner, endRadius: outer)
                graphics.fill(path, with: shading)
            } else {
                graphics.fill(path, with: .color(SpacePalette.groupColor.opacity(opacity)))
            }
        }

        // The slice under the pointer glows softly in its own color, with a fine light edge — it stands
        // out without moving, covering its neighbors or wearing a dark outline.
        for outline in outlines {
            let tone = outline.tone
            // On light backgrounds a light glow vanishes: use a deeper shade of the slice's own color there.
            let glowColor = dark
                ? tone.color.opacity(0.75 * outline.strength)
                : Color(hue: tone.hue, saturation: min(tone.saturation * 1.2, 1), brightness: tone.brightness * 0.72)
                    .opacity(0.5 * outline.strength)
            var glow = graphics
            glow.addFilter(.shadow(color: glowColor, radius: dark ? 9 : 10, y: dark ? 0 : 2))
            glow.fill(outline.path, with: .radialGradient(
                Gradient(colors: [tone.color, tone.light]),
                center: rings.center, startRadius: outline.inner, endRadius: outline.outer))
            // Edge: a fine light line in dark mode; in light mode a mid-tone of the same color — present, not harsh.
            let rim = dark
                ? Color.white.opacity(0.55 * outline.strength)
                : Color(hue: tone.hue, saturation: min(tone.saturation * 1.25, 1), brightness: tone.brightness * 0.82)
                    .opacity(0.75 * outline.strength)
            graphics.stroke(outline.path, with: .color(rim), lineWidth: dark ? 1.25 : 1.5)
        }
    }

    private func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}
