import AppKit
import SwiftUI

// MARK: - Pane width math

/// Width rules for the panes: shared by the deck, the window's minimum size and the tests.
enum PanesView {
    static let gap: CGFloat = 10
    static let minimumWidth: CGFloat = 240

    /// Pane widths always add up to exactly `available`: panes are never pushed under the inspector
    /// or out of the window. Each keeps `minimum` while there is room, and they share equally when not.
    static func widths(_ fractions: [CGFloat], available: CGFloat, minimum: CGFloat) -> [CGFloat] {
        let count = fractions.count
        guard count > 0 else { return [] }
        let space = max(available, 0)
        let floor = min(minimum, space / CGFloat(count))
        var weights = fractions.map { max($0, 0.0001) }
        var fixed = [Bool](repeating: false, count: count)
        var result = [CGFloat](repeating: floor, count: count)
        // Water-filling: panes that would fall below the floor are pinned to it, the rest share what's left.
        while true {
            let free = (0..<count).filter { !fixed[$0] }
            guard !free.isEmpty else { break }
            let remaining = space - floor * CGFloat(count - free.count)
            let weight = free.reduce(0) { $0 + weights[$1] }
            var pinned = false
            for index in free {
                result[index] = remaining * weights[index] / weight
                if result[index] < floor {
                    fixed[index] = true
                    result[index] = floor
                    weights[index] = 0
                    pinned = true
                }
            }
            if !pinned { break }
        }
        return result
    }

    /// The preferred minimum, or an equal share when the panes can't all have it.
    static func effectiveMinimum(_ available: CGFloat, count: Int) -> CGFloat {
        min(minimumWidth, max(available, 0) / CGFloat(max(count, 1)))
    }

    /// Room the panes need for each to get the preferred minimum (cards plus the gaps around them).
    static func preferredWidth(count: Int) -> CGFloat {
        minimumWidth * CGFloat(count) + gap * CGFloat(count + 1)
    }

    /// Sets pane `index` and the next one from a drag's total translation, clamped so both stay at least
    /// `minimumWidth` wide. Same input → same output, so a drag can't oscillate.
    static func resized(_ start: [CGFloat], divider index: Int, translation: CGFloat, available: CGFloat,
                        count: Int, minimumWidth: CGFloat) -> [CGFloat]? {
        guard start.indices.contains(index + 1) else { return nil }
        let total = start.prefix(count).reduce(0, +)
        let perPoint = total / max(available, 1)
        let pair = start[index] + start[index + 1]
        let minimum = minimumWidth * perPoint
        guard pair > minimum * 2 else { return nil }
        let left = min(max(start[index] + translation * perPoint, minimum), pair - minimum)
        var fractions = start
        fractions[index] = left
        fractions[index + 1] = pair - left
        return fractions
    }
}

// MARK: - Deck geometry

/// What the window should settle on.
struct DeckTarget: Equatable {
    var sidebar: Bool
    var inspector: Bool
    var inspectorWidth: CGFloat
    /// Visible panes, left to right.
    var panes: [UUID]
    /// Relative widths of the visible panes.
    var fractions: [CGFloat]

    /// Changes worth animating (as opposed to a gutter drag or the window being resized).
    func differsInShape(from other: DeckTarget) -> Bool {
        sidebar != other.sidebar || inspector != other.inspector || panes != other.panes
    }
}

/// The window's layout at one instant, as numbers that can be blended: how far the sidebar and inspector
/// are in (0…1), each pane's share of the pane area and how present it is (0 while arriving/leaving).
struct DeckPose: Equatable {
    var sidebar: CGFloat
    var inspector: CGFloat
    var inspectorWidth: CGFloat
    var shares: [UUID: CGFloat]
    var presence: [UUID: CGFloat]

    static func blend(_ a: DeckPose, _ b: DeckPose, _ t: CGFloat) -> DeckPose {
        func mix(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        let keys = Set(a.shares.keys).union(b.shares.keys)
        var shares: [UUID: CGFloat] = [:]
        var presence: [UUID: CGFloat] = [:]
        for key in keys {
            shares[key] = mix(a.shares[key] ?? 0, b.shares[key] ?? 0)
            presence[key] = mix(a.presence[key] ?? 0, b.presence[key] ?? 0)
        }
        return DeckPose(sidebar: mix(a.sidebar, b.sidebar), inspector: mix(a.inspector, b.inspector),
                        inspectorWidth: mix(a.inspectorWidth, b.inspectorWidth), shares: shares, presence: presence)
    }
}

/// Where every card goes. Cards keep their full width while sliding in or out; only panes change width.
struct DeckGeometry: Equatable {
    struct Pane: Equatable, Identifiable {
        let id: UUID
        var x: CGFloat
        var width: CGFloat
        var presence: CGFloat
    }

    var sidebarX: CGFloat
    var sidebarPresence: CGFloat
    var inspectorX: CGFloat
    var inspectorWidth: CGFloat
    var inspectorPresence: CGFloat
    var panes: [Pane]

    static let margin: CGFloat = 10
    static let sidebarWidth: CGFloat = 220
    /// Sidebar card plus its leading margin.
    static var sidebarSpace: CGFloat { sidebarWidth + margin }

    /// Space the visible panes share once settled (window width minus sidebar, inspector and gaps).
    static func paneArea(width: CGFloat, target: DeckTarget) -> CGFloat {
        let sidebar = target.sidebar ? sidebarSpace : 0
        let inspector = target.inspector ? target.inspectorWidth + margin : 0
        let gaps = PanesView.gap * CGFloat(max(target.panes.count - 1, 0)) + margin * 2
        return max(width - sidebar - inspector - gaps, 0)
    }

    /// The settled pose for `target` in a window `width` wide.
    static func pose(of target: DeckTarget, width: CGFloat) -> DeckPose {
        let area = paneArea(width: width, target: target)
        let fractions = target.fractions.count == target.panes.count
            ? target.fractions : Array(repeating: 1, count: target.panes.count)
        let widths = PanesView.widths(fractions, available: area, minimum: PanesView.minimumWidth)
        let total = max(widths.reduce(0, +), 0.0001)
        var shares: [UUID: CGFloat] = [:]
        var presence: [UUID: CGFloat] = [:]
        for (index, id) in target.panes.enumerated() {
            shares[id] = area > 0 ? widths[index] / total : 1 / CGFloat(target.panes.count)
            presence[id] = 1
        }
        return DeckPose(sidebar: target.sidebar ? 1 : 0, inspector: target.inspector ? 1 : 0,
                        inspectorWidth: target.inspectorWidth, shares: shares, presence: presence)
    }

    /// Lays out `pose` for panes in `order` (which may include panes on their way out).
    static func layout(_ pose: DeckPose, order: [UUID], width: CGFloat) -> DeckGeometry {
        let left = sidebarSpace * pose.sidebar + margin
        let right = width - (pose.inspectorWidth + margin) * pose.inspector - margin
        // A gap opens only between panes that are both there: an arriving pane brings its gap with it.
        var gaps: [CGFloat] = []
        var before: CGFloat = 0
        for (index, id) in order.enumerated() {
            let presence = pose.presence[id] ?? 0
            gaps.append(index == 0 ? 0 : PanesView.gap * min(presence, before))
            before = max(before, presence)
        }
        let area = max(right - left - gaps.reduce(0, +), 0)
        let totalShare = max(order.reduce(0) { $0 + (pose.shares[$1] ?? 0) }, 0.0001)
        var x = left
        var panes: [Pane] = []
        for (index, id) in order.enumerated() {
            x += gaps[index]
            let paneWidth = area * (pose.shares[id] ?? 0) / totalShare
            panes.append(Pane(id: id, x: x, width: paneWidth, presence: pose.presence[id] ?? 0))
            x += paneWidth
        }
        return DeckGeometry(
            sidebarX: margin - sidebarSpace * (1 - pose.sidebar), sidebarPresence: pose.sidebar,
            inspectorX: width - (pose.inspectorWidth + margin) * pose.inspector, inspectorWidth: pose.inspectorWidth,
            inspectorPresence: pose.inspector, panes: panes)
    }

    /// Critically damped spring, starting at rest: quick to get going, long soft landing, no overshoot.
    static func ease(_ time: Double) -> CGFloat {
        let omega = 16.0
        let t = max(time, 0)
        return CGFloat(1 - (1 + omega * t) * exp(-omega * t))
    }

    static let duration: Double = 0.5
}

/// One pane card for one frame: where it is, and how wide its content is laid out.
struct DeckPaneFrame: Equatable, Identifiable {
    let id: UUID
    var x: CGFloat
    var width: CGFloat
    /// The content's own width: the card's for a pane that stays; the final width for one arriving (the
    /// card uncovers it); the old width for one leaving (the card covers it).
    var contentWidth: CGFloat
    /// While animating, the width the pane is heading for, so lists choose their columns once, up front.
    var plannedWidth: CGFloat?
    var presence: CGFloat
}

struct DeckFrame: Equatable {
    var geometry: DeckGeometry
    var panes: [DeckPaneFrame]
    var isAnimating: Bool
}

// MARK: - Animator

/// Drives the window's layout transitions: every frame is computed explicitly (no implicit SwiftUI
/// animation), so the glass cards and the AppKit lists inside them always agree on their size.
@MainActor @Observable
final class DeckAnimator {
    private(set) var target: DeckTarget?
    /// Panes being drawn: the target's, plus any still leaving (kept at their old position).
    private(set) var order: [UUID] = []
    /// Eased progress of the current transition; observed, so views redraw every tick.
    private(set) var progress: CGFloat = 1

    @ObservationIgnored private var from: DeckPose?
    @ObservationIgnored private var fromOrder: [UUID] = []
    @ObservationIgnored private var fromWidths: [UUID: CGFloat] = [:]
    @ObservationIgnored private var started: CFTimeInterval = 0
    @ObservationIgnored private var timer: Timer?
    /// Last window width a frame was computed for (needed to capture the pose when retargeting).
    @ObservationIgnored private var lastWidth: CGFloat = 0

    var isAnimating: Bool { progress < 1 }

    /// Points the deck at a new target, animating from wherever it is now.
    func retarget(_ newTarget: DeckTarget, animated: Bool) {
        guard newTarget != target else { return }
        guard target != nil, animated, lastWidth > 0 else {
            target = newTarget
            if !isAnimating { order = newTarget.panes } else { order = Self.merge(order, into: newTarget.panes) }
            return
        }
        // Capture the pose on screen right now, including a transition that's still running.
        let current = pose(at: CACurrentMediaTime(), width: lastWidth)
        let currentGeometry = DeckGeometry.layout(current, order: order, width: lastWidth)
        fromWidths = Dictionary(uniqueKeysWithValues: currentGeometry.panes.map { ($0.id, $0.width) })
        from = current
        fromOrder = order
        target = newTarget
        order = Self.merge(order, into: newTarget.panes)
        started = CACurrentMediaTime()
        progress = 0
        startTimer()
    }

    /// The frame to draw for a window `width` wide.
    func frame(width: CGFloat) -> DeckFrame? {
        guard let target else { return nil }
        lastWidth = width
        let settled = DeckGeometry.pose(of: target, width: width)
        guard isAnimating, let from else {
            let geometry = DeckGeometry.layout(settled, order: target.panes, width: width)
            let panes = geometry.panes.map {
                DeckPaneFrame(id: $0.id, x: $0.x, width: $0.width, contentWidth: $0.width, plannedWidth: nil, presence: 1)
            }
            return DeckFrame(geometry: geometry, panes: panes, isAnimating: false)
        }
        let pose = DeckPose.blend(from, settled, progress)
        let geometry = DeckGeometry.layout(pose, order: order, width: width)
        let final = DeckGeometry.layout(settled, order: target.panes, width: width)
        let finalWidths = Dictionary(uniqueKeysWithValues: final.panes.map { ($0.id, $0.width) })
        let panes = geometry.panes.map { pane -> DeckPaneFrame in
            let destination = finalWidths[pane.id] ?? fromWidths[pane.id] ?? pane.width
            // A pane that stays lays out live (its list squeezes or grows columns smoothly); one arriving
            // is laid out at its final width and uncovered; one leaving keeps its width and is covered.
            let stays = (from.presence[pane.id] ?? 0) > 0.5 && finalWidths[pane.id] != nil
            return DeckPaneFrame(id: pane.id, x: pane.x, width: pane.width,
                                 contentWidth: stays ? pane.width : max(pane.width, destination),
                                 plannedWidth: destination, presence: pane.presence)
        }
        return DeckFrame(geometry: geometry, panes: panes, isAnimating: true)
    }

    private func pose(at time: CFTimeInterval, width: CGFloat) -> DeckPose {
        guard let target else { return DeckPose(sidebar: 0, inspector: 0, inspectorWidth: 0, shares: [:], presence: [:]) }
        let settled = DeckGeometry.pose(of: target, width: width)
        guard isAnimating, let from else { return settled }
        return DeckPose.blend(from, settled, DeckGeometry.ease(time - started))
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let elapsed = CACurrentMediaTime() - started
        if elapsed >= DeckGeometry.duration {
            progress = 1
            from = nil
            fromWidths = [:]
            if let target { order = target.panes }
            timer?.invalidate()
            timer = nil
        } else {
            progress = DeckGeometry.ease(elapsed)
        }
    }

    /// `new` in order, with panes that are leaving kept at their old position.
    static func merge(_ old: [UUID], into new: [UUID]) -> [UUID] {
        var result = new
        for (index, id) in old.enumerated() where !new.contains(id) {
            // Insert after the nearest earlier pane that is still there.
            let anchor = old[..<index].last { result.contains($0) }
            let position = anchor.flatMap { result.firstIndex(of: $0).map { $0 + 1 } } ?? 0
            result.insert(id, at: position)
        }
        return result
    }
}

// MARK: - Deck view

/// Planned width of the pane a view sits in while the layout animates (nil when settled).
private struct PlannedPaneWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var plannedPaneWidth: CGFloat? {
        get { self[PlannedPaneWidthKey.self] }
        set { self[PlannedPaneWidthKey.self] = newValue }
    }
}

/// Sidebar, panes and inspector: glass cards floating side by side, laid out frame by frame.
struct DeckView: View {
    let workspace: WorkspaceState
    let inspectorWidth: CGFloat

    @State private var animator = DeckAnimator()
    /// Fractions when the current gutter drag began; widths are always computed from these.
    @State private var dragStart: [CGFloat]?

    private static let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    private var target: DeckTarget {
        let panes = workspace.visiblePanes
        return DeckTarget(sidebar: workspace.showSidebar, inspector: workspace.showInspector,
                          inspectorWidth: inspectorWidth, panes: panes.map(\.id),
                          fractions: Array(workspace.paneFractions.prefix(panes.count)))
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let height = max(size.height - DeckGeometry.margin, 0)
            if let frame = animator.frame(width: size.width) {
                let geometry = frame.geometry
                ZStack(alignment: .topLeading) {
                    if geometry.sidebarPresence > 0.001 {
                        SidebarView(workspace: workspace)
                            .scrollContentBackground(.hidden)
                            .frame(width: DeckGeometry.sidebarWidth, height: height)
                            .background(Glass.card(active: false), in: Self.shape)
                            .overlay(Self.shape.strokeBorder(Glass.hairline))
                            .clipShape(Self.shape)
                            .opacity(Double(geometry.sidebarPresence))
                            .offset(x: geometry.sidebarX)
                    }
                    ForEach(frame.panes) { paneFrame in
                        if let pane = workspace.panes.first(where: { $0.id == paneFrame.id }) {
                            PaneView(workspace: workspace, pane: pane, contentWidth: paneFrame.contentWidth)
                                .environment(\.plannedPaneWidth, paneFrame.plannedWidth)
                                .frame(width: max(paneFrame.width, 0), height: height)
                                .opacity(Double(min(1, paneFrame.presence * 1.4)))
                                .offset(x: paneFrame.x)
                        }
                    }
                    if !frame.isAnimating {
                        gutters(frame, height: height, width: size.width)
                    }
                    if geometry.inspectorPresence > 0.001 {
                        InspectorView(workspace: workspace)
                            .frame(width: geometry.inspectorWidth, height: height)
                            .background(Glass.card(active: true), in: Self.shape)
                            .overlay(Self.shape.strokeBorder(Glass.hairline))
                            .clipShape(Self.shape)
                            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                            .opacity(Double(geometry.inspectorPresence))
                            .offset(x: geometry.inspectorX)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
        .onAppear { animator.retarget(target, animated: false) }
        .onChange(of: target) { old, new in
            let animated = new.differsInShape(from: old) || (dragStart == nil && new.fractions != old.fractions)
            animator.retarget(new, animated: animated)
        }
    }

    @ViewBuilder
    private func gutters(_ frame: DeckFrame, height: CGFloat, width: CGFloat) -> some View {
        let panes = frame.panes
        let area = DeckGeometry.paneArea(width: width, target: target)
        ForEach(Array(panes.dropFirst().enumerated()), id: \.element.id) { index, pane in
            let previous = panes[index]
            PaneGutter(width: PanesView.gap) { translation in
                resize(index, translation: translation, available: area)
            } onEnd: {
                dragStart = nil
            } onReset: {
                workspace.paneFractions = [1, 1, 1]
            }
            .frame(width: PanesView.gap, height: height)
            .offset(x: previous.x + previous.width)
            .id(pane.id)
        }
    }

    /// Sets pane `index` and the next one from the drag's total translation (in window coordinates).
    private func resize(_ index: Int, translation: CGFloat, available: CGFloat) {
        let start = dragStart ?? workspace.paneFractions
        if dragStart == nil { dragStart = start }
        let count = workspace.visiblePanes.count
        guard let fractions = PanesView.resized(start, divider: index, translation: translation, available: available,
                                                count: count, minimumWidth: PanesView.effectiveMinimum(available, count: count)),
              fractions != workspace.paneFractions else { return }
        workspace.paneFractions = fractions
    }
}

/// The transparent gap between two pane cards: drag to resize, double-click to make them equal.
private struct PaneGutter: View {
    let width: CGFloat
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void

    @State private var hovering = false
    @State private var dragging = false
    @State private var cursorPushed = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: width)
            .overlay {
                Capsule()
                    .fill(Color.primary.opacity(dragging ? 0.35 : (hovering ? 0.22 : 0)))
                    .frame(width: 3, height: 36)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                updateCursor()
            }
            // Global coordinates: the gutter moves while it is dragged, so local ones would feed back.
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if !dragging {
                        dragging = true
                        updateCursor()
                    }
                    onDrag(value.translation.width)
                }
                .onEnded { _ in
                    dragging = false
                    onEnd()
                    updateCursor()
                })
            .onTapGesture(count: 2, perform: onReset)
            .onDisappear {
                if cursorPushed { NSCursor.pop() }
                cursorPushed = false
            }
            .help("拖动调整宽度，双击恢复等宽")
    }

    /// Exactly one push per pop, however often hover flips while the gutter slides under the pointer.
    private func updateCursor() {
        let want = hovering || dragging
        if want, !cursorPushed {
            NSCursor.resizeLeftRight.push()
            cursorPushed = true
        } else if !want, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}
