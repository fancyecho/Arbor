import Foundation

enum DirectoryLoader {
    private static let queue = DispatchQueue(label: "app.arbor.loader", qos: .userInitiated, attributes: .concurrent)

    /// Lists `url` off the main thread. Hidden files are always returned so the
    /// "show hidden" toggle can filter without hitting the disk again.
    static func load(_ url: URL, completion: @escaping (Result<[FileItem], Error>) -> Void) {
        queue.async {
            let result = Result {
                try FileManager.default
                    .contentsOfDirectory(at: url, includingPropertiesForKeys: FileItem.resourceKeys, options: [])
                    .map(FileItem.init(url:))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Recursively sums allocated file sizes on a background thread. Returns nil if cancelled.
    static func folderSize(_ url: URL) async -> Int64? {
        let flag = CancelFlag()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) { () -> Int64? in
                var total: Int64 = 0
                let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
                let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
                while let next = enumerator?.nextObject() as? URL {
                    if flag.isCancelled { return nil }
                    let values = try? next.resourceValues(forKeys: Set(keys))
                    if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
                }
                return total
            }.value
        } onCancel: {
            flag.cancel()
        }
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Watches a single directory with FSEvents and calls `onChange` (coalesced, on main)
/// only for changes to its direct children — not for the whole subtree.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let onChange: () -> Void

    init?(url: URL, onChange: @escaping () -> Void) {
        self.path = url.standardizedFileURL.resolvingSymlinksInPath().path
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let relevant = changed.prefix(count).contains { changedPath in
                changedPath == watcher.path
                    || (changedPath as NSString).deletingLastPathComponent == watcher.path
            }
            if relevant { watcher.onChange() }
        }

        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
            FSEventStreamCreateFlags(flags)
        ) else { return nil }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
