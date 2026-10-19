import XCTest
@testable import Arbor

final class BatchRenameRuleTests: XCTestCase {
    func testReplaceKeepsExtensionByDefault() {
        var rule = BatchRenameRule()
        rule.find = "txt"
        rule.replacement = "md"
        XCTAssertEqual(rule.apply(to: ["notes txt.txt"]), ["notes md.txt"])
        rule.includeExtension = true
        XCTAssertEqual(rule.apply(to: ["notes txt.txt"]), ["notes md.md"])
    }

    func testRegexWithGroups() {
        var rule = BatchRenameRule()
        rule.useRegex = true
        rule.find = #"IMG_(\d+)"#
        rule.replacement = "照片-$1"
        XCTAssertEqual(rule.apply(to: ["IMG_0042.JPG", "other.png"]), ["照片-0042.JPG", "other.png"])
    }

    func testInvalidRegexLeavesNamesAlone() {
        var rule = BatchRenameRule()
        rule.useRegex = true
        rule.find = "("
        XCTAssertEqual(rule.apply(to: ["a.txt"]), ["a.txt"])
        XCTAssertNotNil(rule.regexError)
    }

    func testSequence() {
        var rule = BatchRenameRule()
        rule.mode = .sequence
        rule.baseName = "旅行"
        rule.startIndex = 9
        rule.digits = 3
        XCTAssertEqual(rule.apply(to: ["a.jpg", "b.jpg"]), ["旅行 009.jpg", "旅行 010.jpg"])
        rule.numberFirst = true
        rule.separator = "-"
        XCTAssertEqual(rule.apply(to: ["a.jpg"]), ["009-旅行.jpg"])
    }

    func testAddAndCase() {
        var rule = BatchRenameRule()
        rule.mode = .add
        rule.prefix = "v2_"
        rule.suffix = "_final"
        XCTAssertEqual(rule.apply(to: ["report.pdf"]), ["v2_report_final.pdf"])
        rule.mode = .letterCase
        rule.caseStyle = .upper
        XCTAssertEqual(rule.apply(to: ["report.pdf"]), ["REPORT.pdf"])
    }

    func testDotfilesAreNotSplit() {
        var rule = BatchRenameRule()
        rule.mode = .add
        rule.suffix = "-bak"
        XCTAssertEqual(rule.apply(to: [".zshrc"]), [".zshrc-bak"])
    }
}

final class FileSystemTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ArborTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func touch(_ name: String) {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
    }

    func testUniqueURLIncrementsSuffix() {
        XCTAssertEqual(FileOperations.uniqueURL(for: "a.txt", in: dir).lastPathComponent, "a.txt")
        touch("a.txt")
        XCTAssertEqual(FileOperations.uniqueURL(for: "a.txt", in: dir).lastPathComponent, "a 2.txt")
        touch("a 2.txt")
        XCTAssertEqual(FileOperations.uniqueURL(for: "a 2.txt", in: dir).lastPathComponent, "a 3.txt")
    }

    func testBatchRenameDetectsConflictsAndSwaps() throws {
        touch("a.txt"); touch("b.txt"); touch("c.txt")
        let urls = ["a.txt", "b.txt"].map { dir.appendingPathComponent($0) }

        // Swapping names inside the batch is allowed…
        XCTAssertEqual(BatchRenamer.problems(urls: urls, newNames: ["b.txt", "a.txt"]), [nil, nil])
        // …but colliding with each other or with a file outside the batch is not.
        XCTAssertEqual(BatchRenamer.problems(urls: urls, newNames: ["x.txt", "x.txt"]), [.duplicate, .duplicate])
        XCTAssertEqual(BatchRenamer.problems(urls: urls, newNames: ["c.txt", "b.txt"]), [.exists, nil])
        XCTAssertEqual(BatchRenamer.problems(urls: urls, newNames: ["bad/name", "b.txt"]), [.invalid, nil])

        FileManager.default.createFile(atPath: urls[0].path, contents: Data("A".utf8))
        _ = try BatchRenamer.perform(urls: urls, newNames: ["b.txt", "a.txt"])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("b.txt"), encoding: .utf8), "A")
    }

    func testSortFoldersFirstThenNatural() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("zeta"), withIntermediateDirectories: false)
        touch("file10.txt"); touch("file2.txt")
        let items = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: FileItem.resourceKeys)
            .map(FileItem.init(url:))
        XCTAssertEqual(SortOrder().sorted(items).map(\.name), ["zeta", "file2.txt", "file10.txt"])
        var descending = SortOrder()
        descending.ascending = false
        XCTAssertEqual(descending.sorted(items).map(\.name), ["zeta", "file10.txt", "file2.txt"])
    }
}
