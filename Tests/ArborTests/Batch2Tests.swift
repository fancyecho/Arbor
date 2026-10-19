import XCTest
@testable import Arbor

final class PathAndCommandTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/Users/me/My File (1).txt")

    func testPathStyles() {
        XCTAssertEqual(PathFormatter.format(url, .path), "/Users/me/My File (1).txt")
        XCTAssertEqual(PathFormatter.format(url, .quoted), "\"/Users/me/My File (1).txt\"")
        XCTAssertEqual(PathFormatter.format(url, .escaped), "/Users/me/My\\ File\\ \\(1\\).txt")
        XCTAssertEqual(PathFormatter.format(url, .name), "My File (1).txt")
        XCTAssertEqual(PathFormatter.format(url, .stem), "My File (1)")
        XCTAssertEqual(PathFormatter.format(url, .parent), "/Users/me")
        XCTAssertEqual(PathFormatter.format(url, .fileURL), "file:///Users/me/My%20File%20(1).txt")
        let two = [url, URL(fileURLWithPath: "/tmp/b")]
        XCTAssertEqual(PathFormatter.format(two, .escaped), "/Users/me/My\\ File\\ \\(1\\).txt /tmp/b")
        XCTAssertEqual(PathFormatter.format(two, .name), "My File (1).txt\nb")
    }

    func testPlaceholderExpansionQuotesSafely() {
        let files = [URL(fileURLWithPath: "/a/it's.txt"), URL(fileURLWithPath: "/a/b c")]
        let script = CommandRunner.expand("cp $FILES $DIR; echo $FILE $NAMES", files: files, directory: URL(fileURLWithPath: "/d"))
        XCTAssertEqual(script, "cp '/a/it'\\''s.txt' '/a/b c' '/d'; echo '/a/it'\\''s.txt' 'it'\\''s.txt' 'b c'")
    }

    func testCustomCommandRunsInFolder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ArborCmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let command = CustomCommand(name: "pwd", script: "basename \"$(pwd)\"; echo $NAMES", mode: .output)
        let output: CommandOutput = await withCheckedContinuation { continuation in
            Task { @MainActor in
                CommandRunner.run(command, files: [dir.appendingPathComponent("x y")], directory: dir) {
                    continuation.resume(returning: $0)
                }
            }
        }
        XCTAssertTrue(output.succeeded)
        XCTAssertEqual(output.text, "\(dir.lastPathComponent)\nx y")
    }
}

final class MatchingTests: XCTestCase {
    func testFuzzyMatchesPinyinAndInitials() {
        XCTAssertNotNil(Fuzzy.score("新建", "新建文件夹"))
        XCTAssertNotNil(Fuzzy.score("xinjian", "新建文件夹"))
        XCTAssertNotNil(Fuzzy.score("xjwjj", "新建文件夹"))
        XCTAssertNil(Fuzzy.score("zzz", "新建文件夹"))
        XCTAssertGreaterThan(Fuzzy.score("down", "Downloads")!, Fuzzy.score("dwn", "Downloads")!)
    }

    func testPathScoreIsZoxideLike() {
        let path = "/Users/me/Documents/project/Arbor"
        XCTAssertNotNil(Fuzzy.pathScore("arb", path))
        XCTAssertNotNil(Fuzzy.pathScore("pro arb", path))
        XCTAssertNil(Fuzzy.pathScore("arb pro", path), "tokens must appear in order")
        XCTAssertNil(Fuzzy.pathScore("project", path), "last token must match the folder itself")
    }

    func testNameMatcher() {
        XCTAssertTrue(NameMatcher.matches("Résumé.pdf", "resume"))
        XCTAssertTrue(NameMatcher.matches("会议记录.docx", "huiyi"))
        XCTAssertTrue(NameMatcher.matches("会议记录.docx", "hyjl"))
        XCTAssertFalse(NameMatcher.matches("report.pdf", "huiyi"))
    }
}

final class FolderLogicTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ArborFolders-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func file(_ path: String, _ text: String = "x", age: TimeInterval = 0) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
    }

    private func items(_ dir: String) throws -> [FileItem] {
        try fm.contentsOfDirectory(at: root.appendingPathComponent(dir), includingPropertiesForKeys: FileItem.resourceKeys)
            .map(FileItem.init(url:))
    }

    func testCompareListings() throws {
        try file("L/only-left.txt")
        try file("L/new.txt", age: 0)
        try file("R/new.txt", age: 3600)
        try file("L/same.txt", "abc", age: 100)
        try file("R/same.txt", "abc", age: 100)
        try file("L/diff.txt", "abc", age: 100)
        try file("R/diff.txt", "abcdef", age: 100)
        try file("R/only-right.txt")
        let (left, right) = FolderCompare.compare(try items("L"), try items("R"))
        XCTAssertEqual(left["only-left.txt"], .onlyHere)
        XCTAssertEqual(left["new.txt"], .newer)
        XCTAssertEqual(right["new.txt"], .older)
        XCTAssertEqual(left["same.txt"], .same)
        XCTAssertEqual(left["diff.txt"], .different)
        XCTAssertEqual(right["only-right.txt"], .onlyHere)
    }

    func testSyncPlanOneWayAndMirror() throws {
        try file("A/add.txt")
        try file("A/sub/deep.txt")
        try file("A/newer.txt", "v2", age: 0)
        try file("B/newer.txt", "v1", age: 3600)
        try file("A/older.txt", "v1", age: 3600)
        try file("B/older.txt", "v2", age: 0)
        try file("B/sub/extra.txt")
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")

        let plan = SyncPlanner.plan(a, b, options: SyncOptions())
        XCTAssertEqual(Set(plan.map { "\($0.kind.rawValue) \($0.relativePath)" }),
                       ["add add.txt", "add sub/deep.txt", "update newer.txt"],
                       "never overwrites a newer target file, never deletes without mirror")

        var mirror = SyncOptions()
        mirror.deleteExtras = true
        XCTAssertTrue(SyncPlanner.plan(a, b, options: mirror).contains { $0.kind == .delete && $0.relativePath == "sub/extra.txt" })

        var both = SyncOptions()
        both.direction = .both
        XCTAssertEqual(Set(SyncPlanner.plan(a, b, options: both).map { "\($0.kind.rawValue) \($0.relativePath)" }),
                       ["add add.txt", "add sub/deep.txt", "update newer.txt", "update older.txt", "add sub/extra.txt"])
    }

    func testRecursiveSearchFindsNestedMatches() throws {
        try file("tree/a/报告-final.pdf")
        try file("tree/b/c/report.txt")
        try file("tree/b/.hidden-report")
        let done = expectation(description: "search")
        let box = Box()
        RecursiveSearch.run(root: root.appendingPathComponent("tree"), query: "report", includeHidden: false, cancel: CancelFlag(),
                            onBatch: { box.add($0) }, onDone: { _ in done.fulfill() })
        wait(for: [done], timeout: 5)
        XCTAssertEqual(box.names, ["report.txt"])

        let pinyin = expectation(description: "pinyin")
        let box2 = Box()
        RecursiveSearch.run(root: root.appendingPathComponent("tree"), query: "baogao", includeHidden: false, cancel: CancelFlag(),
                            onBatch: { box2.add($0) }, onDone: { _ in pinyin.fulfill() })
        wait(for: [pinyin], timeout: 5)
        XCTAssertEqual(box2.names, ["报告-final.pdf"])
    }

    func testSelectionCondition() throws {
        try file("s/photo1.jpg", age: 86_400 * 40)
        try file("s/photo2.JPG")
        try file("s/notes.txt")
        try fm.createDirectory(at: root.appendingPathComponent("s/folder"), withIntermediateDirectories: true)
        let all = try items("s")
        var condition = SelectionCondition()
        condition.pattern = "*.jpg"
        XCTAssertEqual(Set(all.filter { condition.matches($0) }.map(\.name)), ["photo1.jpg", "photo2.JPG"])
        condition.age = .week
        XCTAssertEqual(all.filter { condition.matches($0) }.map(\.name), ["photo2.JPG"])
        condition = SelectionCondition()
        condition.kind = .folders
        XCTAssertEqual(all.filter { condition.matches($0) }.map(\.name), ["folder"])
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [FileItem] = []
        func add(_ batch: [FileItem]) { lock.withLock { items += batch } }
        var names: [String] { lock.withLock { items.map(\.name).sorted() } }
    }
}
