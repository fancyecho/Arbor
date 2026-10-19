import AppKit

/// Tab and saved-workspace commands.
@MainActor
extension WorkspaceState {
    // MARK: Tabs

    func newTab() {
        activePane.newTab()
        focusToken += 1
    }

    /// ⌘W: closes the active tab. Pinned tabs are skipped over instead of closed; closing the
    /// last tab of a pane collapses the pane, and of the last pane closes the window.
    func closeTab() {
        let pane = activePane
        let tab = pane.activeTab
        if tab.isPinned {
            if let unpinned = pane.tabs.first(where: { !$0.isPinned }) {
                pane.activeTabID = unpinned.id
            } else {
                NSSound.beep()
            }
            return
        }
        if pane.tabs.count > 1 {
            close(tab, in: pane)
        } else if paneCount > 1 {
            rememberClosed(tab, pane: pane, index: 0)
            collapse(pane)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    func close(_ tab: TabState, in pane: PaneState) {
        guard let removed = pane.remove(tab.id) else { return }
        rememberClosed(removed.tab, pane: pane, index: removed.index)
        focusToken += 1
    }

    func closeOtherTabs(_ tab: TabState, in pane: PaneState) {
        for other in pane.tabs where other.id != tab.id && !other.isPinned {
            close(other, in: pane)
        }
        pane.activeTabID = tab.id
    }

    /// ⇧⌘T: reopens the most recently closed tab in the pane it came from (if still visible).
    func reopenClosedTab() {
        guard let closed = popRecentlyClosed() else {
            NSSound.beep()
            return
        }
        let pane = visiblePanes.first { $0.id == closed.paneID } ?? activePane
        let tab = TabState(snapshot: closed.snapshot)
        pane.insert(tab, at: closed.index)
        activate(pane)
        focusToken += 1
    }

    /// Moves a tab to another pane; a pane's only tab is copied instead, so no pane is left empty.
    /// Returns the tab as it now exists in `target`.
    @discardableResult
    func moveTab(_ tab: TabState, from source: PaneState, to target: PaneState, at index: Int? = nil) -> TabState {
        guard source.id != target.id else {
            if let index { source.move(tab.id, to: index) }
            return tab
        }
        let moved: TabState
        if source.tabs.count > 1, let removed = source.remove(tab.id) {
            moved = removed.tab
        } else {
            moved = TabState(snapshot: tab.snapshot)
        }
        target.insert(moved, at: index)
        activate(target)
        focusToken += 1
        return moved
    }

    func moveTabToOtherPane(_ tab: TabState, from pane: PaneState) {
        if otherPane == nil { setPaneCount(2) }
        let visible = visiblePanes
        guard let index = visible.firstIndex(where: { $0.id == pane.id }) else { return }
        moveTab(tab, from: pane, to: visible[(index + 1) % visible.count])
    }

    /// Hides a pane by moving it past the visible ones.
    private func collapse(_ pane: PaneState) {
        guard let index = visiblePanes.firstIndex(where: { $0.id == pane.id }) else { return }
        var reordered = panes
        reordered.remove(at: index)
        reordered.append(pane)
        replacePanes(reordered)
        setPaneCount(paneCount - 1)
        focusToken += 1
    }

    // MARK: Saved workspaces

    /// Recolors the window; also updates the saved workspace that's currently open, if any.
    func setTint(_ newTint: WorkspaceTint) {
        tint = newTint
        if let open = WorkspaceLibrary.shared.saved.first(where: { $0.id == openWorkspaceID }) {
            var snapshot = open.snapshot
            snapshot.tint = newTint.rawValue
            WorkspaceLibrary.shared.update(open.id, snapshot: snapshot)
        }
    }

    /// Saves the current layout as a workspace in `color` and makes it the window's open workspace.
    func saveWorkspace(named name: String, color: WorkspaceTint? = nil) {
        if let color { tint = color }
        let saved = WorkspaceLibrary.shared.save(name: name, snapshot: snapshot)
        openWorkspaceID = saved.id
    }

    /// Switches the window to a saved workspace: its panes, tabs and its color.
    func open(_ saved: SavedWorkspace) {
        guard saved.id != openWorkspaceID else { return }
        saveOpenWorkspaceIfNeeded()
        let latest = WorkspaceLibrary.shared.saved.first { $0.id == saved.id } ?? saved
        apply(latest.snapshot)
        openWorkspaceID = latest.id
    }

    /// With auto-save on, writes the current layout back into the open workspace.
    func saveOpenWorkspaceIfNeeded() {
        guard AppSettings.shared.autoSaveWorkspaces, let open = openWorkspace else { return }
        var current = snapshot
        current.openWorkspace = nil
        if current != open.snapshot { WorkspaceLibrary.shared.update(open.id, snapshot: current) }
    }

    func updateSavedWorkspace(_ saved: SavedWorkspace) {
        var current = snapshot
        current.tint = saved.id == openWorkspaceID ? tint.rawValue : saved.snapshot.tint
        WorkspaceLibrary.shared.update(saved.id, snapshot: current)
    }

    func deleteSavedWorkspace(_ saved: SavedWorkspace) {
        WorkspaceLibrary.shared.delete(saved.id)
        if openWorkspaceID == saved.id { openWorkspaceID = nil }
    }

    var openWorkspace: SavedWorkspace? {
        WorkspaceLibrary.shared.saved.first { $0.id == openWorkspaceID }
    }

    /// A color for a new workspace: the current one if no other workspace uses it, else the first unused.
    var suggestedNewWorkspaceTint: WorkspaceTint {
        let used = Set(WorkspaceLibrary.shared.saved.map(\.tint))
        if !used.contains(tint) { return tint }
        return WorkspaceTint.allCases.first { !used.contains($0) } ?? tint
    }
}
