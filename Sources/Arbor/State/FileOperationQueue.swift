import AppKit
import Observation

/// One running or finished copy/move/duplicate job, shown in the operations popover.
@MainActor @Observable
final class FileTask: Identifiable {
    enum State: Equatable {
        case running, finished, cancelled
        case failed(String)
    }

    let id = UUID()
    let kind: TransferKind
    let title: String
    /// Folder the items go into; its tab shows this task's progress.
    let destination: URL
    let started = Date()
    let cancelFlag = CancelFlag()
    fileprivate(set) var progress = TransferProgress()
    fileprivate(set) var state: State = .running

    init(kind: TransferKind, title: String, destination: URL) {
        self.kind = kind
        self.title = title
        self.destination = destination
    }

    var fraction: Double? {
        guard progress.totalBytes > 0 else {
            return progress.itemsTotal > 0 ? Double(progress.itemsDone) / Double(progress.itemsTotal) : nil
        }
        return min(1, Double(progress.completedBytes) / Double(progress.totalBytes))
    }

    var detail: String {
        switch state {
        case .finished: return L("已完成")
        case .cancelled: return L("已停止")
        case .failed(let message): return message
        case .running:
            guard progress.totalBytes > 0 else { return L("\(progress.itemsDone) / \(progress.itemsTotal) 项") }
            var text = "\(Format.bytes(progress.completedBytes)) / \(Format.bytes(progress.totalBytes))"
            let elapsed = Date().timeIntervalSince(started)
            if elapsed > 2, progress.completedBytes > 0 {
                let rate = Double(progress.completedBytes) / elapsed
                let remaining = Double(progress.totalBytes - progress.completedBytes) / rate
                text += L(" · 剩余约 \(Self.duration(remaining))")
            }
            return text
        }
    }

    func cancel() { cancelFlag.cancel() }

    private static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return L("\(max(1, Int(seconds))) 秒") }
        if seconds < 3600 { return L("\(Int(seconds / 60)) 分钟") }
        return String(format: L("%.1f 小时"), seconds / 3600)
    }
}

/// Runs file jobs in the background, reports progress, resolves conflicts and records undo.
/// All completions are delivered on the main actor as `(createdURLs, error)`.
@MainActor @Observable
final class FileOperationQueue {
    static let shared = FileOperationQueue()

    private(set) var tasks: [FileTask] = []

    var activeCount: Int { tasks.filter { $0.state == .running }.count }

    /// Overall progress of running jobs, for the toolbar indicator.
    var overallFraction: Double? {
        let running = tasks.filter { $0.state == .running }
        let total = running.reduce(Int64(0)) { $0 + $1.progress.totalBytes }
        guard total > 0 else { return nil }
        return Double(running.reduce(Int64(0)) { $0 + $1.progress.completedBytes }) / Double(total)
    }

    typealias Completion = ([URL], Error?) -> Void

    func copy(_ sources: [URL], to destination: URL, completion: @escaping Completion = { _, _ in }) {
        start(.copy, sources, destination, completion)
    }

    /// Copies without asking: existing items are replaced (the old ones go to the Trash, so it's undoable).
    func copyReplacing(_ sources: [URL], to destination: URL, completion: @escaping Completion = { _, _ in }) {
        start(.copy, sources, destination, completion, policy: .replace)
    }

    func move(_ sources: [URL], to destination: URL, completion: @escaping Completion = { _, _ in }) {
        start(.move, sources, destination, completion)
    }

    func duplicate(_ sources: [URL], completion: @escaping Completion = { _, _ in }) {
        guard let parent = sources.first?.deletingLastPathComponent() else { return }
        start(.duplicate, sources, parent, completion)
    }

    /// Finder drop semantics: move within a volume, copy across volumes (or when `forceCopy`).
    func transfer(_ sources: [URL], to destination: URL, forceCopy: Bool = false, completion: @escaping Completion = { _, _ in }) {
        if !forceCopy, FileOperations.isSameVolume(sources, destination) {
            move(sources, to: destination, completion: completion)
        } else {
            copy(sources, to: destination, completion: completion)
        }
    }

    /// Moves items to the Trash (with "Put Back" support) and records undo.
    func trash(_ urls: [URL], completion: @escaping (Error?) -> Void = { _ in }) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls) { trashed, error in
            Task { @MainActor in
                let steps = trashed.map { UndoStep.move(from: $0.value, to: $0.key) }
                FileHistory.shared.record(L("移到废纸篓"), steps: steps)
                completion(error)
            }
        }
    }

    /// The newest task copying/moving into `folder`, for the progress shown on its tab.
    func task(into folder: URL) -> FileTask? {
        tasks.last { $0.destination.isSameFile(as: folder) }
    }

    func clearFinished() {
        tasks.removeAll { $0.state != .running }
    }

    private func start(_ kind: TransferKind, _ sources: [URL], _ destination: URL, _ completion: @escaping Completion,
                       policy: ConflictChoice? = nil) {
        guard !sources.isEmpty else { return }
        let folder = FileManager.default.displayName(atPath: destination.path)
        let what = sources.count == 1 ? "“\(sources[0].lastPathComponent)”" : L("\(sources.count) 个项目")
        let title = kind == .duplicate ? L("复制\(what)") : L("\(kind.verb)\(what)到“\(folder)”")
        let task = FileTask(kind: kind, title: title, destination: destination)
        tasks.append(task)

        let engine = TransferEngine(
            kind: kind, sources: sources, destination: destination, cancelFlag: task.cancelFlag,
            askConflict: { info in
                if let policy { return (policy, true) }
                return await ConflictResolver.ask(info)
            },
            report: { progress in Task { @MainActor in task.progress = progress } })

        Task.detached(priority: .userInitiated) {
            let result = await engine.run()
            await MainActor.run {
                FileHistory.shared.record(kind == .duplicate ? L("复制\(what)") : L("\(kind.verb)\(what)"), steps: result.undoSteps)
                if let error = result.error {
                    task.state = .failed(error.localizedDescription)
                } else {
                    task.state = result.cancelled ? .cancelled : .finished
                }
                completion(result.created, result.error)
                self.scheduleCleanup(task)
            }
        }
    }

    /// Finished jobs linger briefly so the popover can show them; failures stay until cleared.
    private func scheduleCleanup(_ task: FileTask) {
        guard task.state == .finished || task.state == .cancelled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.tasks.removeAll { $0.id == task.id }
        }
    }
}
