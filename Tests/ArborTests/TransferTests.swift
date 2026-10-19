import XCTest
@testable import Arbor

/// Exercises the copy/move engine and undo steps on a temp directory.
/// Nothing here trashes files, so the user's real Trash is never touched.
final class TransferTests: XCTestCase {
    private var root: URL!
    private var src: URL!
    private var dst: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ArborTransfer-\(UUID().uuidString)")
        src = root.appendingPathComponent("src")
        dst = root.appendingPathComponent("dst")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ text: String, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private final class Recorder: @unchecked Sendable {
        var asked: [ConflictInfo] = []
        var last = TransferProgress()
    }

    private func run(_ kind: TransferKind, _ sources: [URL], to destination: URL, choice: ConflictChoice = .stop,
                     applyToAll: Bool = false, cancel: Bool = false, recorder: Recorder = Recorder()) async -> TransferResult {
        let flag = CancelFlag()
        if cancel { flag.cancel() }
        let engine = TransferEngine(
            kind: kind, sources: sources, destination: destination, cancelFlag: flag,
            askConflict: { info in recorder.asked.append(info); return (choice, applyToAll) },
            report: { recorder.last = $0 })
        return await engine.run()
    }

    func testCopyTreeWithProgressAndUndoSteps() async throws {
        try write("hello", src.appendingPathComponent("a.txt"))
        try write(String(repeating: "x", count: 4096), src.appendingPathComponent("folder/inner/b.bin"))
        let recorder = Recorder()
        let result = await run(.copy, [src.appendingPathComponent("a.txt"), src.appendingPathComponent("folder")],
                               to: dst, recorder: recorder)

        XCTAssertNil(result.error)
        XCTAssertEqual(result.created.map(\.lastPathComponent), ["a.txt", "folder"])
        XCTAssertEqual(try read(dst.appendingPathComponent("folder/inner/b.bin")).count, 4096)
        XCTAssertEqual(recorder.last.totalBytes, 5 + 4096)
        XCTAssertEqual(recorder.last.completedBytes, recorder.last.totalBytes)
        // Undo of a copy trashes the copies, newest first.
        let trashed = result.undoSteps.compactMap { step -> String? in
            if case .trash(let url) = step { return url.lastPathComponent }
            return nil
        }
        XCTAssertEqual(trashed, ["folder", "a.txt"])
    }

    func testMoveThenUndoThenRedo() async throws {
        let file = src.appendingPathComponent("doc.txt")
        try write("v1", file)
        let result = await run(.move, [file], to: dst)
        let moved = dst.appendingPathComponent("doc.txt")
        XCTAssertFalse(fm.fileExists(atPath: file.path))
        XCTAssertEqual(try read(moved), "v1")

        let redo = try UndoExecutor.perform(result.undoSteps)
        XCTAssertEqual(try read(file), "v1")
        XCTAssertFalse(fm.fileExists(atPath: moved.path))

        _ = try UndoExecutor.perform(redo)
        XCTAssertEqual(try read(moved), "v1")
    }

    func testConflictKeepBothAndSkip() async throws {
        try write("new", src.appendingPathComponent("a.txt"))
        try write("old", dst.appendingPathComponent("a.txt"))

        let recorder = Recorder()
        let kept = await run(.copy, [src.appendingPathComponent("a.txt")], to: dst, choice: .keepBoth, recorder: recorder)
        XCTAssertEqual(recorder.asked.count, 1)
        XCTAssertEqual(kept.created.map(\.lastPathComponent), ["a 2.txt"])
        XCTAssertEqual(try read(dst.appendingPathComponent("a.txt")), "old")

        let skipped = await run(.copy, [src.appendingPathComponent("a.txt")], to: dst, choice: .skip)
        XCTAssertTrue(skipped.created.isEmpty)
        XCTAssertTrue(skipped.undoSteps.isEmpty)
    }

    func testCopyIntoSameFolderNeverAsks() async throws {
        try write("x", src.appendingPathComponent("a.txt"))
        let recorder = Recorder()
        let result = await run(.copy, [src.appendingPathComponent("a.txt")], to: src, recorder: recorder)
        XCTAssertTrue(recorder.asked.isEmpty)
        XCTAssertEqual(result.created.map(\.lastPathComponent), ["a 2.txt"])

        let dup = await run(.duplicate, [src.appendingPathComponent("a.txt")], to: src)
        XCTAssertEqual(dup.created.map(\.lastPathComponent), ["a 副本.txt"])
    }

    func testMergeFoldersOnMove() async throws {
        try write("1", src.appendingPathComponent("photos/one.jpg"))
        try write("2", src.appendingPathComponent("photos/sub/two.jpg"))
        try write("0", dst.appendingPathComponent("photos/zero.jpg"))
        try write("old-sub", dst.appendingPathComponent("photos/sub/keep.jpg"))

        let recorder = Recorder()
        let result = await run(.move, [src.appendingPathComponent("photos")], to: dst, choice: .merge,
                               applyToAll: true, recorder: recorder)
        XCTAssertNil(result.error)
        let merged = Set(try fm.subpathsOfDirectory(atPath: dst.appendingPathComponent("photos").path))
        XCTAssertEqual(merged, ["zero.jpg", "one.jpg", "sub", "sub/keep.jpg", "sub/two.jpg"])
        XCTAssertFalse(fm.fileExists(atPath: src.appendingPathComponent("photos").path), "empty source folder is removed")
        // "Apply to all" covered the nested sub/ conflict too, so only one question was asked at each level.
        XCTAssertEqual(recorder.asked.count, 2)

        // Undo puts the moved files back and recreates the source folder.
        _ = try UndoExecutor.perform(result.undoSteps)
        XCTAssertEqual(try read(src.appendingPathComponent("photos/sub/two.jpg")), "2")
        XCTAssertEqual(Set(try fm.subpathsOfDirectory(atPath: dst.appendingPathComponent("photos").path)),
                       ["zero.jpg", "sub", "sub/keep.jpg"])
    }

    func testCancelledBeforeStartDoesNothing() async throws {
        try write("x", src.appendingPathComponent("a.txt"))
        let result = await run(.copy, [src.appendingPathComponent("a.txt")], to: dst, cancel: true)
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("a.txt").path))
    }

    func testFolderIntoItselfIsRefused() async throws {
        let folder = src.appendingPathComponent("loop")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = await run(.copy, [folder], to: folder)
        XCTAssertTrue(result.created.isEmpty)
    }

    func testUndoBatchRenameSwap() throws {
        let a = src.appendingPathComponent("a.txt"), b = src.appendingPathComponent("b.txt")
        try write("A", a)
        try write("B", b)
        _ = try BatchRenamer.perform(urls: [a, b], newNames: ["b.txt", "a.txt"])
        XCTAssertEqual(try read(b), "A")

        let steps = UndoExecutor.renameSteps([(from: a, to: b), (from: b, to: a)])
        _ = try UndoExecutor.perform(steps)
        XCTAssertEqual(try read(a), "A")
        XCTAssertEqual(try read(b), "B")
    }

    func testUndoRefusesToOverwrite() throws {
        try write("1", src.appendingPathComponent("x.txt"))
        try write("2", dst.appendingPathComponent("x.txt"))
        XCTAssertThrowsError(try UndoExecutor.perform([.move(from: src.appendingPathComponent("x.txt"),
                                                             to: dst.appendingPathComponent("x.txt"))]))
        XCTAssertEqual(try read(dst.appendingPathComponent("x.txt")), "2")
    }
}
