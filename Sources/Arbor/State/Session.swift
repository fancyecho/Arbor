import AppKit
import Observation

// MARK: - Snapshots (Codable, path-based so they survive relaunches)

struct TabSnapshot: Codable, Equatable {
    var path: String
    var viewMode: String = ViewMode.list.rawValue
    var sortKey: String = SortKey.name.rawValue
    var ascending = true
    var pinned = false

    var url: URL { URL(fileURLWithPath: path) }
    var exists: Bool { TabState.resolvedDirectory(url) != nil }
}

struct PaneSnapshot: Codable, Equatable {
    var tabs: [TabSnapshot]
    var activeTab: Int
}

struct WorkspaceSnapshot: Codable, Equatable {
    var panes: [PaneSnapshot]
    var paneCount: Int
    var activePane: Int
    var showInspector: Bool
    /// Optional so sessions saved before workspace colors still decode.
    var tint: String? = nil
    /// The saved workspace the window was showing (its id), so relaunching keeps the link.
    var openWorkspace: String? = nil
    /// Optional so older sessions and saved workspaces still decode (they keep the defaults).
    var showSidebar: Bool? = nil
    var paneFractions: [Double]? = nil

    /// Just the shape of the window — pane count, widths, sidebar and inspector — with no tabs.
    var layoutOnly: WorkspaceSnapshot {
        WorkspaceSnapshot(panes: [], paneCount: paneCount, activePane: 0, showInspector: showInspector,
                          showSidebar: showSidebar, paneFractions: paneFractions)
    }
}

struct SavedWorkspace: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var snapshot: WorkspaceSnapshot

    var tint: WorkspaceTint { snapshot.tint.flatMap(WorkspaceTint.init(rawValue:)) ?? .indigo }

    /// "主目录 · 下载" — the active tab of each visible pane.
    var summary: String {
        snapshot.panes.prefix(snapshot.paneCount).compactMap { pane in
            pane.tabs.indices.contains(pane.activeTab) ? pane.tabs[pane.activeTab].url.lastPathComponent : nil
        }.joined(separator: " · ")
    }
}

// MARK: - Converting live state

extension TabState {
    var snapshot: TabSnapshot {
        TabSnapshot(path: url.path, viewMode: viewMode.rawValue, sortKey: sort.key.rawValue,
                    ascending: sort.ascending, pinned: isPinned)
    }

    convenience init(snapshot: TabSnapshot) {
        self.init(url: snapshot.url)
        viewMode = ViewMode(rawValue: snapshot.viewMode) ?? .list
        sort.key = SortKey(rawValue: snapshot.sortKey) ?? .name
        sort.ascending = snapshot.ascending
        isPinned = snapshot.pinned
    }
}

extension PaneState {
    var snapshot: PaneSnapshot {
        PaneSnapshot(tabs: tabs.map(\.snapshot), activeTab: tabs.firstIndex { $0.id == activeTabID } ?? 0)
    }

    /// Restores the tabs that still exist; falls back to `fallback` if none do.
    convenience init(snapshot: PaneSnapshot?, fallback: URL) {
        let valid = (snapshot?.tabs ?? []).enumerated().filter { $0.element.exists }
        guard !valid.isEmpty else {
            self.init(url: fallback)
            return
        }
        let tabs = valid.map { TabState(snapshot: $0.element) }
        let active = valid.firstIndex { $0.offset == snapshot?.activeTab } ?? 0
        self.init(tabs: tabs, activeIndex: active)
    }
}

extension WorkspaceState {
    var snapshot: WorkspaceSnapshot {
        WorkspaceSnapshot(panes: panes.map(\.snapshot), paneCount: paneCount,
                          activePane: panes.firstIndex { $0.id == activePaneID } ?? 0,
                          showInspector: showInspector, tint: tint.rawValue,
                          openWorkspace: openWorkspaceID?.uuidString, showSidebar: showSidebar,
                          paneFractions: paneFractions.map(Double.init))
    }
}

// MARK: - Library of saved workspaces + last session

@MainActor @Observable
final class WorkspaceLibrary {
    static let shared = WorkspaceLibrary()

    private(set) var saved: [SavedWorkspace] = []
    private let defaults = AppDefaults.store

    private init() {
        if let data = defaults.data(forKey: "workspaces"),
           let decoded = try? JSONDecoder().decode([SavedWorkspace].self, from: data) {
            saved = decoded
        }
    }

    var lastSession: WorkspaceSnapshot? {
        get { defaults.data(forKey: "session").flatMap { try? JSONDecoder().decode(WorkspaceSnapshot.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "session") }
    }

    @discardableResult
    func save(name: String, snapshot: WorkspaceSnapshot) -> SavedWorkspace {
        let entry = SavedWorkspace(name: name, snapshot: snapshot)
        saved.append(entry)
        persist()
        return entry
    }

    func update(_ id: UUID, snapshot: WorkspaceSnapshot) {
        guard let index = saved.firstIndex(where: { $0.id == id }) else { return }
        saved[index].snapshot = snapshot
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = saved.firstIndex(where: { $0.id == id }) else { return }
        saved[index].name = name
        persist()
    }

    func delete(_ id: UUID) {
        saved.removeAll { $0.id == id }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        saved.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(saved), forKey: "workspaces")
    }
}

// MARK: - Window registry: restores the last session and saves it again

@MainActor
final class WorkspaceRegistry {
    static let shared = WorkspaceRegistry()

    private struct Weak { weak var workspace: WorkspaceState? }
    private var alive: [Weak] = []
    private weak var lastActive: WorkspaceState?
    private var lastSaved: WorkspaceSnapshot?
    /// Workspaces whose window is on screen (a closed window's state can outlive it for a while).
    private var onScreen: Set<ObjectIdentifier> = []
    /// Something to show once the next window opens (Finder service, Dock drop, menu bar).
    var pendingURL: URL?

    private init() {
        let center = NotificationCenter.default
        for name in [NSApplication.willResignActiveNotification, NSApplication.willTerminateNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { WorkspaceRegistry.shared.persist() }
            }
        }
        // Cheap safety net against crashes: save every few seconds if something changed.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { WorkspaceRegistry.shared.persist() }
        }
    }

    /// With no other window open — at launch, or after closing them all — the new window comes back as
    /// the last one was. With windows open (⌘N) it takes their layout but starts from the home folder.
    func makeWorkspace() -> WorkspaceState {
        let workspace = WorkspaceState(snapshot: Self.snapshotForNewWindow(
            last: WorkspaceLibrary.shared.lastSession,
            focused: onScreen.isEmpty ? nil : current?.snapshot,
            paneSetting: AppSettings.shared.newWindowPaneCount))
        if let url = pendingURL {
            pendingURL = nil
            if let folder = TabState.resolvedDirectory(url) {
                workspace.activePane.newTab(url: folder)
            } else {
                workspace.activePane.newTab(url: url.deletingLastPathComponent()).selection = [url]
            }
        }
        alive.append(Weak(workspace: workspace))
        lastActive = workspace
        return workspace
    }

    /// The workspace of the most recently focused window, for app-level panels such as the shelf.
    var current: WorkspaceState? {
        alive.removeAll { $0.workspace == nil }
        return lastActive ?? alive.last?.workspace
    }

    /// Every open window's workspace.
    var workspaces: [WorkspaceState] {
        alive.removeAll { $0.workspace == nil }
        return alive.compactMap(\.workspace)
    }

    func markActive(_ workspace: WorkspaceState) {
        lastActive = workspace
    }

    func windowAppeared(_ workspace: WorkspaceState) {
        onScreen.insert(ObjectIdentifier(workspace))
    }

    func windowClosed(_ workspace: WorkspaceState) {
        persist(workspace)
        onScreen.remove(ObjectIdentifier(workspace))
        if lastActive === workspace {
            lastActive = alive.compactMap(\.workspace).last { onScreen.contains(ObjectIdentifier($0)) }
        }
    }

    /// `last` is the saved session, `focused` the frontmost open window (nil when none is open).
    /// `paneSetting` 1–3 fixes the pane count; 0 keeps whatever the source had.
    static func snapshotForNewWindow(last: WorkspaceSnapshot?, focused: WorkspaceSnapshot?,
                                     paneSetting: Int) -> WorkspaceSnapshot? {
        let source = focused?.layoutOnly ?? last
        guard (1...WorkspaceState.maxPanes).contains(paneSetting) else { return source }
        var snapshot = source ?? WorkspaceSnapshot(panes: [], paneCount: paneSetting, activePane: 0, showInspector: false)
        snapshot.paneCount = paneSetting
        snapshot.activePane = min(snapshot.activePane, paneSetting - 1)
        return snapshot
    }

    /// Saves the most recently active window's layout as the session to restore.
    func persist(_ workspace: WorkspaceState? = nil) {
        alive.removeAll { $0.workspace == nil }
        guard let source = workspace ?? lastActive ?? alive.last?.workspace else { return }
        source.saveOpenWorkspaceIfNeeded()
        let snapshot = source.snapshot
        guard snapshot != lastSaved else { return }
        lastSaved = snapshot
        WorkspaceLibrary.shared.lastSession = snapshot
    }
}
