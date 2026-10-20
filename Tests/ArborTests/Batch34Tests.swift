import AppKit
import SwiftUI
import XCTest
@testable import Arbor

final class FileToolTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ArborTools-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func file(_ path: String, _ text: String = "x") throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testNewFolderWithSelectionAndUndo() throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let (folder, undo) = try FileTools.newFolder(with: [a, b], in: root)
        XCTAssertEqual(folder.lastPathComponent, "带项目的新文件夹")
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: folder.path)), ["a.txt", "b.txt"])
        // Undo minus the final ".trash(folder)" step (so the test never touches the real Trash).
        _ = try UndoExecutor.perform(undo.filter { if case .trash = $0 { return false }; return true })
        XCTAssertTrue(fm.fileExists(atPath: a.path))
        XCTAssertTrue(fm.fileExists(atPath: b.path))
    }

    func testFlattenAndUndo() throws {
        _ = try file("box/one/a.txt", "1")
        _ = try file("box/one/two/a.txt", "2")
        _ = try file("box/top.txt")
        let box = root.appendingPathComponent("box")
        let (moved, undo) = try FileTools.flatten(box) { url in
            try FileManager.default.removeItem(at: url)
            return nil
        }
        XCTAssertEqual(moved, 2)
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: box.path)), ["a.txt", "a 2.txt", "top.txt"])
        _ = try UndoExecutor.perform(undo)
        XCTAssertEqual(try String(contentsOf: box.appendingPathComponent("one/two/a.txt"), encoding: .utf8), "2")
    }

    func testTreeHashesAndLinks() throws {
        let target = try file("t/sub/x.txt", "abc")
        _ = try file("t/y.txt")
        let tree = FileTools.tree(of: root.appendingPathComponent("t"))
        XCTAssertTrue(tree.hasPrefix("t/\n├── sub/\n│   └── x.txt\n└── y.txt"), tree)
        XCTAssertTrue(tree.hasSuffix("1 个文件夹，2 个文件"))

        let hashes = FileTools.hashes([target])
        XCTAssertTrue(hashes.contains("900150983cd24fb0d6963f7d28e17f72"), "MD5 of abc")
        XCTAssertTrue(hashes.contains("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), "SHA-256 of abc")

        let link = try FileTools.makeSymlink(to: target)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), target.path)
        let alias = try FileTools.makeAlias(to: target)
        XCTAssertEqual(try URL(resolvingAliasFileAt: alias).standardizedFileURL.path, target.standardizedFileURL.path)
    }

    func testTemplateInstantiation() throws {
        let template = try file("templates/Markdown.md", "# 标题")
        let made = try Templates.instantiate(template, in: root)
        XCTAssertEqual(made.lastPathComponent, "未命名.md")
        XCTAssertEqual(try Templates.instantiate(template, in: root).lastPathComponent, "未命名 2.md")
    }

    func testTagsRoundTrip() throws {
        let url = try file("tagged.txt")
        try FinderTags.toggle("测试标签", on: [url])
        XCTAssertEqual(FinderTags.tags(of: url), ["测试标签"])
        try FinderTags.toggle("测试标签", on: [url])
        XCTAssertEqual(FinderTags.tags(of: url), [])
    }

    func testTextReadsGB18030() throws {
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let url = root.appendingPathComponent("gbk.txt")
        try "中文内容".data(using: gb)!.write(to: url)
        XCTAssertEqual(TextFile.read(url)?.0, "中文内容")
    }
}

final class ImageToolTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ArborImages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func makePNG(width: Int, height: Int) throws -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let url = root.appendingPathComponent("photo.png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    private func size(_ url: URL) -> (Int, Int) {
        let rep = NSImageRep(contentsOf: url)!
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    func testConvertResizeAndPDF() throws {
        let png = try makePNG(width: 400, height: 200)
        XCTAssertTrue(ImageTools.isImage(png))
        let jpg = try ImageTools.convert(png, to: .jpeg)
        XCTAssertEqual(jpg.lastPathComponent, "photo.jpg")
        XCTAssertEqual(size(jpg).0, 400)

        let small = try ImageTools.convert(png, to: .png, maxPixel: 100)
        XCTAssertEqual(small.lastPathComponent, "photo 100px.png")
        XCTAssertEqual(size(small).0, 100)
        XCTAssertEqual(size(small).1, 50)

        let pdf = try ImageTools.makePDF([png, jpg], in: root)
        XCTAssertEqual(PDFDocumentPageCount(pdf), 2)
    }

    private func PDFDocumentPageCount(_ url: URL) -> Int {
        CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
    }
}

final class Batch34LogicTests: XCTestCase {
    func testColorRuleGlobs() {
        let rule = ColorRule(pattern: "*.psd; IMG_????.jpg", tint: .purple)
        XCTAssertTrue(rule.matches("设计稿.PSD"))
        XCTAssertTrue(rule.matches("IMG_0042.jpg"))
        XCTAssertFalse(rule.matches("IMG_42.jpg"))
        XCTAssertFalse(rule.matches("notes.txt"))
        var off = rule
        off.enabled = false
        XCTAssertFalse(off.matches("a.psd"))
    }

    func testServerAddressNormalization() {
        XCTAssertEqual(ServerConnect.normalize("192.168.1.10/share")?.absoluteString, "smb://192.168.1.10/share")
        XCTAssertEqual(ServerConnect.normalize("afp://nas.local/Photos")?.scheme, "afp")
        XCTAssertNil(ServerConnect.normalize("gopher://x"))
        XCTAssertNil(ServerConnect.normalize("  "))
    }

    func testShortcutSpecRoundTrip() {
        let spec = ShortcutSpec(KeyboardShortcut(.rightArrow, modifiers: [.command, .option]))
        XCTAssertEqual(spec.key, "right")
        XCTAssertEqual(spec.display, "⌥⌘→")
        XCTAssertEqual(spec.keyboardShortcut.key, .rightArrow)
        XCTAssertEqual(ShortcutSpec(key: "n", modifiers: EventModifiers([.command, .shift]).rawValue).display, "⇧⌘N")
    }

    func testShortcutCatalogHasNoDuplicateDefaults() {
        let displays = ShortcutCatalog.entries.map { ShortcutSpec($0.defaultShortcut).display }
        let duplicates = Dictionary(grouping: displays, by: { $0 }).filter { $0.value.count > 1 }.keys
        XCTAssertTrue(duplicates.isEmpty, "conflicting defaults: \(duplicates)")
    }

    func testSyntaxHighlighterKeepsText() {
        let code = "let x = \"hi\" // note"
        XCTAssertEqual(String(SyntaxHighlighter.highlight(code).characters), code)
    }
}

final class AppearanceTests: XCTestCase {
    func testFlattenPreviewFlagsProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArborFlat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Sources/a.swift", "Sources/b.swift", "docs/readme.md"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        var preview = FileTools.flattenPreview(root)
        XCTAssertEqual(preview.fileCount, 3)
        XCTAssertEqual(preview.subfolders, ["docs", "Sources"])
        XCTAssertFalse(preview.looksLikeProject)
        try Data().write(to: root.appendingPathComponent("Package.swift"))
        preview = FileTools.flattenPreview(root)
        XCTAssertTrue(preview.looksLikeProject, "a Package.swift marks a code project")
    }

    func testOldSessionsWithoutTintStillDecode() throws {
        let json = #"{"panes":[{"tabs":[{"path":"/tmp","viewMode":"list","sortKey":"name","ascending":true,"pinned":false}],"activeTab":0}],"paneCount":1,"activePane":0,"showInspector":false}"#
        let snapshot = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.tint)
        XCTAssertEqual(SavedWorkspace(name: "x", snapshot: snapshot).tint, .indigo)
    }

    @MainActor
    func testTintAndOpenWorkspaceRoundTripThroughSnapshot() {
        let workspace = WorkspaceState(snapshot: nil)
        workspace.tint = .teal
        let id = UUID()
        workspace.openWorkspaceID = id
        let restored = WorkspaceState(snapshot: workspace.snapshot)
        XCTAssertEqual(restored.tint, .teal)
        XCTAssertEqual(restored.openWorkspaceID, id, "relaunching keeps which workspace the window shows")
    }
}

final class PaneResizeTests: XCTestCase {
    func testResizeIsDeterministicAndClamped() {
        let start: [CGFloat] = [1, 1, 1]
        // 1000pt for two panes: each fraction point = 2/1000.
        let a = PanesView.resized(start, divider: 0, translation: 100, available: 1000, count: 2, minimumWidth: 240)!
        let b = PanesView.resized(start, divider: 0, translation: 100, available: 1000, count: 2, minimumWidth: 240)!
        XCTAssertEqual(a, b, "same drag → same widths, so the layout can't oscillate")
        XCTAssertEqual(a[0], 1.2, accuracy: 0.0001)
        XCTAssertEqual(a[1], 0.8, accuracy: 0.0001)
        XCTAssertEqual(a[0] + a[1], 2, accuracy: 0.0001, "total is preserved")

        let far = PanesView.resized(start, divider: 0, translation: 5000, available: 1000, count: 2, minimumWidth: 240)!
        XCTAssertEqual(far[1] * 1000 / 2, 240, accuracy: 0.01, "the other pane stops at the minimum width")
        let back = PanesView.resized(start, divider: 0, translation: -5000, available: 1000, count: 2, minimumWidth: 240)!
        XCTAssertEqual(back[0] * 1000 / 2, 240, accuracy: 0.01)
        XCTAssertNil(PanesView.resized(start, divider: 0, translation: 10, available: 400, count: 2, minimumWidth: 240),
                     "no room to resize when both panes are at the minimum")
    }
}

final class UpdaterTests: XCTestCase {
    func testVersionOrdering() {
        let v = { ReleaseVersion(tag: $0)! }
        XCTAssertLessThan(v("v0.1.0-dev.1"), v("v0.1.0-dev.2"))
        XCTAssertLessThan(v("v0.1.0-dev.9"), v("v0.1.0"), "a preview comes before its final release")
        XCTAssertLessThan(v("v0.1.0"), v("v0.1.1-dev.1"))
        XCTAssertLessThan(v("0.9"), v("v1.0.0"))
        XCTAssertEqual(v("v1.2"), v("1.2.0"))
        XCTAssertNil(ReleaseVersion(tag: "latest"))
    }

    private func release(_ tag: String, prerelease: Bool = false, draft: Bool = false, zip: Bool = true) throws -> ReleaseInfo {
        let assets = zip ? #"[{"name":"Arbor-\#(tag).zip","size":10,"browser_download_url":"https://example.com/a.zip"}]"# : "[]"
        let json = #"{"tag_name":"\#(tag)","name":null,"body":"notes","prerelease":\#(prerelease),"draft":\#(draft),"html_url":"https://example.com","published_at":null,"assets":\#(assets)}"#
        return try JSONDecoder().decode(ReleaseInfo.self, from: Data(json.utf8))
    }

    func testPicksNewestEligibleRelease() throws {
        let current = ReleaseVersion(tag: "v0.1.0-dev.1")!
        let releases = [
            try release("v0.1.0-dev.1", prerelease: true),
            try release("v0.1.0-dev.3", prerelease: true),
            try release("v0.2.0-dev.1", prerelease: true, draft: true),
            try release("v0.1.0-dev.4", prerelease: true, zip: false),
        ]
        XCTAssertEqual(ReleaseInfo.newest(in: releases, after: current, includePreviews: true)?.tagName, "v0.1.0-dev.3",
                       "drafts and releases without an app zip are skipped")
        XCTAssertNil(ReleaseInfo.newest(in: releases, after: current, includePreviews: false),
                     "previews are only offered when the user opts in")
        XCTAssertNil(ReleaseInfo.newest(in: releases, after: ReleaseVersion(tag: "v0.1.0-dev.3")!, includePreviews: true))
        XCTAssertEqual(ReleaseInfo.newest(in: releases + [try release("v0.1.0")], after: current, includePreviews: false)?.tagName,
                       "v0.1.0")
        // Going final: 1.0.0 outranks every 0.1.0 preview, and reaches people who turned previews off.
        let dev4 = ReleaseVersion(tag: "v0.1.0-dev.4")!
        let withFinal = releases + [try release("v0.1.0-dev.4", prerelease: true), try release("v1.0.0")]
        XCTAssertEqual(ReleaseInfo.newest(in: withFinal, after: dev4, includePreviews: true)?.tagName, "v1.0.0")
        XCTAssertEqual(ReleaseInfo.newest(in: withFinal, after: dev4, includePreviews: false)?.tagName, "v1.0.0")
        XCTAssertNil(ReleaseInfo.newest(in: withFinal, after: ReleaseVersion(tag: "v1.0.0")!, includePreviews: true))
    }
}
