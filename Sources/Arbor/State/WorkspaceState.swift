import AppKit
import Observation
import SwiftUI

/// Everything shown in one window: up to three panes, the inspector, sheets and alerts.
@MainActor @Observable
final class WorkspaceState {
    static let maxPanes = 3

    private(set) var panes: [PaneState]
    private(set) var paneCount: Int
    var activePaneID: UUID
    var showInspector = false
    var showSidebar = true
    /// The window's color; saved with the session and with named workspaces.
    var tint: WorkspaceTint = .indigo
    /// Relative widths of the visible panes (resized by dragging the gap between cards).
    var paneFractions: [CGFloat] = [1, 1, 1]
    /// The saved workspace this window was last switched to (its color follows recoloring).
    var openWorkspaceID: UUID?

    /// Present the batch rename sheet for these files.
    var batchRenameTargets: [URL]?
    var alertMessage: String?
    /// ⌘K command palette.
    var showPalette = false
    var showSelectByCondition = false
    var showSync = false
    var showConnectServer = false
    /// Bumped to move keyboard focus into the toolbar search field.
    var searchFocusToken = 0
    /// Output of a custom command run in "show output" mode.
    var commandOutput: CommandOutput?
    /// Present the "name this workspace" sheet.
    var workspaceNameRequest: WorkspaceNameRequest?

    /// Bumped to ask the active pane's file view to take keyboard focus.
    var focusToken = 0

    /// Most recent last; reopened with ⇧⌘T.
    private(set) var recentlyClosed: [ClosedTab] = []

    struct ClosedTab {
        let snapshot: TabSnapshot
        let paneID: UUID
        let index: Int
    }

    init(snapshot: WorkspaceSnapshot? = nil) {
        let initial = Self.makePanes(snapshot)
        panes = initial
        paneCount = min(max(snapshot?.paneCount ?? 2, 1), Self.maxPanes)
        activePaneID = initial[min(max(snapshot?.activePane ?? 0, 0), initial.count - 1)].id
        showInspector = snapshot?.showInspector ?? false
        showSidebar = snapshot?.showSidebar ?? true
        if let fractions = Self.validFractions(snapshot?.paneFractions) { paneFractions = fractions }
        tint = snapshot?.tint.flatMap(WorkspaceTint.init(rawValue:)) ?? .indigo
        openWorkspaceID = snapshot?.openWorkspace.flatMap(UUID.init(uuidString:))
    }

    private static func validFractions(_ values: [Double]?) -> [CGFloat]? {
        guard let values, values.count == maxPanes, values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        return values.map { CGFloat($0) }
    }

    private static func makePanes(_ snapshot: WorkspaceSnapshot?) -> [PaneState] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let fallbacks = [
            home,
            fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home,
            fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? home,
        ]
        return (0..<maxPanes).map { index in
            let pane = snapshot.flatMap { $0.panes.indices.contains(index) ? $0.panes[index] : nil }
            return PaneState(snapshot: pane, fallback: fallbacks[index])
        }
    }

    /// Replaces the whole layout, e.g. when switching to a saved workspace.
    func apply(_ snapshot: WorkspaceSnapshot) {
        let rebuilt = Self.makePanes(snapshot)
        panes = rebuilt
        paneCount = min(max(snapshot.paneCount, 1), Self.maxPanes)
        activePaneID = rebuilt[min(max(snapshot.activePane, 0), rebuilt.count - 1)].id
        showInspector = snapshot.showInspector
        if let sidebar = snapshot.showSidebar { showSidebar = sidebar }
        paneFractions = Self.validFractions(snapshot.paneFractions) ?? [1, 1, 1]
        if let tint = snapshot.tint.flatMap(WorkspaceTint.init(rawValue:)) { self.tint = tint }
        focusToken += 1
    }

    func rememberClosed(_ tab: TabState, pane: PaneState, index: Int) {
        recentlyClosed.append(ClosedTab(snapshot: tab.snapshot, paneID: pane.id, index: index))
        if recentlyClosed.count > 20 { recentlyClosed.removeFirst() }
    }

    func popRecentlyClosed() -> ClosedTab? { recentlyClosed.popLast() }

    var visiblePanes: [PaneState] { Array(panes.prefix(paneCount)) }

    var activePane: PaneState { panes.first { $0.id == activePaneID } ?? panes[0] }

    var activeTab: TabState { activePane.activeTab }

    /// The pane to the right of the active one (wrapping), used for "copy to other pane".
    var otherPane: PaneState? {
        let visible = visiblePanes
        guard visible.count > 1, let index = visible.firstIndex(where: { $0.id == activePaneID }) else { return nil }
        return visible[(index + 1) % visible.count]
    }

    func setPaneCount(_ count: Int) {
        paneCount = min(max(count, 1), Self.maxPanes)
        if !visiblePanes.contains(where: { $0.id == activePaneID }) { activePaneID = panes[0].id }
    }

    /// Reorders panes (same set of panes, e.g. moving a closed pane to the hidden end).
    func replacePanes(_ reordered: [PaneState]) {
        guard Set(reordered.map(\.id)) == Set(panes.map(\.id)) else { return }
        panes = reordered
    }

    func activate(_ pane: PaneState) {
        if activePaneID != pane.id { activePaneID = pane.id }
    }

    func focusNextPane(_ step: Int = 1) {
        let visible = visiblePanes
        guard visible.count > 1, let index = visible.firstIndex(where: { $0.id == activePaneID }) else { return }
        activePaneID = visible[(index + step + visible.count) % visible.count].id
        focusToken += 1
    }

    func report(_ error: Error?) {
        guard let error else { return }
        alertMessage = error.localizedDescription
    }
}

enum WorkspaceNameRequest: Identifiable {
    case save
    case rename(SavedWorkspace)

    var id: String {
        switch self {
        case .save: "save"
        case .rename(let saved): saved.id.uuidString
        }
    }
}

// MARK: - Focused value so menu commands reach the key window's workspace

struct WorkspaceFocusKey: FocusedValueKey {
    typealias Value = WorkspaceState
}

extension FocusedValues {
    var workspace: WorkspaceState? {
        get { self[WorkspaceFocusKey.self] }
        set { self[WorkspaceFocusKey.self] = newValue }
    }
}
