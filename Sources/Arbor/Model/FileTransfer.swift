import Darwin
import Foundation

enum TransferKind: Sendable {
    case copy, move, duplicate

    var verb: String {
        switch self {
        case .copy: L("拷贝")
        case .move: L("移动")
        case .duplicate: L("复制")
        }
    }

    func failure(_ name: String, _ reason: String) -> String {
        switch self {
        case .copy: L("无法拷贝“\(name)”：\(reason)")
        case .move: L("无法移动“\(name)”：\(reason)")
        case .duplicate: L("无法复制“\(name)”：\(reason)")
        }
    }
}

enum ConflictChoice: Sendable {
    case keepBoth, replace, skip, merge, stop
}

struct ConflictInfo: Sendable {
    let source: URL
    let existing: URL
    let bothDirectories: Bool
    /// Conflicts may still follow; lets the dialog offer "apply to all".
    let hasMoreItems: Bool
}

struct TransferProgress: Sendable, Equatable {
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var itemsDone = 0
    var itemsTotal = 0
    var currentName = ""
}

struct TransferResult: Sendable {
    /// Top-level items now at the destination (for selecting them afterwards).
    var created: [URL] = []
    /// Steps that revert everything that was done, in the order they must run.
    var undoSteps: [UndoStep] = []
    var error: Error?
    var cancelled = false
}

/// Runs one copy/move/duplicate job off the main thread. Not reusable.
final class TransferEngine: @unchecked Sendable {
    typealias ConflictHandler = @Sendable (ConflictInfo) async -> (ConflictChoice, applyToAll: Bool)

    private let kind: TransferKind
    private let sources: [URL]
    private let destination: URL
    private let cancelFlag: CancelFlag
    private let askConflict: ConflictHandler
    private let report: @Sendable (TransferProgress) -> Void

    private let fm = FileManager.default
    private var progress = TransferProgress()
    private var lastReport = Date.distantPast
    private var stickyChoice: ConflictChoice?
    private var stickyMergeChoice: ConflictChoice?
    private var undo: [UndoStep] = []

    init(kind: TransferKind, sources: [URL], destination: URL, cancelFlag: CancelFlag,
         askConflict: @escaping ConflictHandler, report: @escaping @Sendable (TransferProgress) -> Void) {
        self.kind = kind
        self.sources = sources
        self.destination = destination
        self.cancelFlag = cancelFlag
        self.askConflict = askConflict
        self.report = report
    }

    func run() async -> TransferResult {
        var result = TransferResult()
        let jobs = plannedJobs()
        progress.itemsTotal = jobs.count
        progress.totalBytes = jobs.reduce(0) { $0 + ($1.needsCopy ? Self.byteCount(of: $1.source) : 0) }
        flush(force: true)

        for (index, job) in jobs.enumerated() {
            if cancelFlag.isCancelled { result.cancelled = true; break }
            progress.currentName = job.source.lastPathComponent
            flush(force: true)
            do {
                if let created = try await perform(job, hasMoreItems: index < jobs.count - 1) {
                    result.created.append(created)
                }
            } catch TransferStop.stopped {
                result.cancelled = true
                break
            } catch {
                if cancelFlag.isCancelled { result.cancelled = true } else { result.error = error }
                break
            }
            progress.itemsDone += 1
            flush(force: true)
        }
        result.undoSteps = undo
        return result
    }

    // MARK: Planning

    private struct Job {
        let source: URL
        let target: URL
        /// False for same-volume moves, which are instant renames.
        let needsCopy: Bool
    }

    private enum TransferStop: Error { case stopped }

    private func plannedJobs() -> [Job] {
        sources.compactMap { source in
            let parent = kind == .duplicate ? source.deletingLastPathComponent() : destination
            // Moving into the folder it already lives in does nothing.
            if kind == .move, source.deletingLastPathComponent().isSameFile(as: parent) { return nil }
            // A folder can't go inside itself.
            if parent.isSameFile(as: source) || parent.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/") {
                return nil
            }
            let name: String
            if kind == .duplicate {
                // Folders keep their whole name ("v1.2 副本"); files and packages keep the extension ("App 副本.app").
                let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                let plainFolder = values?.isDirectory == true && values?.isPackage != true
                let ext = source.pathExtension
                let base = source.deletingPathExtension().lastPathComponent
                name = ext.isEmpty || plainFolder ? L("\(source.lastPathComponent) 副本") : L("\(base) 副本.\(ext)")
            } else {
                name = source.lastPathComponent
            }
            let needsCopy = kind != .move || !FileOperations.isSameVolume([source], parent)
            return Job(source: source, target: parent.appendingPathComponent(name), needsCopy: needsCopy)
        }
    }

    // MARK: Execution

    /// Returns the URL the item ended up at, or nil if it was skipped.
    private func perform(_ job: Job, hasMoreItems: Bool) async throws -> URL? {
        var target = job.target

        if exists(target) {
            // Copying into the same folder (or duplicating) silently picks a free name, like Finder.
            let sameFolder = job.source.deletingLastPathComponent().isSameFile(as: target.deletingLastPathComponent())
            let choice: ConflictChoice
            if kind == .duplicate || (kind == .copy && sameFolder) {
                choice = .keepBoth
            } else {
                choice = try await resolve(source: job.source, existing: target, hasMoreItems: hasMoreItems, nested: false)
            }
            switch choice {
            case .skip:
                progress.completedBytes += job.needsCopy ? Self.byteCount(of: job.source) : 0
                return nil
            case .stop:
                throw TransferStop.stopped
            case .keepBoth:
                target = FileOperations.uniqueURL(for: target.lastPathComponent, in: target.deletingLastPathComponent())
            case .replace:
                try trashExisting(target)
            case .merge:
                try await merge(job.source, into: target, needsCopy: job.needsCopy)
                return target
            }
        }

        try transfer(job.source, to: target, needsCopy: job.needsCopy)
        return target
    }

    private func resolve(source: URL, existing: URL, hasMoreItems: Bool, nested: Bool) async throws -> ConflictChoice {
        let bothDirectories = isDirectory(source) && isDirectory(existing)
        if source.isSameFile(as: existing) { return .keepBoth }
        if let sticky = nested ? stickyMergeChoice : stickyChoice {
            if sticky == .merge && !bothDirectories { /* fall through to ask */ } else { return sticky }
        }
        flush(force: true)
        let (choice, applyToAll) = await askConflict(ConflictInfo(
            source: source, existing: existing, bothDirectories: bothDirectories, hasMoreItems: hasMoreItems || nested))
        if cancelFlag.isCancelled { throw TransferStop.stopped }
        if applyToAll {
            if nested { stickyMergeChoice = choice } else { stickyChoice = choice }
        }
        return choice
    }

    /// Puts `source`'s children into the existing folder `target`, asking about nested conflicts.
    private func merge(_ source: URL, into target: URL, needsCopy: Bool) async throws {
        let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        for child in children {
            if cancelFlag.isCancelled { throw TransferStop.stopped }
            var childTarget = target.appendingPathComponent(child.lastPathComponent)
            if exists(childTarget) {
                switch try await resolve(source: child, existing: childTarget, hasMoreItems: true, nested: true) {
                case .skip: continue
                case .stop: throw TransferStop.stopped
                case .keepBoth: childTarget = FileOperations.uniqueURL(for: child.lastPathComponent, in: target)
                case .replace: try trashExisting(childTarget)
                case .merge:
                    try await merge(child, into: childTarget, needsCopy: needsCopy)
                    continue
                }
            }
            try transfer(child, to: childTarget, needsCopy: needsCopy)
        }
        // A merged move leaves an empty source folder behind; remove it (undo recreates it).
        if kind == .move, (try? fm.contentsOfDirectory(atPath: source.path))?.isEmpty == true {
            try? fm.removeItem(at: source)
        }
    }

    private func transfer(_ source: URL, to target: URL, needsCopy: Bool) throws {
        if kind == .move && !needsCopy {
            try fm.moveItem(at: source, to: target)
            undo.insert(.move(from: target, to: source), at: 0)
            return
        }
        try copyWithProgress(source, to: target)
        if kind == .move {
            try fm.removeItem(at: source)
            undo.insert(.move(from: target, to: source), at: 0)
        } else {
            undo.insert(.trash(target), at: 0)
        }
    }

    private func trashExisting(_ url: URL) throws {
        var resulting: NSURL?
        try fm.trashItem(at: url, resultingItemURL: &resulting)
        if let trashed = resulting as URL? { undo.insert(.move(from: trashed, to: url), at: 0) }
    }

    // MARK: copyfile with progress

    private func copyWithProgress(_ source: URL, to target: URL) throws {
        let baseline = progress.completedBytes
        let expected = Self.byteCount(of: source)
        let context = CopyContext(cancelFlag: cancelFlag) { [weak self] copied in
            guard let self else { return }
            self.progress.completedBytes = baseline + copied
            self.flush(force: false)
        }
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(copyfileCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())

        var flags = copyfile_flags_t(COPYFILE_ALL) | copyfile_flags_t(COPYFILE_NOFOLLOW_SRC) | copyfile_flags_t(COPYFILE_CLONE)
        if isDirectory(source) { flags |= copyfile_flags_t(COPYFILE_RECURSIVE) }

        let status = withExtendedLifetime(context) { copyfile(source.path, target.path, state, flags) }
        if status != 0 {
            let code = errno
            try? fm.removeItem(at: target) // never leave a half-copied item behind
            if cancelFlag.isCancelled { throw TransferStop.stopped }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: kind.failure(source.lastPathComponent, String(cString: strerror(code))),
            ])
        }
        progress.completedBytes = baseline + expected
    }

    // MARK: Helpers

    private func flush(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) > 0.1 else { return }
        lastReport = now
        report(progress)
    }

    private func exists(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.path)
            || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    /// Logical size of a file or folder tree, matching what copyfile reports as copied.
    static func byteCount(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        let values = try? url.resourceValues(forKeys: keys)
        if values?.isDirectory != true || values?.isSymbolicLink == true { return Int64(values?.fileSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
                                                        errorHandler: { _, _ in true })
        while let next = enumerator?.nextObject() as? URL {
            let child = try? next.resourceValues(forKeys: keys)
            if child?.isRegularFile == true { total += Int64(child?.fileSize ?? 0) }
        }
        return total
    }
}

// MARK: - copyfile callback

private final class CopyContext {
    let cancelFlag: CancelFlag
    let onBytes: (Int64) -> Void
    /// Bytes of files already finished inside a recursive copy.
    var finishedBytes: Int64 = 0
    var currentFileBytes: Int64 = 0

    init(cancelFlag: CancelFlag, onBytes: @escaping (Int64) -> Void) {
        self.cancelFlag = cancelFlag
        self.onBytes = onBytes
    }
}

private let copyfileCallback: copyfile_callback_t = { what, stage, state, _, _, ctx in
    guard let ctx else { return COPYFILE_CONTINUE }
    let context = Unmanaged<CopyContext>.fromOpaque(ctx).takeUnretainedValue()
    if context.cancelFlag.isCancelled { return COPYFILE_QUIT }

    if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
        var copied: off_t = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
        context.currentFileBytes = Int64(copied)
        context.onBytes(context.finishedBytes + context.currentFileBytes)
    } else if what == COPYFILE_RECURSE_FILE, stage == COPYFILE_FINISH {
        context.finishedBytes += context.currentFileBytes
        context.currentFileBytes = 0
    } else if what == COPYFILE_RECURSE_ERROR || stage == COPYFILE_ERR {
        return COPYFILE_QUIT
    }
    return COPYFILE_CONTINUE
}
