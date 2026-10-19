import AppKit

/// Dual-pane comparison and folder sync.
@MainActor
extension WorkspaceState {
    var isComparing: Bool { !activeTab.compareMarks.isEmpty }

    /// Marks every item in both panes' folders and selects the differing ones on each side.
    func comparePanes(select mode: CompareSelection = .differing) {
        if otherPane == nil { setPaneCount(2) }
        guard let other = otherPane else { return }
        let here = activeTab, there = other.activeTab
        let result = FolderCompare.compare(here.items, there.items)
        here.compareMarks = result.left
        there.compareMarks = result.right
        for (tab, marks) in [(here, result.left), (there, result.right)] {
            tab.selection = Set(tab.visibleItems.filter { marks[$0.name].map(mode.includes) ?? false }.map(\.url))
        }
        let differing = result.left.values.filter { $0 != .same }.count + result.right.values.filter { $0 == .onlyHere }.count
        if differing == 0 { alertMessage = "两个文件夹的内容相同。" }
    }

    func clearComparison() {
        for pane in visiblePanes { pane.activeTab.compareMarks = [:] }
    }

    /// Runs a sync plan: copies grouped by destination folder (replacing older files), then trashes extras.
    func runSync(_ actions: [SyncAction]) {
        let copies = Dictionary(grouping: actions.filter { $0.kind != .delete }, by: \.destination)
        for (destination, group) in copies {
            FileOperationQueue.shared.copyReplacing(group.map(\.item), to: destination) { [weak self] _, error in
                self?.report(error)
            }
        }
        let deletions = actions.filter { $0.kind == .delete }.map(\.item)
        if !deletions.isEmpty {
            FileOperationQueue.shared.trash(deletions) { [weak self] error in self?.report(error) }
        }
        clearComparison()
    }
}
