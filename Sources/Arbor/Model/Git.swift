import Foundation
import Observation

// MARK: - Status model

/// How a path differs from the last commit, as `git status` reports it. Ordered by how much it
/// deserves attention: a folder shows the most pressing change inside it.
enum GitChange: Int, Comparable, Sendable {
    case ignored, untracked, renamed, added, modified, deleted, conflicted

    static func < (a: GitChange, b: GitChange) -> Bool { a.rawValue < b.rawValue }

    /// One letter, like the gutter of a code editor.
    var letter: String {
        switch self {
        case .ignored: "!"
        case .untracked: "U"
        case .renamed: "R"
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .conflicted: "C"
        }
    }

    var title: String {
        switch self {
        case .ignored: L("已忽略")
        case .untracked: L("未跟踪")
        case .renamed: L("已重命名")
        case .added: L("已添加")
        case .modified: L("已修改")
        case .deleted: L("已删除")
        case .conflicted: L("有冲突")
        }
    }

    /// Two status letters from `git status --porcelain` (index, then work tree).
    init?(x: Character, y: Character) {
        switch (x, y) {
        case ("?", "?"): self = .untracked
        case ("!", "!"): self = .ignored
        case ("D", "D"), ("A", "U"), ("U", "D"), ("U", "A"), ("D", "U"), ("A", "A"), ("U", "U"): self = .conflicted
        default:
            if x == "R" || y == "R" || x == "C" { self = .renamed }
            else if x == "A" { self = .added }
            else if x == "D" || y == "D" { self = .deleted }
            else if x == " " && y == " " { return nil }
            else { self = .modified }
        }
    }
}

/// What a row shows: the item's own change, or (for a folder) the most pressing change inside it.
enum GitMark: Equatable, Sendable {
    case item(GitChange)
    case contains(GitChange)

    var change: GitChange {
        switch self {
        case .item(let change), .contains(let change): change
        }
    }
}

/// One repository's `git status`, keyed by paths relative to its root.
struct GitRepoStatus: Equatable, Sendable {
    let root: String
    var branch: String?
    var detached = false
    var ahead = 0
    var behind = 0
    var hasUpstream = false
    /// Files and (with a trailing "/") whole untracked or ignored folders.
    var entries: [String: GitChange] = [:]
    /// The most pressing change under each folder that has one ("" is the root).
    var folders: [String: GitChange] = [:]
    /// Untracked or ignored folders (no trailing "/"), whose whole contents share the state.
    var wholeFolders: [String: GitChange] = [:]

    /// Changed files, not counting ignored ones.
    var changes: [(path: String, change: GitChange)] {
        entries.filter { $0.value != .ignored }.map { ($0.key, $0.value) }.sorted { $0.path < $1.path }
    }

    var changeCount: Int { entries.values.lazy.filter { $0 != .ignored }.count }

    func mark(relativePath rel: String, isFolder: Bool) -> GitMark? {
        if let own = entries[rel] ?? entries[rel + "/"] { return .item(own) }
        // Inside an untracked or ignored folder: everything inherits it.
        var parent = rel
        while let slash = parent.lastIndex(of: "/") {
            parent = String(parent[..<slash])
            if let whole = wholeFolders[parent] { return .item(whole) }
        }
        if isFolder, let inside = folders[rel], inside != .ignored { return .contains(inside) }
        return nil
    }

    /// Parses `git status --porcelain=v1 -z --branch --ignored`.
    static func parse(_ output: String, root: String) -> GitRepoStatus {
        var status = GitRepoStatus(root: root)
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let field = fields.next() {
            if field.hasPrefix("## ") {
                status.readBranch(String(field.dropFirst(3)))
                continue
            }
            guard field.count > 3 else { continue }
            let chars = Array(field.prefix(2))
            let path = String(field.dropFirst(3))
            // A rename is followed by its old name, which we don't show.
            if chars[0] == "R" || chars[0] == "C" { _ = fields.next() }
            guard let change = GitChange(x: chars[0], y: chars[1]) else { continue }
            status.entries[path] = change
            if path.hasSuffix("/") { status.wholeFolders[String(path.dropLast())] = change }
            // Roll the change up into every folder above it.
            var parent = path.hasSuffix("/") ? String(path.dropLast()) : path
            while true {
                if let slash = parent.lastIndex(of: "/") { parent = String(parent[..<slash]) } else { parent = "" }
                // Every folder above already carries at least this much.
                if let known = status.folders[parent], known >= change { break }
                status.folders[parent] = change
                if parent.isEmpty { break }
            }
        }
        return status
    }

    /// "main...origin/main [ahead 1, behind 2]", "No commits yet on main", "HEAD (no branch)".
    private mutating func readBranch(_ line: String) {
        if line.hasPrefix("No commits yet on ") {
            branch = String(line.dropFirst("No commits yet on ".count))
            return
        }
        if line.hasPrefix("HEAD (no branch)") {
            detached = true
            branch = "HEAD"
            return
        }
        var head = line
        if let bracket = line.range(of: " [") {
            head = String(line[..<bracket.lowerBound])
            let info = line[bracket.upperBound...].dropLast()
            for part in info.split(separator: ",") {
                let words = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
                guard words.count == 2, let count = Int(words[1]) else { continue }
                if words[0] == "ahead" { ahead = count } else if words[0] == "behind" { behind = count }
            }
        }
        if let dots = head.range(of: "...") {
            branch = String(head[..<dots.lowerBound])
            hasUpstream = true
        } else {
            branch = head
        }
    }
}

// MARK: - Running git

enum GitRunner {
    /// A git that won't trigger the "install command line developer tools" prompt: Homebrew's, or
    /// Apple's only when the developer tools are actually installed. Found by looking at files only:
    /// this is first read on the main thread, which must never wait for a process.
    static let executable: String? = {
        let fm = FileManager.default
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // What `xcode-select -p` prints, read from its symlink (or the default locations).
        var developerDirs: [String] = []
        if let linked = try? fm.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") { developerDirs.append(linked) }
        developerDirs += ["/Applications/Xcode.app/Contents/Developer", "/Library/Developer/CommandLineTools"]
        guard developerDirs.contains(where: { fm.isExecutableFile(atPath: $0 + "/usr/bin/git") }) else { return nil }
        return "/usr/bin/git"
    }()

    /// Runs git in `directory`; nil when git is missing or fails. Blocks, so call it off the main thread.
    static func git(_ arguments: [String], in directory: String, limit: Int = 8_000_000) -> String? {
        guard let executable else { return nil }
        return run(executable, ["-C", directory] + arguments, limit: limit)
    }

    private static func run(_ tool: String, _ arguments: [String], limit: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Reading status must never take the index lock or rewrite the index (that would wake our own watcher).
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // `waitUntilExit()` spins the current run loop, which re-enters whatever else is queued on this thread.
        // Wait on a semaphore instead.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        var data = Data()
        let handle = output.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if data.count < limit { data.append(chunk) }
        }
        exited.wait()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data.prefix(limit), as: UTF8.self)
    }
}

// MARK: - Index

/// Keeps `git status` for the repositories that open tabs are showing, refreshed as files change.
@MainActor @Observable
final class GitIndex {
    static let shared = GitIndex()

    /// Bumps whenever any repository's status changes.
    private(set) var revision = 0

    @ObservationIgnored private var statuses: [String: GitRepoStatus] = [:]
    @ObservationIgnored private var roots: [String: String?] = [:]
    @ObservationIgnored private var watchers: [String: RepoWatcher] = [:]
    @ObservationIgnored private var leases: [String: Int] = [:]
    @ObservationIgnored private var refreshing: Set<String> = []
    @ObservationIgnored private var refreshAgain: Set<String> = []

    var isAvailable: Bool { GitRunner.executable != nil }

    /// The repository containing `folder` (the folder holding `.git`), cached.
    func repoRoot(for folder: URL) -> String? {
        let path = folder.standardizedFileURL.path
        if let known = roots[path] { return known }
        var current = path
        var found: String?
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: current + (current == "/" ? ".git" : "/.git")) { found = current; break }
            if current == "/" { break }
            current = (current as NSString).deletingLastPathComponent
        }
        roots[path] = .some(found)
        return found
    }

    /// Starts following the repository that contains `folder` while the lease lives.
    func track(_ folder: URL) -> GitLease? {
        guard AppSettings.shared.showGitStatus, isAvailable, let root = repoRoot(for: folder) else { return nil }
        leases[root, default: 0] += 1
        if watchers[root] == nil {
            watchers[root] = RepoWatcher(root: root) { [weak self] in self?.refresh(root) }
            refresh(root)
        }
        return GitLease(root: root)
    }

    fileprivate func release(_ root: String) {
        guard let count = leases[root] else { return }
        if count > 1 {
            leases[root] = count - 1
            return
        }
        leases[root] = nil
        watchers[root] = nil
        // Keep the last status around briefly: switching tabs back and forth shouldn't re-run git.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.leases[root] == nil else { return }
            self.statuses[root] = nil
        }
    }

    func status(forRoot root: String) -> GitRepoStatus? { statuses[root] }

    func status(containing folder: URL) -> GitRepoStatus? {
        repoRoot(for: folder).flatMap { statuses[$0] }
    }

    /// The badge for one item, if its repository is being followed.
    func mark(for url: URL, isFolder: Bool) -> GitMark? {
        guard AppSettings.shared.showGitStatus else { return nil }
        let path = url.standardizedFileURL.path
        let parent = (path as NSString).deletingLastPathComponent
        guard let root = roots[parent] ?? repoRoot(for: URL(fileURLWithPath: parent)), let status = statuses[root],
              path.count > root.count else { return nil }
        let rel = String(path.dropFirst(root == "/" ? 1 : root.count + 1))
        if rel == ".git" { return nil }
        return status.mark(relativePath: rel, isFolder: isFolder)
    }

    func refresh(_ root: String) {
        guard !refreshing.contains(root) else {
            refreshAgain.insert(root)
            return
        }
        refreshing.insert(root)
        Task.detached(priority: .utility) {
            let output = GitRunner.git(["status", "--porcelain=v1", "-z", "--branch", "--ignored", "--untracked-files=normal"],
                                       in: root)
            let status = output.map { GitRepoStatus.parse($0, root: root) }
            await MainActor.run {
                self.refreshing.remove(root)
                if self.leases[root] != nil, self.statuses[root] != status {
                    self.statuses[root] = status
                    self.revision += 1
                }
                if self.refreshAgain.remove(root) != nil { self.refresh(root) }
            }
        }
    }

    /// Clears everything (Settings › 显示 Git 状态 switched off or on).
    func reset() {
        statuses = [:]
        roots = [:]
        revision += 1
    }

    /// `git diff` of one file against the last commit (staged and unstaged together).
    nonisolated static func diff(of url: URL, root: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let path = url.standardizedFileURL.path
            guard path.count > root.count else { return nil }
            let rel = String(path.dropFirst(root == "/" ? 1 : root.count + 1))
            return GitRunner.git(["diff", "--no-color", "--no-ext-diff", "HEAD", "--", rel], in: root, limit: 400_000)
                ?? GitRunner.git(["diff", "--no-color", "--no-ext-diff", "--cached", "--", rel], in: root, limit: 400_000)
        }.value
    }
}

/// Held by a tab while it shows a folder inside a repository.
final class GitLease: @unchecked Sendable {
    let root: String

    fileprivate init(root: String) { self.root = root }

    deinit {
        let root = self.root
        Task { @MainActor in GitIndex.shared.release(root) }
    }
}

/// Watches a whole repository (work tree and `.git`) and calls back, debounced, when it changes.
private final class RepoWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private var pending: DispatchWorkItem?

    init?(root: String, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            // Objects and logs change on every git command without changing what status says.
            let relevant = changed.prefix(count).contains { path in
                !path.contains("/.git/objects") && !path.contains("/.git/logs") && !path.contains("/node_modules/")
            }
            if relevant { watcher.schedule() }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    deinit {
        pending?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
