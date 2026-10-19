import Foundation
import Observation

/// A column of the workspace with its own set of tabs. Pinned tabs always come first.
@MainActor @Observable
final class PaneState: Identifiable {
    let id = UUID()
    private(set) var tabs: [TabState]
    var activeTabID: UUID

    init(url: URL) {
        let tab = TabState(url: url)
        tabs = [tab]
        activeTabID = tab.id
    }

    init(tabs: [TabState], activeIndex: Int) {
        precondition(!tabs.isEmpty)
        self.tabs = tabs
        activeTabID = tabs[min(max(activeIndex, 0), tabs.count - 1)].id
        normalizeOrder()
    }

    var activeTab: TabState {
        tabs.first { $0.id == activeTabID } ?? tabs[0]
    }

    func index(of id: UUID) -> Int? { tabs.firstIndex { $0.id == id } }

    @discardableResult
    func newTab(url: URL? = nil, activate: Bool = true) -> TabState {
        let source = activeTab
        let tab = TabState(url: url ?? source.url)
        tab.viewMode = source.viewMode
        tab.sort = source.sort
        insert(tab, at: (index(of: activeTabID) ?? tabs.count - 1) + 1, activate: activate)
        return tab
    }

    /// Adds an existing tab (e.g. one dragged from another pane).
    func insert(_ tab: TabState, at position: Int? = nil, activate: Bool = true) {
        let target = min(max(position ?? tabs.count, 0), tabs.count)
        tabs.insert(tab, at: target)
        normalizeOrder()
        if activate { activeTabID = tab.id }
    }

    /// Removes a tab and returns it with its former index. The last tab is never removed.
    @discardableResult
    func remove(_ id: UUID) -> (tab: TabState, index: Int)? {
        guard tabs.count > 1, let position = index(of: id) else { return nil }
        let tab = tabs.remove(at: position)
        if activeTabID == id {
            activeTabID = tabs[min(position, tabs.count - 1)].id
        }
        return (tab, position)
    }

    func duplicate(_ id: UUID) {
        guard let position = index(of: id) else { return }
        let source = tabs[position]
        let copy = TabState(snapshot: source.snapshot)
        copy.isPinned = false
        insert(copy, at: position + 1)
    }

    func togglePin(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.isPinned.toggle()
        normalizeOrder()
    }

    func move(_ id: UUID, to destination: Int) {
        guard let position = index(of: id) else { return }
        let tab = tabs.remove(at: position)
        tabs.insert(tab, at: min(max(destination, 0), tabs.count))
        normalizeOrder()
    }

    func selectNextTab(_ step: Int) {
        guard let position = index(of: activeTabID) else { return }
        activeTabID = tabs[(position + step + tabs.count) % tabs.count].id
    }

    func selectTab(at position: Int) {
        guard tabs.indices.contains(position) else { return }
        activeTabID = tabs[position].id
    }

    /// Pinned tabs first, otherwise keep the user's order.
    private func normalizeOrder() {
        let pinned = tabs.filter(\.isPinned)
        let unpinned = tabs.filter { !$0.isPinned }
        let ordered = pinned + unpinned
        if ordered.map(\.id) != tabs.map(\.id) { tabs = ordered }
    }
}
