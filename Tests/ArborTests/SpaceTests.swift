import XCTest
@testable import Arbor

@MainActor
final class SpaceScanTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ArborSpace-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("Movies/Trips"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("Code/node_modules/left-pad"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("Many"), withIntermediateDirectories: true)
        try Data(count: 3_000_000).write(to: dir.appendingPathComponent("Movies/Trips/beach.mov"))
        try Data(count: 500_000).write(to: dir.appendingPathComponent("Movies/poster.jpg"))
        try Data(count: 200_000).write(to: dir.appendingPathComponent("Code/node_modules/left-pad/index.js"))
        try Data(count: 10_000).write(to: dir.appendingPathComponent("Code/main.swift"))
        for index in 0..<40 {
            try Data(count: 4096 * (index + 1)).write(to: dir.appendingPathComponent("Many/file\(index).txt"))
        }
        try Data(count: 1_000_000).write(to: dir.appendingPathComponent("top.zip"))
        try fm.linkItem(at: dir.appendingPathComponent("top.zip"), to: dir.appendingPathComponent("top-link.zip"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func finishedScan() async throws -> SpaceScan {
        let scan = SpaceScan(url: dir)
        for _ in 0..<200 where scan.isScanning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(scan.isScanning)
        return scan
    }

    func testSizesAddUpAndCategoriesFollowFolders() async throws {
        let scan = try await finishedScan()
        let root = scan.root
        XCTAssertEqual(root.size, root.children.reduce(0) { $0 + $1.size } + 0, accuracy: 4096 * 8,
                       "the root is the sum of its children (plus folder entries)")
        XCTAssertEqual(root.children.first?.name, "Movies", "largest first")

        let movies = try XCTUnwrap(scan.node(for: dir.appendingPathComponent("Movies")))
        XCTAssertEqual(movies.dominantCategory, .video)
        XCTAssertGreaterThanOrEqual(movies.categories[FileCategory.image.rawValue], 500_000)

        XCTAssertGreaterThanOrEqual(root.categories[FileCategory.video.rawValue], 3_000_000, "the root adds up its folders' categories")
        XCTAssertEqual(root.categories.reduce(0, +), root.size, accuracy: 4096 * 8)
        let code = try XCTUnwrap(scan.node(for: dir.appendingPathComponent("Code")))
        XCTAssertGreaterThanOrEqual(code.categories[FileCategory.developer.rawValue], 200_000,
                                    "everything under node_modules counts as development")
    }

    func testHardLinksCountOnceAndSmallFilesAreGrouped() async throws {
        let scan = try await finishedScan()
        let zips = scan.root.children.filter { $0.name.hasSuffix(".zip") }
        XCTAssertEqual(zips.count, 2)
        XCTAssertEqual(zips.filter { $0.size > 0 }.count, 1, "the second name of a hard link adds nothing")

        let many = try XCTUnwrap(scan.node(for: dir.appendingPathComponent("Many")))
        XCTAssertEqual(many.fileCount, 40)
        let group = try XCTUnwrap(many.children.first { $0.kind == .smallFiles })
        XCTAssertEqual(group.fileCount, 40 - SpaceScanner.keptFilesPerFolder)
        XCTAssertEqual(many.children.filter { $0.kind == .file }.count, SpaceScanner.keptFilesPerFolder)
        XCTAssertEqual(many.children.filter { $0.kind == .file }.first?.name, "file39.txt", "the biggest are kept")
    }

    func testLargestFilesAndURLs() async throws {
        let scan = try await finishedScan()
        let largest = scan.root.largestFiles(limit: 3)
        XCTAssertEqual(largest.first?.name, "beach.mov")
        XCTAssertEqual(largest.count, 3)
        XCTAssertEqual(scan.url(of: largest[0]).path, dir.appendingPathComponent("Movies/Trips/beach.mov").path)
    }

    func testRemovingAndGraftingKeepTotalsRight() async throws {
        let scan = try await finishedScan()
        let before = scan.root.size
        let beach = try XCTUnwrap(scan.node(for: dir.appendingPathComponent("Movies/Trips/beach.mov")))
        let size = beach.size
        scan.remove(beach)
        XCTAssertEqual(scan.root.size, before - size)
        XCTAssertNil(scan.node(for: dir.appendingPathComponent("Movies/Trips/beach.mov")))
        XCTAssertEqual(scan.root.children.first?.name, "Many", "re-sorted after shrinking (Many: 3.3 MB of small files)")

        scan.graft(dir.appendingPathComponent("Movies/Trips/beach.mov"))
        for _ in 0..<100 where scan.node(for: dir.appendingPathComponent("Movies/Trips/beach.mov")) == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(scan.root.size, before)
    }

    func testFileChangesKeepTheTreeCurrent() async throws {
        let index = SpaceIndex.shared
        let scan = index.startScan(dir)
        for _ in 0..<200 where scan.isScanning { try await Task.sleep(nanoseconds: 20_000_000) }
        let poster = dir.appendingPathComponent("Movies/poster.jpg")
        let before = scan.root.size
        let size = try XCTUnwrap(scan.node(for: poster)).size
        let moved = dir.appendingPathComponent("Code/poster.jpg")
        try FileManager.default.moveItem(at: poster, to: moved)
        FileChanges.post(added: [moved], removed: [poster])
        XCTAssertNil(scan.node(for: poster), "gone from where it was at once")
        for _ in 0..<100 where scan.node(for: moved) == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(scan.node(for: moved)?.size, size, "and shows up where it went")
        XCTAssertEqual(scan.root.size, before)
        scan.cancel()
    }

    func testRenamingInArborUpdatesTheScan() async throws {
        let index = SpaceIndex.shared
        let scan = index.startScan(dir)
        for _ in 0..<200 where scan.isScanning { try await Task.sleep(nanoseconds: 20_000_000) }
        let workspace = WorkspaceState()
        let old = dir.appendingPathComponent("top.zip")
        XCTAssertTrue(workspace.commitRename(old, to: "renamed.zip", in: workspace.activeTab))
        let renamed = dir.appendingPathComponent("renamed.zip")
        XCTAssertNil(scan.node(for: old), "the old name is gone at once")
        for _ in 0..<100 where scan.node(for: renamed) == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(scan.node(for: renamed), "and the new name appears")
        XCTAssertEqual(index.childSizes(of: dir)?["Movies"], scan.node(for: dir.appendingPathComponent("Movies"))?.size)
        scan.cancel()
    }

    func testIndexPicksTheMostSpecificScanAndReportsFolderSizes() async throws {
        let index = SpaceIndex.shared
        let scan = index.startScan(dir)
        for _ in 0..<200 where scan.isScanning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(index.scan(covering: dir.appendingPathComponent("Code")) === scan)
        XCTAssertNotNil(index.folderSize(dir.appendingPathComponent("Movies")))
        XCTAssertNil(index.folderSize(FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere")))
        scan.cancel()
    }
}

@MainActor
final class SpacePerformanceProbe: XCTestCase {
    /// Opt-in: ARBOR_SCAN_PROBE=/some/folder swift test --filter SpacePerformanceProbe
    func testScanSpeed() async throws {
        guard let path = ProcessInfo.processInfo.environment["ARBOR_SCAN_PROBE"] else { throw XCTSkip("probe only") }
        let start = Date()
        let scan = SpaceScan(url: URL(fileURLWithPath: path))
        while scan.isScanning { try await Task.sleep(nanoseconds: 50_000_000) }
        var nodes = 0
        func count(_ node: SpaceNode) { nodes += 1; node.children.forEach(count) }
        count(scan.root)
        print("CATS", FileCategory.allCases.map { "\($0.title)=\(Format.bytes(scan.root.categories[$0.rawValue]))" }.joined(separator: " "))
        for child in scan.root.children.prefix(6) { print("CHILD", child.name, Format.bytes(child.size), child.dominantCategory.title, scan.url(of: child).path) }
        print("UNACCOUNTED", Format.bytes(scan.unaccounted), scan.volume.map { "used \(Format.bytes($0.used)) purgeable \(Format.bytes($0.purgeable))" } ?? "-")
        if let users = scan.node(for: URL(fileURLWithPath: "/Users")) { print("LOOKUP /Users ->", Format.bytes(users.size)) }
        if let home = scan.node(for: FileManager.default.homeDirectoryForCurrentUser) ?? (scan.root.name == NSUserName() ? scan.root : nil) {
            for child in home.children.prefix(8) { print("HOME", child.name, Format.bytes(child.size), child.kind) }
        }
        print("PROBE \(path): \(Format.bytes(scan.root.size)) in \(scan.root.fileCount) files, \(nodes) nodes kept, \(scan.unreadableFolders) unreadable, \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
    }
}

@MainActor
final class SunburstLayoutTests: XCTestCase {
    private func tree() -> SpaceNode {
        let empty = [Int64](repeating: 0, count: FileCategory.allCases.count)
        let big = SpaceNode(name: "big.mov", kind: .file, size: 600, fileCount: 1, category: .video)
        let tiny = (0..<50).map { SpaceNode(name: "t\($0)", kind: .file, size: 1, fileCount: 1) }
        let folder = SpaceNode(name: "Folder", kind: .folder, size: 650, fileCount: 51, children: [big] + tiny, categories: empty)
        let doc = SpaceNode(name: "doc.pdf", kind: .file, size: 350, fileCount: 1, category: .document)
        return SpaceNode(name: "root", kind: .folder, size: 1000, fileCount: 52, children: [folder, doc], categories: empty)
    }

    func testSlicesCoverTheirShareAndNestInsideTheirParent() {
        let layout = SunburstLayout.make(root: tree())
        let first = layout.segments.filter { $0.depth == 1 }
        XCTAssertEqual(first.map { $0.node?.name }, ["Folder", "doc.pdf"])
        XCTAssertEqual(first[0].end - first[0].start, 0.65, accuracy: 0.0001)
        XCTAssertEqual(first[1].end, 1, accuracy: 0.0001)
        for segment in layout.segments where segment.depth == 2 {
            XCTAssertGreaterThanOrEqual(segment.start, first[0].start - 0.0001)
            XCTAssertLessThanOrEqual(segment.end, first[0].end + 0.0001)
            XCTAssertEqual(segment.parent, first[0].id)
        }
    }

    func testTinyChildrenBecomeOneSlice() {
        let layout = SunburstLayout.make(root: tree())
        let inside = layout.segments.filter { $0.depth == 2 }
        XCTAssertEqual(inside.count, 2, "the movie, plus one slice for the 50 one-byte files")
        XCTAssertNil(inside[1].node)
        XCTAssertEqual(inside[1].end - inside[1].start, 0.05, accuracy: 0.0001)
    }

    func testExtraSliceForUnaccountedSpaceAndBranches() {
        let hidden = SpaceNode(name: "系统与其他", kind: .hidden, size: 1000, fileCount: 0)
        let layout = SunburstLayout.make(root: tree(), extra: hidden)
        XCTAssertEqual(layout.total, 2000)
        let first = layout.segments.filter { $0.depth == 1 }
        XCTAssertEqual(first.first?.node?.kind, .hidden, "largest first, so the system's share leads")
        XCTAssertEqual(layout.branchCount, 3)
        XCTAssertTrue(layout.isWithin(layout.segments.first { $0.node?.name == "big.mov" }!, first[1].id))
    }

    func testRingsLocateWhatIsUnderThePointer() {
        let rings = SunRings(size: CGSize(width: 400, height: 400), maxDepth: 5)
        XCTAssertNil(rings.locate(CGPoint(x: 200, y: 200), maxDepth: 5), "the middle is the hole")
        let top = rings.locate(CGPoint(x: 200, y: 200 - rings.inner(1) - 2), maxDepth: 5)
        XCTAssertEqual(top?.depth, 1)
        XCTAssertEqual(top?.fraction ?? -1, 0, accuracy: 0.01, "12 o'clock is where slices start")
        let right = rings.locate(CGPoint(x: 200 + rings.inner(3) + 2, y: 200), maxDepth: 5)
        XCTAssertEqual(right?.depth, 3)
        XCTAssertEqual(right?.fraction ?? -1, 0.25, accuracy: 0.01, "clockwise")
    }
}

final class FolderSizeSortTests: XCTestCase {
    func testSortingBySizeUsesScannedFolderSizes() {
        let tmp = FileManager.default.temporaryDirectory
        let small = FileItem(url: tmp), big = FileItem(url: URL(fileURLWithPath: "/Applications"))
        var order = SortOrder()
        order.key = .size
        order.ascending = false
        let sizes: [URL: Int64] = [small.url: 10, big.url: 999]
        let sorted = order.sorted([small, big], folderSize: { sizes[$0] })
        XCTAssertEqual(sorted.map(\.url), [big.url, small.url])
    }
}

@MainActor
final class ShelfSizeTests: XCTestCase {
    func testShelfMeasuresItsItems() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ArborShelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data(count: 200_000).write(to: dir.appendingPathComponent("folder/a.bin"))
        try Data(count: 100_000).write(to: dir.appendingPathComponent("b.bin"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let shelf = StashShelf.shared
        shelf.clear()
        shelf.add([dir.appendingPathComponent("folder"), dir.appendingPathComponent("b.bin")])
        shelf.hide()
        XCTAssertNil(shelf.totalSize, "unknown until measured")
        for url in shelf.items { await shelf.measure(url) }
        let total = try XCTUnwrap(shelf.totalSize)
        XCTAssertGreaterThanOrEqual(total, 300_000)
        shelf.clear()
    }
}
