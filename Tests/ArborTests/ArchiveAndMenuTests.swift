import XCTest
@testable import Arbor

@MainActor
final class ArchiveAndMenuTests: XCTestCase {
    private var dir: URL!
    private var savedHidden: Set<String>!
    private var savedArchiver: String!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ArborArchiveMenu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("world".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try Data("zip".utf8).write(to: dir.appendingPathComponent("bundle.tar.gz"))
        try Data("7z".utf8).write(to: dir.appendingPathComponent("pack.7z"))
        savedHidden = AppSettings.shared.hiddenMenuItems
        savedArchiver = AppSettings.shared.archiverBundleID
    }

    override func tearDown() async throws {
        AppSettings.shared.hiddenMenuItems = savedHidden
        AppSettings.shared.archiverBundleID = savedArchiver
        try? FileManager.default.removeItem(at: dir)
    }

    func testArchiveDetectionHandlesCompoundExtensionsAndSkipsFolders() {
        XCTAssertTrue(ArchiveTools.isArchive(dir.appendingPathComponent("bundle.tar.gz")))
        XCTAssertTrue(ArchiveTools.isArchive(dir.appendingPathComponent("pack.7z")))
        XCTAssertFalse(ArchiveTools.isArchive(dir.appendingPathComponent("a.txt")))
        XCTAssertFalse(ArchiveTools.isArchive(dir.appendingPathComponent("Sub")))
    }

    func testDittoCompressesFilesIntoZip() {
        let exp = expectation(description: "ditto zip")
        var createdURLs: [URL] = []
        var failure: Error?
        ArchiveTools.compressWithDitto(
            [dir.appendingPathComponent("a.txt"), dir.appendingPathComponent("b.txt")],
            in: dir
        ) { created, error in
            createdURLs = created
            failure = error
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertNil(failure)
        XCTAssertEqual(createdURLs.count, 1)
        XCTAssertEqual(createdURLs.first?.pathExtension, "zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdURLs[0].path))
    }

    func testOpenWithAvailableForFoldersAndMultiSelectionWithOtherOption() throws {
        AppSettings.shared.hiddenMenuItems = []
        let ws = WorkspaceState()
        let tab = ws.activeTab
        let folder = FileItem(url: dir.appendingPathComponent("Sub"))
        let fileA = FileItem(url: dir.appendingPathComponent("a.txt"))
        let fileB = FileItem(url: dir.appendingPathComponent("b.txt"))

        let folderMenu = ContextMenuBuilder.sections(workspace: ws, tab: tab, selected: [folder]).flatMap { $0 }
        let folderOpenWith = try XCTUnwrap(folderMenu.first { $0.title == "打开方式" })
        XCTAssertTrue(folderOpenWith.children.flatMap { $0 }.contains { $0.title == "其他…" })

        let multiMenu = ContextMenuBuilder.sections(workspace: ws, tab: tab, selected: [fileA, fileB]).flatMap { $0 }
        let multiOpenWith = try XCTUnwrap(multiMenu.first { $0.title == "打开方式" })
        XCTAssertTrue(multiOpenWith.children.flatMap { $0 }.contains { $0.title == "其他…" })
    }

    func testBatchRenameHiddenOnSingleItemAndShownOnMultiple() {
        AppSettings.shared.hiddenMenuItems = []
        let ws = WorkspaceState()
        let tab = ws.activeTab
        let fileA = FileItem(url: dir.appendingPathComponent("a.txt"))
        let fileB = FileItem(url: dir.appendingPathComponent("b.txt"))

        let singleMenu = ContextMenuBuilder.sections(workspace: ws, tab: tab, selected: [fileA]).flatMap { $0 }
        XCTAssertNil(singleMenu.first { $0.title == "批量重命名…" })

        let multiMenu = ContextMenuBuilder.sections(workspace: ws, tab: tab, selected: [fileA, fileB]).flatMap { $0 }
        XCTAssertNotNil(multiMenu.first { $0.title == "批量重命名…" })
    }

    func testArchiveMenuSwitchesBetweenCompressAndExtract() {
        AppSettings.shared.hiddenMenuItems = []
        AppSettings.shared.archiverBundleID = ExternalApp.systemArchiverBundleID
        let ws = WorkspaceState()
        let tab = ws.activeTab
        let archive = FileItem(url: dir.appendingPathComponent("pack.7z"))
        let plain = FileItem(url: dir.appendingPathComponent("a.txt"))

        let archiveMenu = ContextMenuBuilder.sections(workspace: ws, tab: tab, selected: [archive]).flatMap { $0 }
        XCTAssertNotNil(archiveMenu.first { $0.title == "解压" })

        let plainMenu = ContextMenuBuilder.sections(workspace: ws, tab: tab, selected: [plain]).flatMap { $0 }
        XCTAssertNotNil(plainMenu.first { $0.title == "压缩为 ZIP" })
    }

    func testMenuPresetsFilterAsExpected() {
        XCTAssertTrue(ContextMenuBuilder.MenuPreset.full.hiddenItems.isEmpty)
        XCTAssertTrue(ContextMenuBuilder.MenuPreset.standard.hiddenItems.isSubset(of: ContextMenuBuilder.MenuPreset.minimal.hiddenItems))
        let allIDs = Set(ContextMenuBuilder.customizable)
        XCTAssertTrue(ContextMenuBuilder.MenuPreset.minimal.hiddenItems.isSubset(of: allIDs))
        XCTAssertTrue(ContextMenuBuilder.MenuPreset.standard.hiddenItems.isSubset(of: allIDs))
    }

    func testNewFolderClearsActiveFilterAndRequestsRename() {
        let ws = WorkspaceState()
        let tab = ws.activeTab
        tab.navigate(to: dir)
        tab.filter = "nonexistent-filter"
        ws.newFolder()
        XCTAssertEqual(tab.filter, "")
        XCTAssertNotNil(tab.renamingURL)
        if let created = tab.renamingURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))
        }
    }

    func testFileClipboardTracksAndClearsCutPaths() {
        let fileA = dir.appendingPathComponent("a.txt")
        let clipboard = FileClipboard.shared
        clipboard.write([fileA], cut: true)
        XCTAssertTrue(clipboard.isCut)
        XCTAssertTrue(clipboard.activeCutPaths.contains(fileA.standardizedFileURL.path))

        clipboard.write([fileA], cut: false)
        XCTAssertFalse(clipboard.isCut)
        XCTAssertTrue(clipboard.activeCutPaths.isEmpty)

        clipboard.write([fileA], cut: true)
        clipboard.didPasteCut()
        XCTAssertFalse(clipboard.isCut)
        XCTAssertTrue(clipboard.activeCutPaths.isEmpty)
    }

    func testWorkspaceShowsToastOnCopyAndCut() {
        let ws = WorkspaceState()
        let fileA = dir.appendingPathComponent("a.txt")
        ws.cut([fileA])
        XCTAssertEqual(ws.toast?.symbol, "scissors")
        ws.copyPath([fileA])
        XCTAssertEqual(ws.toast?.symbol, "link")
    }

    func testByteCountRespectsCancelFlag() {
        let flag = CancelFlag()
        flag.cancel()
        let counted = TransferEngine.byteCount(of: dir, cancelFlag: flag)
        XCTAssertEqual(counted, 0)
    }
}
