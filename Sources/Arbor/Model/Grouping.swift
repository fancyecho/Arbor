import CoreServices
import Foundation
import Observation

/// How the list sorts its items into labeled groups, like Finder's "Use Groups".
enum GroupBy: String, CaseIterable, Codable {
    case none, kind, modified, created, added, lastOpened, size, tags

    var title: String {
        switch self {
        case .none: L("不分组")
        case .kind: L("种类")
        case .modified: L("修改日期")
        case .created: L("创建日期")
        case .added: L("添加日期")
        case .lastOpened: L("上次打开日期")
        case .size: L("大小")
        case .tags: L("标签")
        }
    }
}

/// One labeled run of items in a grouped list.
struct FileGroup: Equatable {
    /// Stable across reloads, so the list keeps its rows (and scroll position) when files change.
    let id: String
    let title: String
    var items: [FileItem]
}

enum Grouping {
    /// Splits already-sorted `items` into groups, keeping their order inside each group. Groups come in
    /// the order a person scans for them: newest dates, largest sizes and folders first.
    static func groups(_ items: [FileItem], by groupBy: GroupBy, now: Date = Date(),
                       lastOpened: (URL) -> Date? = { _ in nil },
                       folderSize: (FileItem) -> Int64? = { _ in nil }) -> [FileGroup] {
        guard groupBy != .none else { return [FileGroup(id: "all", title: "", items: items)] }
        var buckets: [String: FileGroup] = [:]
        var order: [String: Double] = [:]
        for item in items {
            let (id, title, rank) = bucket(for: item, by: groupBy, now: now, lastOpened: lastOpened, folderSize: folderSize)
            buckets[id, default: FileGroup(id: id, title: title, items: [])].items.append(item)
            order[id] = rank
        }
        return buckets.values.sorted { a, b in
            let ra = order[a.id] ?? 0, rb = order[b.id] ?? 0
            return ra != rb ? ra < rb : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// The group an item falls in: (id, title, rank — lower ranks come first; equal ranks sort by title).
    private static func bucket(for item: FileItem, by groupBy: GroupBy, now: Date, lastOpened: (URL) -> Date?,
                               folderSize: (FileItem) -> Int64?) -> (String, String, Double) {
        switch groupBy {
        case .none:
            return ("all", "", 0)
        case .kind:
            if item.isNavigable { return ("kind:folder", L("文件夹"), 0) }
            let kind = item.localizedKind.isEmpty ? L("其他") : item.localizedKind
            return ("kind:" + kind, kind, 1)
        case .modified:
            return dateBucket(item.modified, now: now)
        case .created:
            return dateBucket(item.created, now: now)
        case .added:
            return dateBucket(item.added, now: now)
        case .lastOpened:
            return dateBucket(lastOpened(item.url), now: now)
        case .size:
            return sizeBucket(item.isNavigable ? folderSize(item) : item.size, isFolder: item.isNavigable)
        case .tags:
            guard let tag = item.tagNames.first else { return ("tag:", L("无标签"), 1) }
            return ("tag:" + tag, tag, 0)
        }
    }

    /// Finder's date groups: 今天, 昨天, 前 7 天, 前 30 天, then the months of this year, then whole years.
    static func dateBucket(_ date: Date?, now: Date) -> (String, String, Double) {
        guard let date else { return ("date:none", L("未知"), .greatestFiniteMagnitude) }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        if date >= today { return ("date:today", L("今天"), 0) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date >= yesterday {
            return ("date:yesterday", L("昨天"), 1)
        }
        if let week = calendar.date(byAdding: .day, value: -7, to: today), date >= week {
            return ("date:7", L("前 7 天"), 2)
        }
        if let month = calendar.date(byAdding: .day, value: -30, to: today), date >= month {
            return ("date:30", L("前 30 天"), 3)
        }
        let year = calendar.component(.year, from: date)
        // Older items rank by how long ago they were: a month this year before last year.
        let age = now.timeIntervalSince(date) / 86_400 + 10
        if year == calendar.component(.year, from: now) {
            let month = calendar.component(.month, from: date)
            return ("date:\(year)-\(month)", monthFormatter.string(from: date), age)
        }
        guard let start = calendar.date(from: DateComponents(year: year + 1)) else { return ("date:\(year)", "\(year)", age) }
        return ("date:\(year)", "\(year)", now.timeIntervalSince(start) / 86_400 + 10)
    }

    static func sizeBucket(_ size: Int64?, isFolder: Bool) -> (String, String, Double) {
        guard let size else {
            return isFolder ? ("size:folder", L("文件夹"), 10) : ("size:none", L("未知"), 11)
        }
        let mb: Int64 = 1_000_000
        switch size {
        case (1000 * mb)...: return ("size:1g", L("大于 1 GB"), 0)
        case (100 * mb)...: return ("size:100m", L("100 MB – 1 GB"), 1)
        case mb...: return ("size:1m", L("1 – 100 MB"), 2)
        case 100_000...: return ("size:100k", L("100 KB – 1 MB"), 3)
        default: return ("size:small", L("小于 100 KB"), 4)
        }
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM")
        return formatter
    }()
}

/// Spotlight's "last opened" dates (kMDItemLastUsedDate). Reading them costs about half a millisecond a
/// file, so they're fetched in the background only for folders that show, sort or group by them.
@MainActor @Observable
final class LastOpenedIndex {
    static let shared = LastOpenedIndex()

    /// Bumps when new dates arrive, so lists showing them redraw and re-sort.
    private(set) var revision = 0
    @ObservationIgnored private var dates: [String: Date] = [:]
    @ObservationIgnored private var fetched: Set<String> = []
    @ObservationIgnored private var lastRefresh: [String: Date] = [:]
    private static let queue = DispatchQueue(label: "app.arbor.last-opened", qos: .utility)

    func date(for url: URL) -> Date? { dates[url.standardizedFileURL.path] }

    /// Fetches dates for `urls` that haven't been read yet. `folder` refreshes all of them at most every
    /// half minute, so a file opened since shows its new date when its folder reloads.
    func prefetch(_ urls: [URL], folder: URL? = nil) {
        var refresh = false
        if let folder {
            let key = folder.standardizedFileURL.path
            if Date().timeIntervalSince(lastRefresh[key] ?? .distantPast) > 30 {
                lastRefresh[key] = Date()
                refresh = true
            }
        }
        let paths = urls.map(\.standardizedFileURL.path).filter { refresh || !fetched.contains($0) }
        guard !paths.isEmpty else { return }
        fetched.formUnion(paths)
        Self.queue.async {
            var found: [String: Date] = [:]
            for path in paths {
                guard let item = MDItemCreate(nil, path as CFString),
                      let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date else { continue }
                found[path] = date
            }
            DispatchQueue.main.async {
                let index = LastOpenedIndex.shared
                var changed = false
                for path in paths where index.dates[path] != found[path] {
                    index.dates[path] = found[path]
                    changed = true
                }
                if changed { index.revision += 1 }
            }
        }
    }
}
