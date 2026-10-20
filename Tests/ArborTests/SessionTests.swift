import XCTest
@testable import Arbor

@MainActor
final class SessionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ArborSession-\(UUID().uuidString)")
        for name in ["a", "b", "c"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

    func testSnapshotRoundTripsThroughJSON() throws {
        let snapshot = WorkspaceSnapshot(
            panes: [PaneSnapshot(tabs: [TabSnapshot(path: path("a"), viewMode: "grid", sortKey: "size", ascending: false, pinned: true),
                                        TabSnapshot(path: path("b"))], activeTab: 1)],
            paneCount: 1, activePane: 0, showInspector: true)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)

        let workspace = WorkspaceState(snapshot: decoded)
        XCTAssertEqual(workspace.paneCount, 1)
        XCTAssertTrue(workspace.showInspector)
        let pane = workspace.panes[0]
        XCTAssertEqual(pane.tabs.count, 2)
        XCTAssertEqual(pane.activeTab.url.path, path("b"))
        XCTAssertTrue(pane.tabs[0].isPinned)
        XCTAssertEqual(pane.tabs[0].viewMode, .grid)
        XCTAssertEqual(pane.tabs[0].sort.key, .size)
        // And back again.
        XCTAssertEqual(workspace.snapshot.panes[0], snapshot.panes[0])
    }

    func testMissingFoldersAreSkippedOnRestore() {
        let snapshot = PaneSnapshot(tabs: [TabSnapshot(path: path("gone")), TabSnapshot(path: path("c"))], activeTab: 0)
        let pane = PaneState(snapshot: snapshot, fallback: dir)
        XCTAssertEqual(pane.tabs.map { $0.url.lastPathComponent }, ["c"])

        let empty = PaneState(snapshot: PaneSnapshot(tabs: [TabSnapshot(path: path("gone"))], activeTab: 0), fallback: dir)
        XCTAssertEqual(empty.activeTab.url.path, dir.path)
    }

    func testPinnedTabsStayFirst() {
        let pane = PaneState(url: URL(fileURLWithPath: path("a")))
        let b = pane.newTab(url: URL(fileURLWithPath: path("b")))
        let c = pane.newTab(url: URL(fileURLWithPath: path("c")))
        pane.togglePin(c.id)
        XCTAssertEqual(pane.tabs.first?.id, c.id)
        pane.move(c.id, to: 2)
        XCTAssertEqual(pane.tabs.first?.id, c.id, "a pinned tab can't be dragged behind unpinned ones")
        pane.move(b.id, to: 0)
        XCTAssertEqual(pane.tabs.map(\.id).prefix(2), [c.id, b.id])
    }

    func testCloseAndReopenTab() {
        let workspace = WorkspaceState(snapshot: WorkspaceSnapshot(
            panes: [PaneSnapshot(tabs: [TabSnapshot(path: path("a")), TabSnapshot(path: path("b"))], activeTab: 1)],
            paneCount: 1, activePane: 0, showInspector: false))
        workspace.closeTab()
        XCTAssertEqual(workspace.activePane.tabs.map { $0.url.lastPathComponent }, ["a"])
        workspace.reopenClosedTab()
        XCTAssertEqual(workspace.activePane.tabs.map { $0.url.lastPathComponent }, ["a", "b"])
        XCTAssertEqual(workspace.activeTab.url.lastPathComponent, "b")
    }

    func testMovingOnlyTabCopiesIt() {
        let workspace = WorkspaceState(snapshot: nil)
        workspace.setPaneCount(2)
        let left = workspace.visiblePanes[0], right = workspace.visiblePanes[1]
        let before = right.tabs.count
        workspace.moveTabToOtherPane(left.activeTab, from: left)
        XCTAssertEqual(left.tabs.count, 1, "a pane never ends up empty")
        XCTAssertEqual(right.tabs.count, before + 1)
    }

    func testFolderMemoryRestoresSelection() {
        let tab = TabState(url: dir)
        let target = dir.appendingPathComponent("b")
        FolderMemory.shared.remember(dir, selection: [target], anchor: target)
        let recalled = FolderMemory.shared.recall(dir)
        XCTAssertEqual(recalled?.selection.map(\.path), [target.path])
        XCTAssertEqual(recalled?.anchor?.path, target.path)
        _ = tab
    }
}

@MainActor
final class RenameConflictTests: XCTestCase {
    func testFailedRenameKeepsTheNameAndResumesNaming() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ArborRename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("taken"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("未命名文件夹"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = WorkspaceState()
        let tab = workspace.activeTab
        let folder = dir.appendingPathComponent("未命名文件夹")
        XCTAssertFalse(workspace.commitRename(folder, to: "taken", in: tab), "the name is in use")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "nothing was renamed")
        XCTAssertNotNil(workspace.alertMessage)
        XCTAssertTrue(workspace.renameAfterAlert?.url == folder, "naming picks up again after the alert")
        XCTAssertTrue(workspace.commitRename(folder, to: "free", in: tab))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("free").path))
    }
}
