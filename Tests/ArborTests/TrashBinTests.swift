import XCTest
@testable import Arbor

/// Emptying the Trash, tested on a stand-in folder (never the real Trash).
final class TrashBinTests: XCTestCase {
    func testDeletesEverythingIncludingLockedItems() throws {
        let fm = FileManager.default
        let trash = fm.temporaryDirectory.appendingPathComponent("ArborTrash-\(UUID().uuidString)")
        defer {
            if let all = fm.enumerator(atPath: trash.path) {
                for case let path as String in all {
                    try? fm.setAttributes([.immutable: false], ofItemAtPath: trash.appendingPathComponent(path).path)
                }
            }
            try? fm.removeItem(at: trash)
        }
        try fm.createDirectory(at: trash.appendingPathComponent("folder/inner"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: trash.appendingPathComponent("file.txt"))
        let locked = trash.appendingPathComponent("folder/inner/locked.txt")
        try Data("b".utf8).write(to: locked)
        try fm.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        try Data().write(to: trash.appendingPathComponent(".DS_Store"))

        XCTAssertEqual(TrashBin.summary(of: [trash]), TrashBin.Summary(count: 2, readable: true), ".DS_Store doesn't count")
        let failures = TrashBin.deleteContents(of: [trash])
        XCTAssertEqual(failures, [])
        XCTAssertEqual(TrashBin.summary(of: [trash]).count, 0)
        XCTAssertTrue(fm.fileExists(atPath: trash.path), "the Trash folder itself stays")
    }

    func testRecognizesTrashFolders() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(TrashBin.isTrash(home.appendingPathComponent(".Trash")))
        XCTAssertTrue(TrashBin.isTrash(URL(fileURLWithPath: "/Volumes/Disk/.Trashes/\(getuid())")))
        XCTAssertFalse(TrashBin.isTrash(home.appendingPathComponent("Downloads")))
        XCTAssertFalse(TrashBin.isTrash(home.appendingPathComponent(".Trash/old folder")))
        XCTAssertEqual(TrashBin.folders().first?.path, home.appendingPathComponent(".Trash").path)
    }

    func testUnreadableTrashIsReported() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        XCTAssertFalse(TrashBin.summary(of: [missing]).readable)
    }
}
