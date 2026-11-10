import XCTest
@testable import Arbor

/// Date-added sorting, groups and folders expanded in the list view.
@MainActor
final class ListBasicsTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ArborList-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("docs/inner"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: dir.appendingPathComponent("docs/readme.md"))
        try Data("b".utf8).write(to: dir.appendingPathComponent("docs/inner/deep.txt"))
        try Data(count: 2_000_000).write(to: dir.appendingPathComponent("big.bin"))
        try Data("c".utf8).write(to: dir.appendingPathComponent("note.txt"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func waitFor(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testDateGroupsFollowFinder() {
        let now = Date()
        let calendar = Calendar.current
        XCTAssertEqual(Grouping.dateBucket(now, now: now).0, "date:today")
        XCTAssertEqual(Grouping.dateBucket(calendar.date(byAdding: .day, value: -1, to: now), now: now).0, "date:yesterday")
        XCTAssertEqual(Grouping.dateBucket(calendar.date(byAdding: .day, value: -4, to: now), now: now).0, "date:7")
        XCTAssertEqual(Grouping.dateBucket(calendar.date(byAdding: .day, value: -20, to: now), now: now).0, "date:30")
        let old = calendar.date(from: DateComponents(year: 2019, month: 5, day: 1))
        XCTAssertEqual(Grouping.dateBucket(old, now: now).1, "2019")
        XCTAssertEqual(Grouping.dateBucket(nil, now: now).0, "date:none")
    }

    func testGroupsKeepSortOrderAndPutFoldersAndBigFilesFirst() {
        let items = ["docs", "big.bin", "note.txt"].map { FileItem(url: dir.appendingPathComponent($0)) }
        let bySize = Grouping.groups(items, by: .size)
        XCTAssertEqual(bySize.map(\.id), ["size:1m", "size:small", "size:folder"])
        let byKind = Grouping.groups(items, by: .kind)
        XCTAssertEqual(byKind.first?.id, "kind:folder")
        XCTAssertEqual(byKind.flatMap(\.items).count, 3, "every item lands in exactly one group")
        XCTAssertEqual(Grouping.groups(items, by: .none).map(\.items), [items])
    }

    func testSortingByDateAdded() throws {
        let items = ["note.txt", "big.bin", "docs"].map { FileItem(url: dir.appendingPathComponent($0)) }
        XCTAssertTrue(items.allSatisfy { $0.added != nil }, "APFS records when an item was added")
        var order = SortOrder(key: .added, ascending: true, foldersFirst: false)
        let ascending = order.sorted(items)
        order.ascending = false
        XCTAssertEqual(order.sorted(items).map(\.url), ascending.reversed().map(\.url))
    }

    func testExpandingAFolderShowsItsContentsInTheRows() {
        let tab = TabState(url: dir)
        waitFor(!tab.items.isEmpty)
        let docs = dir.appendingPathComponent("docs")
        tab.setExpanded(docs, true)
        waitFor(tab.children(of: docs) != nil)
        let names = tab.visibleRows.map(\.name)
        XCTAssertEqual(names, ["docs", "inner", "readme.md", "big.bin", "note.txt"], "children sit right under their folder")

        // Selecting a child and collapsing the folder drops it from the selection, like Finder.
        let readme = try? XCTUnwrap(tab.visibleRows.first { $0.name == "readme.md" })
        tab.selection = Set([readme?.url].compactMap { $0 })
        XCTAssertEqual(tab.selectedItems.map(\.name), ["readme.md"])
        tab.setExpanded(docs, false)
        XCTAssertTrue(tab.selection.isEmpty)
        XCTAssertEqual(tab.visibleRows.map(\.name), ["docs", "big.bin", "note.txt"])
    }

    func testOptionExpandOpensEverythingInside() {
        let tab = TabState(url: dir)
        waitFor(!tab.items.isEmpty)
        let docs = dir.appendingPathComponent("docs")
        tab.setExpanded(docs, true, all: true)
        waitFor(tab.children(of: docs.appendingPathComponent("inner")) != nil)
        XCTAssertTrue(tab.visibleRows.map(\.name).contains("deep.txt"))
        tab.setExpanded(docs, false)
        XCTAssertFalse(tab.isExpanded(docs.appendingPathComponent("inner")), "collapsing folds everything inside")
    }

    func testExpandedFoldersComeBackWithTheFolder() {
        let tab = TabState(url: dir)
        waitFor(!tab.items.isEmpty)
        let docs = dir.appendingPathComponent("docs")
        tab.setExpanded(docs, true)
        tab.navigate(to: docs)
        XCTAssertTrue(tab.expandedFolders.isEmpty, "a new folder starts collapsed")
        tab.goBack()
        XCTAssertTrue(tab.isExpanded(docs), "going back reopens what was expanded")
    }

    func testGroupsShowInTheListAndOrderTheRows() {
        let tab = TabState(url: dir)
        waitFor(!tab.items.isEmpty)
        tab.groupBy = .size
        XCTAssertTrue(tab.showsGroups)
        XCTAssertEqual(tab.visibleRows.map(\.name), ["big.bin", "note.txt", "docs"])
        tab.viewMode = .columns
        XCTAssertFalse(tab.showsGroups, "the column view doesn't group")
    }

    func testSnapshotKeepsGrouping() {
        let tab = TabState(url: dir)
        tab.groupBy = .modified
        let restored = TabState(snapshot: tab.snapshot)
        XCTAssertEqual(restored.groupBy, .modified)
        let old = try? JSONDecoder().decode(TabSnapshot.self, from: Data(#"{"path":"/tmp","viewMode":"list","sortKey":"name","ascending":true,"pinned":false}"#.utf8))
        XCTAssertNotNil(old, "sessions saved before groups still load")
    }

    func testSpringLoaderFiresWhileADragIsTracking() {
        var opened: URL?
        let loader = SpringLoader { opened = $0 }
        let folder = dir.appendingPathComponent("docs")
        loader.hover(folder)
        loader.hover(folder) // staying over the same folder keeps the countdown going
        // A drag runs the event-tracking mode, where timers in the default mode never fire.
        let deadline = Date().addingTimeInterval(SpringLoader.delay + 1)
        while opened == nil, Date() < deadline { RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(opened?.path, folder.path)

        opened = nil
        loader.hover(folder)
        loader.leave(dir.appendingPathComponent("other")) // leaving another folder doesn't stop it
        loader.leave(folder)
        RunLoop.main.run(until: Date().addingTimeInterval(SpringLoader.delay + 0.2))
        XCTAssertNil(opened, "moving off the folder cancels")
    }
}
