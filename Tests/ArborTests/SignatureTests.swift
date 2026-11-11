import ArborObjC
import XCTest
@testable import Arbor

/// Git status, developer caches, the timeline and the AI command bar.
final class SignatureTests: XCTestCase {
    // MARK: Git

    func testParsesPorcelainStatus() {
        let output = [
            "## main...origin/main [ahead 2, behind 1]",
            " M Sources/App.swift",
            "A  Sources/New.swift",
            "R  Docs/new.md", "Docs/old.md",
            "?? scratch/",
            "!! build/",
            "UU Sources/Conflict.swift",
        ].joined(separator: "\0") + "\0"
        let status = GitRepoStatus.parse(output, root: "/repo")
        XCTAssertEqual(status.branch, "main")
        XCTAssertTrue(status.hasUpstream)
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.mark(relativePath: "Sources/App.swift", isFolder: false), .item(.modified))
        XCTAssertEqual(status.mark(relativePath: "Sources/New.swift", isFolder: false), .item(.added))
        XCTAssertEqual(status.mark(relativePath: "Docs/new.md", isFolder: false), .item(.renamed))
        XCTAssertNil(status.mark(relativePath: "Docs/old.md", isFolder: false))
        // Whole untracked / ignored folders: the folder and everything in it.
        XCTAssertEqual(status.mark(relativePath: "scratch", isFolder: true), .item(.untracked))
        XCTAssertEqual(status.mark(relativePath: "scratch/a/b.txt", isFolder: false), .item(.untracked))
        XCTAssertEqual(status.mark(relativePath: "build/out.o", isFolder: false), .item(.ignored))
        // A folder shows the most pressing change inside it.
        XCTAssertEqual(status.mark(relativePath: "Sources", isFolder: true), .contains(.conflicted))
        XCTAssertEqual(status.mark(relativePath: "Docs", isFolder: true), .contains(.renamed))
        XCTAssertNil(status.mark(relativePath: "README.md", isFolder: false))
        XCTAssertEqual(status.changeCount, 5)
    }

    func testParsesUnusualBranchLines() {
        XCTAssertEqual(GitRepoStatus.parse("## No commits yet on trunk\0", root: "/r").branch, "trunk")
        let detached = GitRepoStatus.parse("## HEAD (no branch)\0", root: "/r")
        XCTAssertTrue(detached.detached)
        let local = GitRepoStatus.parse("## feature/x\0", root: "/r")
        XCTAssertEqual(local.branch, "feature/x")
        XCTAssertFalse(local.hasUpstream)
    }

    func testDiffParsingSkipsHeader() {
        let diff = "diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n\\ No newline at end of file"
        let lines = GitDiffSection.parse(diff)
        XCTAssertEqual(lines.map(\.text), ["@@ -1,2 +1,2 @@", " keep", "-old", "+new"])
        XCTAssertEqual(lines.filter { $0.kind == .added }.count, 1)
        XCTAssertEqual(lines.filter { $0.kind == .removed }.count, 1)
    }

    // MARK: Developer caches

    func testDerivedDataProjectNames() {
        XCTAssertEqual(DevCacheFinder.projectName(fromDerivedData: "Arbor-bxqzjfhtywkdcvaaeiqgfdmgopua"), "Arbor")
        XCTAssertEqual(DevCacheFinder.projectName(fromDerivedData: "My-App-abcdefghijklmnopqrstuvwxyz"), "My-App")
        XCTAssertEqual(DevCacheFinder.projectName(fromDerivedData: "ModuleCache.noindex"), "ModuleCache.noindex")
    }

    func testResolvesCachesByTheirMarkers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arbor-dev-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for folder in ["web/node_modules", "rust/target", "plain/target", "py/.venv", "notvenv/venv"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        fm.createFile(atPath: root.appendingPathComponent("web/package.json").path, contents: Data("{}".utf8))
        fm.createFile(atPath: root.appendingPathComponent("rust/Cargo.toml").path, contents: Data())
        fm.createFile(atPath: root.appendingPathComponent("py/.venv/pyvenv.cfg").path, contents: Data())
        let candidates = ["web/node_modules", "rust/target", "plain/target", "py/.venv", "notvenv/venv"].enumerated().map {
            (url: root.appendingPathComponent($0.element), size: Int64(10_000_000 - $0.offset), names: [String]())
        }
        let items = DevCacheFinder.resolve(candidates)
        XCTAssertEqual(items.map(\.rule), [.nodeModules, .cargoTarget, .pythonVenv])
        XCTAssertEqual(items.map(\.name), ["web", "rust", "py"])
        // A plain "target" folder without Cargo.toml / pom.xml, and a "venv" without pyvenv.cfg, are left alone.
    }

    // MARK: Timeline

    @MainActor func testTimelineFoldsRunsOfImagesIntoStrips() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("arbor-tl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func entry(_ name: String, minutesAgo: Double) -> TimelineEntry {
            let url = folder.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            return TimelineEntry(item: FileItem(url: url), date: Date().addingTimeInterval(-minutesAgo * 60), event: .modified,
                                 source: nil, isScreenshot: false, types: [])
        }
        let entries = [entry("a.png", minutesAgo: 1), entry("b.png", minutesAgo: 2), entry("c.jpg", minutesAgo: 3),
                       entry("notes.txt", minutesAgo: 4), entry("d.png", minutesAgo: 5)]
        let days = TimelineModel.days(entries)
        XCTAssertEqual(days.count, 1)
        let shapes = days[0].rows.map { row -> String in
            switch row {
            case .strip(let items): "strip\(items.count)"
            case .entry(let item): item.item.name
            }
        }
        XCTAssertEqual(shapes, ["strip3", "notes.txt", "d.png"])
        XCTAssertEqual(days[0].count, 5)
    }

    // MARK: AI

    func testEndpointJoining() {
        XCTAssertEqual(AIClient.endpoint("https://api.anthropic.com", path: "v1/messages").absoluteString,
                       "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(AIClient.endpoint("https://api.anthropic.com/v1/", path: "v1/messages").absoluteString,
                       "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(AIClient.endpoint("http://localhost:11434/v1", path: "chat/completions").absoluteString,
                       "http://localhost:11434/v1/chat/completions")
    }

    func testParsesJSONEvenWithFences() throws {
        let object = try AIClient.parseObject("Sure!\n```json\n{\"action\": \"answer\", \"reply\": \"hi\"}\n```")
        XCTAssertEqual(object["reply"] as? String, "hi")
        XCTAssertThrowsError(try AIClient.parseObject("no json here"))
    }

    func testCommandToPredicate() throws {
        let object: [String: Any] = [
            "action": "search", "reply": "ok", "path": "",
            "query": ["keywords": ["invoice"], "kinds": ["pdf", "bogus"], "extensions": [".PDF"], "withinDays": 7,
                      "after": "", "before": "", "minMB": 1, "maxMB": 0, "downloadedFrom": "github.com", "wholeHome": true],
        ]
        let command = try AIAssistant.command(from: object)
        XCTAssertEqual(command.action, .search)
        XCTAssertEqual(command.query.kinds, ["pdf"])
        XCTAssertEqual(command.query.extensions, ["pdf"])
        XCTAssertEqual(command.query.minBytes, 1_000_000)
        XCTAssertTrue(command.query.wholeHome)
        let predicate = try XCTUnwrap(AIAssistant.predicate(for: command.query)).predicateFormat
        XCTAssertTrue(predicate.contains("kMDItemDisplayName"))
        XCTAssertTrue(predicate.contains("com.adobe.pdf"))
        XCTAssertTrue(predicate.contains("kMDItemWhereFroms"))
        XCTAssertTrue(predicate.contains("kMDItemFSSize"))
        XCTAssertNil(AIAssistant.predicate(for: AICommand.Query()))
    }

    func testSelectionMatchesLocally() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("arbor-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, size) in [("photo.png", 10), ("Screenshot 2026.png", 10), ("big.mov", 3_000_000), ("notes.txt", 5)] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data(count: size))
        }
        let items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).map(FileItem.init(url:))
        func names(_ query: AICommand.Query) -> [String] { AIAssistant.matches(items, query).map(\.name).sorted() }
        var images = AICommand.Query()
        images.kinds = ["image"]
        XCTAssertEqual(names(images), ["Screenshot 2026.png", "photo.png"])
        var shots = AICommand.Query()
        shots.kinds = ["screenshot"]
        XCTAssertEqual(names(shots), ["Screenshot 2026.png"])
        var big = AICommand.Query()
        big.minBytes = 1_000_000
        XCTAssertEqual(names(big), ["big.mov"])
    }

    func testRenameRepliesKeepExtensions() {
        let urls = [URL(fileURLWithPath: "/tmp/IMG_1.png"), URL(fileURLWithPath: "/tmp/scan.pdf")]
        let object: [String: Any] = ["names": [["index": 0, "name": "Receipt: coffee"], ["index": 1, "name": "Lease.PDF"],
                                               ["index": 5, "name": "nope"]]]
        XCTAssertEqual(AIAssistant.names(from: object, for: urls), ["Receipt- coffee.png", "Lease.PDF"])
    }

    // MARK: Assistant

    @MainActor func testParsesToolCalls() throws {
        let object: [String: Any] = [
            "tool": "move", "path": "", "paths": ["~/Desktop/a.png", ""], "to": "~/Pictures/Shots", "name": "", "command": "",
            "title": "", "query": ["keywords": [], "kinds": ["image"], "extensions": [], "withinDays": 3, "after": "", "before": "",
                                   "minMB": 0, "maxMB": 0, "downloadedFrom": "", "wholeHome": false],
        ]
        let call = try XCTUnwrap(AIAgentPrompt.call(from: object))
        XCTAssertEqual(call.tool, .move)
        XCTAssertTrue(call.tool.changesFiles)
        XCTAssertEqual(call.paths, ["~/Desktop/a.png"])
        XCTAssertEqual(call.query.kinds, ["image"])
        XCTAssertEqual(call.query.withinDays, 3)
        XCTAssertNil(AIAgentPrompt.call(from: ["tool": "format_disk"]))
        XCTAssertFalse(AIToolCall.Tool.search.changesFiles)
        XCTAssertFalse(AIToolCall.Tool.show.changesFiles)
    }

    @MainActor func testShortensPlanPaths() {
        let base = URL(fileURLWithPath: "/Users/me/Downloads")
        XCTAssertEqual(AIAgent.display("/Users/me/Downloads/PDF/x.pdf", base: base), "“PDF/x.pdf”")
        XCTAssertTrue(AIAgent.display("/Library/Fonts", base: base).hasPrefix("/Library"))
        XCTAssertEqual(AIAgent.display("/private/tmp/demo/New Folder", base: URL(fileURLWithPath: "/tmp/demo")), "“New Folder”")
    }

    func testMergesConsecutiveMessages() {
        let merged = AIClient.merged([("user", "a"), ("user", "b"), ("assistant", "c"), ("user", "d")])
        XCTAssertEqual(merged.map { $0["role"] ?? "" }, ["user", "assistant", "user"])
        XCTAssertEqual(merged[0]["content"], "a\n\nb")
    }

    @MainActor func testAgentSchemaRequiresEveryField() {
        let schema = AIAgentPrompt.schema()
        let call = ((schema["properties"] as? [String: Any])?["calls"] as? [String: Any])?["items"] as? [String: Any]
        let required = Set(call?["required"] as? [String] ?? [])
        let properties = Set((call?["properties"] as? [String: Any])?.keys.map { $0 } ?? [])
        XCTAssertEqual(required, properties)
        XCTAssertEqual(call?["additionalProperties"] as? Bool, false)
    }

    /// "上周下载的 PDF": one kind plus a date. Spotlight throws for one-member OR groups, which used to
    /// corrupt the main thread's task state and crash Arbor a moment later.
    @MainActor func testSpotlightAcceptsEveryQueryShape() throws {
        var shapes: [AICommand.Query] = []
        var pdf = AICommand.Query(); pdf.kinds = ["pdf"]; pdf.withinDays = 7; shapes.append(pdf)
        var one = AICommand.Query(); one.kinds = ["image"]; shapes.append(one)
        var ext = AICommand.Query(); ext.extensions = ["md"]; shapes.append(ext)
        var mixed = AICommand.Query(); mixed.kinds = ["document"]; mixed.keywords = ["invoice"]; mixed.minBytes = 1; shapes.append(mixed)
        var shot = AICommand.Query(); shot.kinds = ["screenshot"]; shapes.append(shot)
        for query in shapes {
            let predicate = try XCTUnwrap(AIAssistant.predicate(for: query))
            let spotlight = NSMetadataQuery()
            spotlight.predicate = predicate
            spotlight.searchScopes = [FileManager.default.temporaryDirectory]
            var error: NSError?
            XCTAssertTrue(ArborCatchException({ spotlight.start() }, &error), "\(predicate): \(error?.localizedDescription ?? "")")
            spotlight.stop()
        }
        // And the catcher really catches.
        var error: NSError?
        XCTAssertFalse(ArborCatchException({ NSArray().object(at: 3) }, &error))
        XCTAssertNotNil(error)
    }

    func testParsesMessyReplies() throws {
        // Reasoning models' thinking, prose with braces around the object, trailing commas, code fences.
        let thinking = "<think>The user wants {pdfs}. I'll search.</think>\n{\"say\": \"ok\", \"calls\": [], \"done\": true}"
        XCTAssertEqual(try AIClient.parseObject(thinking)["say"] as? String, "ok")
        let prose = "Here you go {not json} and then {\"say\": \"a } b\", \"done\": true} thanks"
        XCTAssertEqual(try AIClient.parseObject(prose)["say"] as? String, "a } b")
        let trailing = "```json\n{\"say\": \"x\", \"calls\": [], \"done\": true,}\n```"
        XCTAssertEqual(try AIClient.parseObject(trailing)["say"] as? String, "x")
        // Nothing but whitespace: an error that says so, not "couldn't understand: ".
        XCTAssertThrowsError(try AIClient.parseObject("\n\n\n   \n")) { error in
            guard case AIError.unreadable(let raw) = error else { return XCTFail("\(error)") }
            XCTAssertNil(AIError.snippet(raw))
            XCTAssertFalse(error.localizedDescription.hasSuffix("："))
        }
    }
}
