import Foundation
import Observation

/// A primitive file-system change used to revert an operation.
/// Running a list of steps yields the list that reverts *them*, which is how redo works.
enum UndoStep: Equatable, Sendable {
    /// Move the item currently at `from` to `to`.
    case move(from: URL, to: URL)
    /// Move the item to the Trash.
    case trash(URL)
}

struct UndoEntry: Sendable {
    /// Describes the original operation, e.g. "移动 3 个项目". Menus prefix it with 撤销/重做.
    let title: String
    let steps: [UndoStep]
}

enum UndoError: LocalizedError {
    case occupied(String)

    var errorDescription: String? {
        switch self {
        case .occupied(let name): "无法撤销：“\(name)”所在位置已有同名项目。"
        }
    }
}

enum UndoExecutor {
    /// Performs `steps` in order and returns the steps that revert them. If a step fails,
    /// the steps already performed are rolled back before the error is rethrown.
    /// Items that no longer exist are skipped (the user may have deleted them since).
    static func perform(_ steps: [UndoStep]) throws -> [UndoStep] {
        let fm = FileManager.default
        var inverse: [UndoStep] = []
        do {
            for step in steps {
                switch step {
                case .move(let from, let to):
                    guard fm.fileExists(atPath: from.path) || isSymlink(from) else { continue }
                    let caseOnly = from.path.lowercased() == to.path.lowercased()
                    if !caseOnly, fm.fileExists(atPath: to.path) { throw UndoError.occupied(to.lastPathComponent) }
                    try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: from, to: to)
                    inverse.insert(.move(from: to, to: from), at: 0)
                case .trash(let url):
                    guard fm.fileExists(atPath: url.path) || isSymlink(url) else { continue }
                    var resulting: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &resulting)
                    if let trashed = resulting as URL? { inverse.insert(.move(from: trashed, to: url), at: 0) }
                }
            }
        } catch {
            _ = try? perform(inverse)
            throw error
        }
        return inverse
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// Steps that reverse a batch of renames, routed through temporary names so swaps (a↔b) work.
    static func renameSteps(_ pairs: [(from: URL, to: URL)]) -> [UndoStep] {
        let changed = pairs.filter { !$0.from.isSameFile(as: $0.to) }
        guard changed.count > 1 else { return changed.map { .move(from: $0.to, to: $0.from) } }
        let staged = changed.map { pair in
            (pair, pair.to.deletingLastPathComponent().appendingPathComponent(".arbor-undo-\(UUID().uuidString)"))
        }
        return staged.map { .move(from: $0.0.to, to: $0.1) } + staged.map { .move(from: $0.1, to: $0.0.from) }
    }
}

/// App-wide undo/redo for file operations (files are shared by all windows, as in Finder).
@MainActor @Observable
final class FileHistory {
    static let shared = FileHistory()

    private(set) var undoStack: [UndoEntry] = []
    private(set) var redoStack: [UndoEntry] = []
    private(set) var isBusy = false

    private let limit = 100

    var undoTitle: String? { undoStack.last?.title }
    var redoTitle: String? { redoStack.last?.title }

    func record(_ title: String, steps: [UndoStep]) {
        guard !steps.isEmpty else { return }
        undoStack.append(UndoEntry(title: title, steps: steps))
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    /// Reverts the latest operation. `completion` receives the URLs that now exist again.
    func undo(completion: @escaping ([URL], Error?) -> Void) {
        guard !isBusy, let entry = undoStack.popLast() else { return }
        run(entry, completion: completion) { [weak self] inverse in
            self?.redoStack.append(inverse)
        } onFailure: { [weak self] in
            self?.undoStack.append(entry)
        }
    }

    func redo(completion: @escaping ([URL], Error?) -> Void) {
        guard !isBusy, let entry = redoStack.popLast() else { return }
        run(entry, completion: completion) { [weak self] inverse in
            self?.undoStack.append(inverse)
        } onFailure: { [weak self] in
            self?.redoStack.append(entry)
        }
    }

    private func run(_ entry: UndoEntry, completion: @escaping ([URL], Error?) -> Void,
                     onSuccess: @escaping (UndoEntry) -> Void, onFailure: @escaping () -> Void) {
        isBusy = true
        let steps = entry.steps
        Task.detached(priority: .userInitiated) {
            let result = Result { try UndoExecutor.perform(steps) }
            await MainActor.run {
                self.isBusy = false
                switch result {
                case .success(let inverse):
                    onSuccess(UndoEntry(title: entry.title, steps: inverse))
                    let restored = steps.compactMap { step -> URL? in
                        if case .move(_, let to) = step, !to.lastPathComponent.hasPrefix(".arbor-undo-") { return to }
                        return nil
                    }
                    completion(restored, nil)
                case .failure(let error):
                    onFailure()
                    completion([], error)
                }
            }
        }
    }
}
