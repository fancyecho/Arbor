import Darwin
import Foundation

// MARK: - Categories

/// What kind of thing is taking the space. Decided by extension, or by the folder a file lives in
/// (everything inside an .app is "应用", inside Caches is "缓存", inside node_modules is "开发").
enum FileCategory: Int, CaseIterable, Sendable {
    case video, image, audio, document, app, developer, archive, cache, other

    var title: String {
        switch self {
        case .video: "视频"
        case .image: "图片"
        case .audio: "音频"
        case .document: "文档"
        case .app: "应用"
        case .developer: "开发"
        case .archive: "映像与虚拟机"
        case .cache: "缓存与日志"
        case .other: "其他"
        }
    }

    var symbol: String {
        switch self {
        case .video: "film"
        case .image: "photo"
        case .audio: "music.note"
        case .document: "doc.text"
        case .app: "app.dashed"
        case .developer: "hammer"
        case .archive: "shippingbox"
        case .cache: "clock.arrow.circlepath"
        case .other: "square.dashed"
        }
    }

    private static let byExtension: [String: FileCategory] = {
        var map: [String: FileCategory] = [:]
        func add(_ category: FileCategory, _ list: String) {
            for ext in list.split(separator: " ") { map[String(ext)] = category }
        }
        add(.video, "mp4 mov m4v mkv avi wmv flv webm mpg mpeg 3gp mts m2ts vob braw r3d prores")
        add(.image, "jpg jpeg png heic heif gif tif tiff bmp webp raw cr2 cr3 nef arw dng orf rw2 raf psd psb ai svg ico icns exr hdr avif sketch fig xcf")
        add(.audio, "mp3 m4a aac flac wav aif aiff ogg opus alac caf mid midi m4r wma ape logicx band")
        add(.document, "pdf doc docx xls xlsx ppt pptx pages numbers key txt rtf md markdown csv tsv epub mobi odt ods odp tex")
        add(.archive, "zip rar 7z tar gz tgz bz2 xz zst lz4 dmg iso img pkg mpkg ipa xip apk sparseimage sparsebundle hdd hds vmdk vdi vhd vhdx qcow2 raw nvram vmem vmsn ova ovf")
        add(.developer, "swift m mm h hpp c cc cpp rs go py rb js mjs ts tsx jsx java kt class jar o a dylib so dSYM pch swiftmodule pyc wasm map lock gradle xcarchive")
        add(.cache, "log cache tmp temp crash ips diag")
        return map
    }()

    /// Packages that are opened as one thing: their size counts as one item in the chart.
    static let packageExtensions: Set<String> = [
        "app", "appex", "framework", "bundle", "plugin", "kext", "xpc", "photoslibrary", "musiclibrary",
        "imovielibrary", "fcpbundle", "logicx", "band", "pages", "numbers", "key", "rtfd", "xcarchive",
        "sparsebundle", "photolibrary", "aplibrary", "lrlibrary", "tvlibrary", "playground", "docset",
        "pvm", "utm", "vmwarevm", "pvmp", "vbox",
    ]

    static func forExtension(_ ext: String) -> FileCategory? {
        byExtension[ext.lowercased()]
    }

    /// Folders whose whole contents count as one category.
    static func folderOverride(_ name: String) -> FileCategory? {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "app", "appex", "framework", "plugin", "kext", "xpc", "bundle": return .app
        case "photoslibrary", "photolibrary", "aplibrary", "lrlibrary": return .image
        case "imovielibrary", "fcpbundle", "tvlibrary": return .video
        case "musiclibrary", "logicx", "band": return .audio
        case "xcarchive", "docset", "playground": return .developer
        case "sparsebundle", "pvm", "utm", "vmwarevm", "pvmp", "vbox": return .archive
        default: break
        }
        switch name {
        case "Caches", "Cache", "CachedData", "Code Cache", "GPUCache", "ShaderCache", "Logs", "logs",
             "DiagnosticReports", ".cache", "tmp", "Temp", "Crashpad", "Service Worker":
            return .cache
        case "DerivedData", "node_modules", ".git", "Pods", ".gradle", ".npm", ".pnpm-store", ".cargo", ".rustup",
             "CoreSimulator", "Archives", ".build", "__pycache__", ".venv", "venv", ".m2", "iOS DeviceSupport":
            return .developer
        default:
            return nil
        }
    }
}

// MARK: - Tree

/// One folder or file in a scanned tree. Built off the main thread, then only touched on main.
final class SpaceNode: Identifiable, @unchecked Sendable {
    enum Kind: UInt8 { case folder, package, file, smallFiles, unreadable, hidden }

    let name: String
    let kind: Kind
    /// Allocated bytes on disk.
    var size: Int64
    /// Files underneath (for a file: 1; for the small-files group: how many it stands for).
    var fileCount: Int
    /// Largest first.
    var children: [SpaceNode]
    weak var parent: SpaceNode?
    /// Bytes per FileCategory (containers only).
    var categories: [Int64]
    /// A file's category (containers: the category it was forced to, if any).
    let category: FileCategory

    init(name: String, kind: Kind, size: Int64, fileCount: Int, children: [SpaceNode] = [],
         categories: [Int64] = [], category: FileCategory = .other) {
        self.name = name
        self.kind = kind
        self.size = size
        self.fileCount = fileCount
        self.children = children
        self.categories = categories
        self.category = category
        for child in children { child.parent = self }
    }

    var isContainer: Bool { kind == .folder || kind == .package || kind == .unreadable }
    /// Something you can step into in the chart and the pane.
    var isBrowsable: Bool { kind == .folder || kind == .package }
    /// A real item on disk (not the "small files" group or the volume's unaccounted space).
    var isItem: Bool { kind != .smallFiles && kind != .hidden }

    var dominantCategory: FileCategory {
        guard isContainer, !categories.isEmpty else { return category }
        let index = categories.indices.max { categories[$0] < categories[$1] } ?? FileCategory.other.rawValue
        return categories[index] > 0 ? FileCategory(rawValue: index) ?? .other : category
    }

    /// Names from the scan root down to this node (the root itself contributes nothing).
    var components: [String] {
        var names: [String] = []
        var node: SpaceNode? = self
        while let current = node, let parent = current.parent {
            names.append(current.name)
            node = parent
        }
        return names.reversed()
    }

    func child(named name: String) -> SpaceNode? {
        children.first { $0.name == name && $0.isItem }
    }

    func isDescendant(of other: SpaceNode) -> Bool {
        var node = parent
        while let current = node {
            if current === other { return true }
            node = current.parent
        }
        return false
    }

    /// Re-sorts children after a size change (largest first, groups last among equals).
    func sortChildren() {
        children.sort { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }
    }

    /// The `limit` largest files at or below this node.
    func largestFiles(limit: Int) -> [SpaceNode] {
        var result: [SpaceNode] = []
        var floor: Int64 = 0
        func visit(_ node: SpaceNode) {
            for child in node.children {
                if child.kind == .file {
                    guard result.count < limit || child.size > floor else { continue }
                    let index = result.firstIndex { $0.size < child.size } ?? result.count
                    result.insert(child, at: index)
                    if result.count > limit { result.removeLast() }
                    floor = result.count == limit ? result.last?.size ?? 0 : 0
                } else if child.isContainer, child.size > floor || result.count < limit {
                    visit(child)
                }
            }
        }
        if kind == .file { return [self] }
        visit(self)
        return result
    }
}

// MARK: - Scanning

/// Counters shared by the scanning threads.
final class ScanCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var items = 0
    private var unreadable = 0
    private var seenLinks = Set<DevIno>()
    let cancel = CancelFlag()

    struct DevIno: Hashable { let dev: Int32; let ino: UInt64 }

    func add(bytes: Int64, items: Int) {
        lock.withLock {
            self.bytes += bytes
            self.items += items
        }
    }

    func addUnreadable() { lock.withLock { unreadable += 1 } }

    /// Hard-linked files are counted once (the first time any of their names is seen).
    func firstSighting(_ key: DevIno) -> Bool {
        lock.withLock { seenLinks.insert(key).inserted }
    }

    var snapshot: (bytes: Int64, items: Int, unreadable: Int) {
        lock.withLock { (bytes, items, unreadable) }
    }
}

enum SpaceScanner {
    /// Files kept as their own node per folder; the rest become one "small files" group.
    static let keptFilesPerFolder = 30
    /// Files at least this big are always kept, however many there are.
    static let alwaysKeepSize: Int64 = 1 << 20

    /// Collects one folder's contents while it is being walked.
    final class FolderBuilder {
        let name: String
        let kind: SpaceNode.Kind
        let forced: FileCategory?
        /// fts level of the folder (walks only), to match an "unreadable" report to the folder it follows.
        var level = -1
        var folders: [SpaceNode] = []
        var files: [(name: String, size: Int64, category: FileCategory)] = []
        var ownSize: Int64 = 0

        init(name: String, kind: SpaceNode.Kind, forced: FileCategory?) {
            self.name = name
            self.kind = kind
            self.forced = forced
        }

        func addFile(name: String, size: Int64) {
            let ext = (name as NSString).pathExtension
            let category = forced ?? FileCategory.forExtension(ext) ?? .other
            files.append((name, size, category))
        }

        func finish() -> SpaceNode {
            var categories = [Int64](repeating: 0, count: FileCategory.allCases.count)
            var size = ownSize
            var count = 0
            categories[(forced ?? .other).rawValue] += ownSize
            for folder in folders {
                size += folder.size
                count += folder.fileCount
                for index in categories.indices where index < folder.categories.count {
                    categories[index] += folder.categories[index]
                }
            }
            files.sort { $0.size > $1.size }
            var children = folders
            var smallSize: Int64 = 0
            var smallCount = 0
            var smallCategories = [Int64](repeating: 0, count: categories.count)
            for (index, file) in files.enumerated() {
                size += file.size
                count += 1
                categories[file.category.rawValue] += file.size
                if index < SpaceScanner.keptFilesPerFolder || file.size >= SpaceScanner.alwaysKeepSize {
                    children.append(SpaceNode(name: file.name, kind: .file, size: file.size, fileCount: 1,
                                              category: file.category))
                } else {
                    smallSize += file.size
                    smallCount += 1
                    smallCategories[file.category.rawValue] += file.size
                }
            }
            if smallCount > 0 {
                children.append(SpaceNode(name: "\(smallCount) 个更小的文件", kind: .smallFiles, size: smallSize,
                                          fileCount: smallCount, categories: smallCategories))
            }
            children.sort { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }
            return SpaceNode(name: name, kind: kind, size: size, fileCount: count, children: children,
                             categories: categories, category: forced ?? .other)
        }
    }

    static func kind(forFolder name: String) -> SpaceNode.Kind {
        packageExtension(name) ? .package : .folder
    }

    static func packageExtension(_ name: String) -> Bool {
        FileCategory.packageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Scans `path`, splitting the first `parallelDepth` levels into concurrent tasks and walking
    /// deeper levels with fts (fast, no per-file allocations beyond what we keep).
    static func scanFolder(path: String, name: String, forced: FileCategory?, depth: Int, parallelDepth: Int,
                           device: Int32, counters: ScanCounters) async -> SpaceNode? {
        if counters.cancel.isCancelled { return nil }
        let forced = FileCategory.folderOverride(name) ?? forced
        guard depth < parallelDepth else {
            return walk(path: path, name: name, forced: forced, counters: counters)
        }
        let builder = FolderBuilder(name: name, kind: kind(forFolder: name), forced: forced)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            counters.addUnreadable()
            return SpaceNode(name: name, kind: .unreadable, size: 0, fileCount: 0,
                             categories: [Int64](repeating: 0, count: FileCategory.allCases.count))
        }
        var folders: [String] = []
        var filesSize: Int64 = 0
        for entry in entries {
            var info = stat()
            let full = path == "/" ? "/" + entry : path + "/" + entry
            guard lstat(full, &info) == 0 else { continue }
            if (info.st_mode & S_IFMT) == S_IFDIR {
                if info.st_dev == device { folders.append(entry) }
            } else {
                let size = allocated(info, counters: counters)
                builder.addFile(name: entry, size: size)
                filesSize += size
            }
        }
        counters.add(bytes: filesSize, items: entries.count - folders.count)
        await withTaskGroup(of: SpaceNode?.self) { group in
            for folder in folders {
                let child = path == "/" ? "/" + folder : path + "/" + folder
                group.addTask {
                    await scanFolder(path: child, name: folder, forced: forced, depth: depth + 1,
                                     parallelDepth: parallelDepth, device: device, counters: counters)
                }
            }
            for await node in group {
                if let node { builder.folders.append(node) }
            }
        }
        if counters.cancel.isCancelled { return nil }
        return builder.finish()
    }

    static func allocated(_ info: stat, counters: ScanCounters) -> Int64 {
        if info.st_nlink > 1, (info.st_mode & S_IFMT) != S_IFDIR,
           !counters.firstSighting(.init(dev: info.st_dev, ino: info.st_ino)) {
            return 0
        }
        return Int64(info.st_blocks) * 512
    }

    private static let nameOffset = MemoryLayout<FTSENT>.offset(of: \FTSENT.fts_name)!

    /// Walks a whole subtree on the calling thread.
    static func walk(path: String, name: String, forced: FileCategory?, counters: ScanCounters) -> SpaceNode? {
        guard let cPath = strdup(path) else { return nil }
        defer { free(cPath) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return nil }
        defer { fts_close(fts) }

        var stack: [FolderBuilder] = []
        var result: SpaceNode?
        var pendingBytes: Int64 = 0
        var pendingItems = 0
        var visited = 0

        while let entry = fts_read(fts) {
            visited += 1
            if visited & 511 == 0 {
                counters.add(bytes: pendingBytes, items: pendingItems)
                pendingBytes = 0
                pendingItems = 0
                if counters.cancel.isCancelled { return nil }
            }
            let level = Int(entry.pointee.fts_level)
            let entryName = level == 0
                ? name
                : String(cString: UnsafeRawPointer(entry).advanced(by: nameOffset).assumingMemoryBound(to: CChar.self))
            switch Int32(entry.pointee.fts_info) {
            case FTS_D:
                let forcedHere = FileCategory.folderOverride(entryName) ?? stack.last?.forced ?? forced
                let builder = FolderBuilder(name: entryName, kind: kind(forFolder: entryName), forced: forcedHere)
                builder.level = level
                if let info = entry.pointee.fts_statp?.pointee { builder.ownSize = Int64(info.st_blocks) * 512 }
                pendingBytes += builder.ownSize
                stack.append(builder)
            case FTS_DP:
                guard let builder = stack.popLast() else { continue }
                let node = builder.finish()
                if let parent = stack.last { parent.folders.append(node) } else { result = node }
            case FTS_DNR, FTS_ERR:
                counters.addUnreadable()
                // A folder that can't be read is reported twice: entered (FTS_D), then this — with no FTS_DP.
                // Replace the folder we just entered rather than leaving it open on the stack.
                var ownSize: Int64 = 0
                if let last = stack.last, last.level == level, last.name == entryName {
                    ownSize = last.ownSize
                    stack.removeLast()
                }
                var categories = [Int64](repeating: 0, count: FileCategory.allCases.count)
                categories[FileCategory.other.rawValue] = ownSize
                let node = SpaceNode(name: entryName, kind: .unreadable, size: ownSize, fileCount: 0,
                                     categories: categories)
                if let parent = stack.last { parent.folders.append(node) } else { result = node }
            case FTS_DC, FTS_DOT:
                continue
            case FTS_NS:
                counters.addUnreadable()
            default:
                // Files, symlinks, sockets…
                guard let info = entry.pointee.fts_statp?.pointee, let parent = stack.last else { continue }
                let size = allocated(info, counters: counters)
                parent.addFile(name: entryName, size: size)
                pendingBytes += size
                pendingItems += 1
            }
        }
        counters.add(bytes: pendingBytes, items: pendingItems)
        if !stack.isEmpty {
            // fts gave up part-way (an error it can't step over): keep everything walked so far instead
            // of losing the whole subtree, and count the rest as unreadable.
            if ProcessInfo.processInfo.environment["ARBOR_SCAN_DEBUG"] != nil {
                NSLog("fts stopped early in %@: errno %d", path, errno)
            }
            counters.addUnreadable()
            while let builder = stack.popLast() {
                let node = builder.finish()
                if let parent = stack.last { parent.folders.append(node) } else { result = node }
            }
        }
        return result
    }
}

// MARK: - A scan of one folder or disk

@MainActor @Observable
final class SpaceScan: Identifiable {
    enum Phase: Equatable {
        case scanning
        case finished(seconds: Double)
        case cancelled
        case failed(String)
    }

    struct Volume: Equatable {
        var name: String
        var total: Int64
        var available: Int64
        var purgeable: Int64
        var used: Int64 { max(total - available, 0) }
    }

    let id = UUID()
    /// What the user asked to scan, e.g. "/" for the startup disk.
    let rootURL: URL
    /// What is actually walked: the startup disk's data volume instead of "/".
    let scanPath: String
    private(set) var root: SpaceNode
    private(set) var phase: Phase = .scanning
    private(set) var scannedBytes: Int64 = 0
    private(set) var scannedItems = 0
    private(set) var unreadableFolders = 0
    /// Set when the scan covers a whole volume.
    private(set) var volume: Volume?
    /// Bumped whenever the tree changes, so views that cache layouts recompute.
    private(set) var revision = 0
    /// Folders being re-scanned in place (the old numbers stay until the new ones arrive).
    private(set) var refreshing = 0

    @ObservationIgnored private let counters = ScanCounters()
    @ObservationIgnored private var poller: Timer?
    @ObservationIgnored private let started = Date()
    @ObservationIgnored private var pendingFolders = 0

    static let dataVolume = "/System/Volumes/Data"

    init(url: URL) {
        let standardized = url.standardizedFileURL
        rootURL = standardized
        let isStartupDisk = standardized.path == "/" && FileManager.default.fileExists(atPath: Self.dataVolume)
        scanPath = isStartupDisk ? Self.dataVolume : standardized.path
        let name = standardized.path == "/"
            ? (try? standardized.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "/"
            : FileManager.default.displayName(atPath: standardized.path)
        root = SpaceNode(name: name, kind: .folder, size: 0, fileCount: 0,
                         categories: [Int64](repeating: 0, count: FileCategory.allCases.count))
        volume = Self.volumeInfo(standardized)
        start()
    }

    var isScanning: Bool { phase == .scanning }

    /// Roughly how far along a volume scan is (nil for folders, whose size isn't known up front).
    var fraction: Double? {
        guard let volume, volume.used > 0 else { return nil }
        return min(Double(scannedBytes) / Double(volume.used), 0.99)
    }

    /// Space the volume reports as used that the scan couldn't see: the system, snapshots, other users…
    var unaccounted: Int64 {
        guard let volume, !isScanning else { return 0 }
        return max(volume.used - root.size, 0)
    }

    func cancel() {
        counters.cancel.cancel()
        if isScanning { phase = .cancelled }
        poller?.invalidate()
    }

    // MARK: Paths

    /// The node for `url`, if the scan has reached it.
    func node(for url: URL) -> SpaceNode? {
        guard let components = relativeComponents(url.standardizedFileURL.path) else { return nil }
        var node = root
        for name in components {
            guard let next = node.child(named: name) else { return nil }
            node = next
        }
        return node
    }

    /// Whether `url` is inside what this scan covers.
    func covers(_ url: URL) -> Bool {
        relativeComponents(url.standardizedFileURL.path) != nil
    }

    private func relativeComponents(_ path: String) -> [String]? {
        func split(_ rest: Substring) -> [String] { rest.split(separator: "/").map(String.init) }
        if path == scanPath || path == rootURL.path { return [] }
        if path.hasPrefix(scanPath + "/") { return split(path.dropFirst(scanPath.count)) }
        if rootURL.path == "/" { return split(path[...]) } // firmlinked paths such as /Users map onto the data volume
        if path.hasPrefix(rootURL.path + "/") { return split(path.dropFirst(rootURL.path.count)) }
        return nil
    }

    /// Where a node lives on disk. On the startup disk, firmlinked folders use their usual path (/Users…).
    func url(of node: SpaceNode) -> URL {
        let components = node.components
        if components.isEmpty { return rootURL }
        if scanPath == Self.dataVolume {
            let short = "/" + components.joined(separator: "/")
            if FileManager.default.fileExists(atPath: short) { return URL(fileURLWithPath: short) }
        }
        return URL(fileURLWithPath: scanPath + "/" + components.joined(separator: "/"))
    }

    // MARK: Running

    private func start() {
        let counters = self.counters
        let path = scanPath
        var info = stat()
        guard lstat(path, &info) == 0 else {
            phase = .failed("无法读取这个位置。")
            return
        }
        let device = info.st_dev
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            phase = .failed("没有权限读取这个文件夹。")
            return
        }
        // Files right at the top show up at once; each folder joins the chart as soon as it's done.
        let builder = SpaceScanner.FolderBuilder(name: root.name, kind: .folder, forced: FileCategory.folderOverride(root.name))
        var folders: [String] = []
        for entry in entries {
            var entryInfo = stat()
            let full = path == "/" ? "/" + entry : path + "/" + entry
            guard lstat(full, &entryInfo) == 0 else { continue }
            if (entryInfo.st_mode & S_IFMT) == S_IFDIR {
                if entryInfo.st_dev == device { folders.append(entry) }
            } else {
                builder.addFile(name: entry, size: SpaceScanner.allocated(entryInfo, counters: counters))
            }
        }
        let top = builder.finish()
        root = top
        root.parent = nil
        counters.add(bytes: top.size, items: top.fileCount)
        pendingFolders = folders.count
        revision += 1

        let forced = FileCategory.folderOverride(root.name)
        for folder in folders {
            let child = path == "/" ? "/" + folder : path + "/" + folder
            Task.detached(priority: .userInitiated) { [weak self] in
                let node = await SpaceScanner.scanFolder(path: child, name: folder, forced: forced, depth: 0,
                                                          parallelDepth: 2, device: device, counters: counters)
                await self?.attach(node)
            }
        }
        poller = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        if folders.isEmpty { finish() }
    }

    private func poll() {
        let snapshot = counters.snapshot
        if snapshot.bytes != scannedBytes { scannedBytes = snapshot.bytes }
        if snapshot.items != scannedItems { scannedItems = snapshot.items }
        if snapshot.unreadable != unreadableFolders { unreadableFolders = snapshot.unreadable }
    }

    private func attach(_ node: SpaceNode?) {
        guard phase == .scanning else { return }
        if let node {
            node.parent = root
            root.children.append(node)
            Self.add(node, to: root)
            root.sortChildren()
            revision += 1
        }
        pendingFolders -= 1
        if pendingFolders <= 0 { finish() }
    }

    private func finish() {
        poll()
        poller?.invalidate()
        poller = nil
        volume = Self.volumeInfo(rootURL)
        phase = .finished(seconds: Date().timeIntervalSince(started))
        revision += 1
        SpaceIndex.shared.scanChanged()
    }

    private static func add(_ node: SpaceNode, to parent: SpaceNode) {
        parent.size += node.size
        parent.fileCount += node.fileCount
        for index in parent.categories.indices where index < node.categories.count {
            parent.categories[index] += node.categories[index]
        }
        if node.kind == .file { parent.categories[node.category.rawValue] += node.size }
    }

    static func volumeInfo(_ url: URL) -> Volume? {
        let keys: Set<URLResourceKey> = [.isVolumeKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isVolume == true || url.path == "/",
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity else { return nil }
        let important = values.volumeAvailableCapacityForImportantUsage ?? Int64(available)
        return Volume(name: values.volumeLocalizedName ?? url.lastPathComponent, total: Int64(total),
                      available: Int64(available), purgeable: max(important - Int64(available), 0))
    }

    // MARK: Keeping up with changes

    /// Takes `node` out of the tree (it was moved to the Trash, or elsewhere).
    func remove(_ node: SpaceNode) {
        guard let parent = node.parent else { return }
        parent.children.removeAll { $0 === node }
        var ancestor: SpaceNode? = parent
        while let current = ancestor {
            current.size -= node.size
            current.fileCount -= node.fileCount
            for index in current.categories.indices where index < node.categories.count {
                current.categories[index] -= node.categories[index]
            }
            if node.kind == .file { current.categories[node.category.rawValue] -= node.size }
            current.sortChildren()
            ancestor = current.parent
        }
        node.parent = nil
        revision += 1
    }

    /// Scans `url` (a file or folder that appeared, or one to refresh) and puts it into the tree.
    func graft(_ url: URL) {
        let parentURL = url.deletingLastPathComponent()
        guard let parent = node(for: parentURL), parent.isContainer else { return }
        let name = url.lastPathComponent
        let counters = ScanCounters()
        let path = url.path
        refreshing += 1
        Task.detached(priority: .utility) { [weak self] in
            var info = stat()
            guard lstat(path, &info) == 0 else {
                await self?.finishRefresh()
                return
            }
            let node: SpaceNode?
            if (info.st_mode & S_IFMT) == S_IFDIR {
                node = SpaceScanner.walk(path: path, name: name, forced: nil, counters: counters)
            } else {
                let size = Int64(info.st_blocks) * 512
                let category = FileCategory.forExtension((name as NSString).pathExtension) ?? .other
                node = SpaceNode(name: name, kind: .file, size: size, fileCount: 1, category: category)
            }
            guard let node else {
                await self?.finishRefresh()
                return
            }
            await self?.insert(node, into: parentURL)
        }
    }

    private func finishRefresh() {
        refreshing = max(refreshing - 1, 0)
    }

    private func insert(_ node: SpaceNode, into parentURL: URL) {
        defer { finishRefresh() }
        guard let parent = self.node(for: parentURL) else { return }
        if let existing = parent.child(named: node.name) { remove(existing) }
        node.parent = parent
        parent.children.append(node)
        var ancestor: SpaceNode? = parent
        while let current = ancestor {
            Self.add(node, to: current)
            current.sortChildren()
            ancestor = current.parent
        }
        revision += 1
        SpaceIndex.shared.scanChanged()
    }
}

// MARK: - All scans

/// Every scan made this session. Panes ask it for the node of their folder; the list view asks it for
/// folder sizes; file operations tell it what changed.
@MainActor @Observable
final class SpaceIndex {
    static let shared = SpaceIndex()

    private(set) var scans: [SpaceScan] = []
    /// Bumped when any finished tree changes (list views re-read folder sizes).
    private(set) var revision = 0

    private init() {
        NotificationCenter.default.addObserver(forName: FileChanges.notification, object: nil, queue: .main) { note in
            let change = note.object as? FileChanges
            MainActor.assumeIsolated { SpaceIndex.shared.apply(change) }
        }
    }

    /// The most specific scan that covers `url`.
    func scan(covering url: URL) -> SpaceScan? {
        scans.filter { $0.covers(url) && $0.phase != .cancelled }.max { $0.scanPath.count < $1.scanPath.count }
    }

    /// Starts scanning `url`, replacing scans it contains.
    @discardableResult
    func startScan(_ url: URL) -> SpaceScan {
        let scan = SpaceScan(url: url)
        for old in scans where scan.covers(old.rootURL) {
            old.cancel()
        }
        scans.removeAll { scan.covers($0.rootURL) }
        scans.append(scan)
        return scan
    }

    /// Size of a folder that has been scanned (nil when unknown or still scanning).
    func folderSize(_ url: URL) -> Int64? {
        guard !scans.isEmpty, let scan = scan(covering: url), let node = scan.node(for: url) else { return nil }
        // While a scan runs only finished subtrees are trustworthy; the root is still growing.
        if scan.isScanning, node === scan.root { return nil }
        return node.size
    }

    /// Scanned sizes of `folder`'s subfolders by name, for list views (one lookup per folder, not per row).
    func childSizes(of folder: URL) -> [String: Int64]? {
        guard !scans.isEmpty, let scan = scan(covering: folder), let node = scan.node(for: folder) else { return nil }
        var sizes: [String: Int64] = [:]
        // Children only join the tree once they're fully scanned, so these are final even mid-scan.
        for child in node.children where child.isBrowsable { sizes[child.name] = child.size }
        return sizes
    }

    func scanChanged() { revision += 1 }

    private func apply(_ change: FileChanges?) {
        guard let change, !scans.isEmpty else { return }
        for url in change.removed {
            for scan in scans where !scan.isScanning {
                if let node = scan.node(for: url), node !== scan.root { scan.remove(node) }
            }
        }
        for url in change.added {
            for scan in scans where !scan.isScanning && scan.covers(url.deletingLastPathComponent()) {
                scan.graft(url)
            }
        }
        revision += 1
    }
}

/// Posted after Arbor moves, copies, trashes or restores files, so caches such as scans stay right.
final class FileChanges: @unchecked Sendable {
    static let notification = Notification.Name("ArborFileChanges")
    let added: [URL]
    let removed: [URL]

    init(added: [URL], removed: [URL]) {
        self.added = added
        self.removed = removed
    }

    static func post(added: [URL] = [], removed: [URL] = []) {
        guard !added.isEmpty || !removed.isEmpty else { return }
        NotificationCenter.default.post(name: notification, object: FileChanges(added: added, removed: removed))
    }
}
