import AppKit
import UniformTypeIdentifiers

/// A snapshot of one directory entry. Resource values are prefetched in bulk by
/// `DirectoryLoader`, so reading these properties never touches the disk.
struct FileItem: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let isSymlink: Bool
    let size: Int64?
    let modified: Date?
    let created: Date?
    let contentType: UTType?
    let localizedKind: String
    let tagNames: [String]

    var id: URL { url }

    /// Folders that behave like folders (packages such as .app open instead).
    var isNavigable: Bool { isDirectory && !isPackage }

    var fileExtension: String { url.pathExtension }

    static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
        .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .creationDateKey,
        .contentTypeKey, .localizedTypeDescriptionKey, .tagNamesKey,
    ]

    init(url: URL) {
        let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
        self.url = url
        self.name = values?.name ?? url.lastPathComponent
        self.isDirectory = values?.isDirectory ?? false
        self.isPackage = values?.isPackage ?? false
        self.isHidden = values?.isHidden ?? url.lastPathComponent.hasPrefix(".")
        self.isSymlink = values?.isSymbolicLink ?? false
        if let fileSize = values?.fileSize, !(values?.isDirectory ?? false) {
            self.size = Int64(fileSize)
        } else if values?.isPackage == true, let allocated = values?.totalFileAllocatedSize {
            self.size = Int64(allocated)
        } else {
            self.size = nil
        }
        self.modified = values?.contentModificationDate
        self.created = values?.creationDate
        self.contentType = values?.contentType
        self.localizedKind = values?.localizedTypeDescription ?? ""
        self.tagNames = values?.tagNames ?? []
    }

    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url && lhs.modified == rhs.modified && lhs.size == rhs.size && lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

// MARK: - Sorting

enum SortKey: String, CaseIterable, Codable {
    case name, modified, size, kind, created, location, ext, tags

    var title: String {
        switch self {
        case .name: L("名称")
        case .modified: L("修改日期")
        case .size: L("大小")
        case .kind: L("种类")
        case .created: L("创建日期")
        case .location: L("位置")
        case .ext: L("扩展名")
        case .tags: L("标签")
        }
    }
}

struct SortOrder: Equatable, Codable {
    var key: SortKey = .name
    var ascending = true
    var foldersFirst = true

    /// `folderSize` supplies sizes for folders (from a space scan) when sorting by size.
    func sorted(_ items: [FileItem], folderSize: ((URL) -> Int64?)? = nil) -> [FileItem] {
        var sizes: [URL: Int64] = [:]
        if key == .size, let folderSize {
            for item in items where item.isNavigable { sizes[item.url] = folderSize(item.url) }
        }
        return items.sorted { a, b in
            if foldersFirst, a.isNavigable != b.isNavigable { return a.isNavigable }
            let result = key == .size && !sizes.isEmpty
                ? Self.cmp(sizes[a.url] ?? a.size ?? -1, sizes[b.url] ?? b.size ?? -1)
                : compare(a, b)
            if result == .orderedSame {
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func compare(_ a: FileItem, _ b: FileItem) -> ComparisonResult {
        switch key {
        case .name: return a.name.localizedStandardCompare(b.name)
        case .modified: return Self.cmp(a.modified ?? .distantPast, b.modified ?? .distantPast)
        case .created: return Self.cmp(a.created ?? .distantPast, b.created ?? .distantPast)
        case .size: return Self.cmp(a.size ?? -1, b.size ?? -1)
        case .kind: return a.localizedKind.localizedStandardCompare(b.localizedKind)
        case .location: return a.url.deletingLastPathComponent().path.localizedStandardCompare(b.url.deletingLastPathComponent().path)
        case .ext: return a.fileExtension.localizedStandardCompare(b.fileExtension)
        case .tags: return a.tagNames.joined().localizedStandardCompare(b.tagNames.joined())
        }
    }

    private static func cmp<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}

// MARK: - Formatting

enum Format {
    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false // "0 KB", never the English "Zero KB"
        return f
    }()

    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "--" }
        return byteFormatter.string(fromByteCount: value)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// "今天 14:02" / "昨天 09:10" / "2026/10/03 18:22" — compact so the column stays narrow.
    static func date(_ date: Date?) -> String {
        guard let date else { return "--" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L("今天 ") + clockFormatter.string(from: date) }
        if cal.isDateInYesterday(date) { return L("昨天 ") + clockFormatter.string(from: date) }
        return dateFormatter.string(from: date)
    }
}

extension URL {
    /// Path-based equality: ignores trailing slashes and `.`/`..` segments that make `==` unreliable.
    func isSameFile(as other: URL) -> Bool {
        standardizedFileURL.path == other.standardizedFileURL.path
    }
}
