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

/// Watches a directory subtree with one FSEventStream and delivers coalesced directory changes on main.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let onDirectoriesChanged: (Set<String>) -> Void

    /// Convenience initializer that fires only when `url`'s direct children change.
    convenience init?(url: URL, onChange: @escaping () -> Void) {
        let watched = url.standardizedFileURL.resolvingSymlinksInPath().path
        self.init(root: url) { changed in
            if changed.contains(watched) { onChange() }
        }
    }

    /// Watches `root` and its whole subtree with a single FSEventStream, reporting the standardized paths
    /// of directories whose direct children (or the directory itself) changed.
    init?(root url: URL, onDirectoriesChanged: @escaping (Set<String>) -> Void) {
        self.path = url.standardizedFileURL.resolvingSymlinksInPath().path
        self.onDirectoriesChanged = onDirectoriesChanged
        var context = FSEventStreamContext(
            version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var affected = Set<String>()
            for changedPath in changed.prefix(count) {
                affected.insert(changedPath)
                affected.insert((changedPath as NSString).deletingLastPathComponent)
            }
            if !affected.isEmpty { watcher.onDirectoriesChanged(affected) }
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

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit {
        stop()
    }
}
