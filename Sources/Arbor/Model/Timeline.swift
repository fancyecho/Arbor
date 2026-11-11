import AppKit
import ArborObjC
import Observation
import UniformTypeIdentifiers

/// What last happened to a file, which decides where it sits in the timeline.
enum TimelineEvent: String, Sendable {
    case downloaded, screenshot, opened, modified, added

    var title: String {
        switch self {
        case .downloaded: L("下载")
        case .screenshot: L("截图")
        case .opened: L("打开")
        case .modified: L("修改")
        case .added: L("添加")
        }
    }

    var symbol: String {
        switch self {
        case .downloaded: "arrow.down.circle.fill"
        case .screenshot: "camera.viewfinder"
        case .opened: "eye.fill"
        case .modified: "pencil.circle.fill"
        case .added: "plus.circle.fill"
        }
    }
}

/// Which files the timeline shows.
enum TimelineFilter: String, CaseIterable, Identifiable, Sendable {
    case all, downloads, screenshots, documents, images, code

    var id: Self { self }

    var title: String {
        switch self {
        case .all: L("全部")
        case .downloads: L("下载")
        case .screenshots: L("截图")
        case .documents: L("文档")
        case .images: L("图片")
        case .code: L("代码")
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.stack"
        case .downloads: "arrow.down.circle"
        case .screenshots: "camera.viewfinder"
        case .documents: "doc.text"
        case .images: "photo"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }

    func matches(_ entry: TimelineEntry) -> Bool {
        switch self {
        case .all: true
        case .downloads: entry.source != nil
        case .screenshots: entry.isScreenshot
        case .documents: entry.conforms(to: [.pdf, .text, .presentation, .spreadsheet, .rtf]) && !entry.isCode
        case .images: entry.conforms(to: [.image])
        case .code: entry.isCode
        }
    }
}

enum TimelineRange: Int, CaseIterable, Identifiable, Sendable {
    case today = 1, week = 7, month = 30

    var id: Self { self }

    var title: String {
        switch self {
        case .today: L("今天")
        case .week: L("7 天")
        case .month: L("30 天")
        }
    }
}

struct TimelineEntry: Identifiable, Sendable {
    let item: FileItem
    let date: Date
    let event: TimelineEvent
    /// The site a download came from ("github.com").
    let source: String?
    let isScreenshot: Bool
    let types: [String]

    var id: URL { item.url }

    func conforms(to wanted: [UTType]) -> Bool {
        guard let type = item.contentType else { return false }
        return wanted.contains { type.conforms(to: $0) }
    }

    var isCode: Bool {
        conforms(to: [.sourceCode, .script, .json, .xml, .yaml, .propertyList]) || Self.codeExtensions.contains(item.fileExtension.lowercased())
    }

    var isImage: Bool { conforms(to: [.image]) }

    private static let codeExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "rb", "kt", "java", "c", "cc", "cpp", "h", "m", "mm",
        "md", "toml", "yml", "yaml", "json", "css", "scss", "html", "vue", "svelte", "sh", "zsh", "sql",
    ]
}

/// A day in the timeline: single files, and runs of three or more images shown as one strip.
struct TimelineDay: Identifiable {
    enum Row: Identifiable {
        case entry(TimelineEntry)
        case strip([TimelineEntry])

        var id: String {
            switch self {
            case .entry(let entry): entry.id.path
            case .strip(let entries): "strip:" + (entries.first?.id.path ?? "")
            }
        }
    }

    let id: Date
    let title: String
    let rows: [Row]
    let count: Int
}

/// Recently downloaded, opened, changed or captured files under a folder, from Spotlight.
@MainActor @Observable
final class TimelineModel {
    private(set) var entries: [TimelineEntry] = []
    private(set) var isLoading = true
    private(set) var truncated = false

    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var collectWork: DispatchWorkItem?
    @ObservationIgnored private var generation = 0
    /// Noise filtering applies below the folder being shown, so browsing ~/Library still works.
    @ObservationIgnored private var scopePath = ""

    nonisolated static let limit = 2500

    /// Folders that change all the time without anyone touching them.
    private static let noise = ["/library/", "/node_modules/", "/.git/", "/deriveddata/", "/.build/", "/caches/", "/cache/",
                                "/.trash/", "/build/", "/target/", "/.cache/", "/pods/", ".app/contents/", "/logs/", "/tmp/"]

    func start(scope: URL, range: TimelineRange) {
        stop()
        generation += 1
        isLoading = true
        let since = Calendar.current.date(byAdding: .day, value: -(range.rawValue - 1),
                                          to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(
            format: "(kMDItemFSContentChangeDate >= %@ OR kMDItemLastUsedDate >= %@ OR kMDItemDateAdded >= %@) AND kMDItemContentType != 'public.folder'",
            since as NSDate, since as NSDate, since as NSDate)
        let isRoot = scope.path == "/" || (try? scope.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
        query.searchScopes = isRoot ? [NSMetadataQueryUserHomeScope] : [scope]
        scopePath = isRoot ? FileManager.default.homeDirectoryForCurrentUser.path : scope.standardizedFileURL.path
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        query.notificationBatchingInterval = 0.5
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleCollect(since: since) }
            })
        }
        self.query = query
        var error: NSError?
        if !ArborCatchException({ query.start() }, &error) {
            self.query = nil
            isLoading = false
        }
    }

    func stop() {
        query?.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        query = nil
        collectWork?.cancel()
    }

    private func scheduleCollect(since: Date) {
        collectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collect(since: since) }
        collectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private struct Raw: Sendable {
        let path: String
        let modified: Date?
        let used: Date?
        let added: Date?
        let froms: [String]
        let screenshot: Bool
        let types: [String]
    }

    private func collect(since: Date) {
        guard let query else { return }
        query.disableUpdates()
        let count = min(query.resultCount, Self.limit * 2)
        var raws: [Raw] = []
        raws.reserveCapacity(count)
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let inside = (path.hasPrefix(scopePath) ? String(path.dropFirst(scopePath.count)) : path).lowercased()
            if Self.noise.contains(where: inside.contains) || inside.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                continue
            }
            raws.append(Raw(
                path: path,
                modified: item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
                used: item.value(forAttribute: "kMDItemLastUsedDate") as? Date,
                added: item.value(forAttribute: "kMDItemDateAdded") as? Date,
                froms: item.value(forAttribute: "kMDItemWhereFroms") as? [String] ?? [],
                screenshot: (item.value(forAttribute: "kMDItemIsScreenCapture") as? NSNumber)?.boolValue ?? false,
                types: item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String] ?? []))
        }
        let total = query.resultCount
        query.enableUpdates()
        let generation = self.generation
        Task.detached(priority: .userInitiated) {
            let built = raws.compactMap { Self.entry(from: $0, since: since) }
                .sorted { $0.date > $1.date }
            let limited = Array(built.prefix(Self.limit))
            await MainActor.run {
                guard generation == self.generation else { return }
                self.entries = limited
                self.truncated = total > Self.limit * 2 || built.count > Self.limit
                self.isLoading = false
            }
        }
    }

    nonisolated private static func entry(from raw: Raw, since: Date) -> TimelineEntry? {
        let url = URL(fileURLWithPath: raw.path)
        // Files only (Spotlight sometimes reports packages and folders by type tree).
        if raw.types.contains("public.folder") && !raw.types.contains("com.apple.package") { return nil }
        let candidates: [(Date?, TimelineEvent)] = [
            (raw.added, raw.froms.isEmpty ? .added : .downloaded),
            (raw.used, .opened),
            (raw.modified, .modified),
        ]
        guard let latest = candidates.compactMap({ pair in pair.0.map { ($0, pair.1) } }).max(by: { $0.0 < $1.0 }),
              latest.0 >= since, latest.0 <= Date().addingTimeInterval(300) else { return nil }
        var event = latest.1
        // A download opened once is still best described as a download; same for screenshots.
        if raw.screenshot { event = .screenshot }
        else if !raw.froms.isEmpty, let added = raw.added, latest.0.timeIntervalSince(added) < 120 { event = .downloaded }
        let source = raw.froms.lazy.compactMap { URL(string: $0)?.host() }.first.map {
            $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0
        }
        return TimelineEntry(item: FileItem(url: url), date: latest.0, event: event, source: source,
                             isScreenshot: raw.screenshot, types: raw.types)
    }

    // MARK: Days

    /// Entries grouped by day, newest first, with runs of images folded into strips.
    static func days(_ entries: [TimelineEntry]) -> [TimelineDay] {
        let calendar = Calendar.current
        var byDay: [(Date, [TimelineEntry])] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.date)
            if byDay.last?.0 == day { byDay[byDay.count - 1].1.append(entry) } else { byDay.append((day, [entry])) }
        }
        return byDay.map { day, items in
            var rows: [TimelineDay.Row] = []
            var run: [TimelineEntry] = []
            func flush() {
                if run.count >= 3 { rows.append(.strip(run)) } else { rows += run.map { .entry($0) } }
                run = []
            }
            for item in items {
                if item.isImage { run.append(item) } else { flush(); rows.append(.entry(item)) }
            }
            flush()
            return TimelineDay(id: day, title: title(for: day), rows: rows, count: items.count)
        }
    }

    private static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()

    private static let longDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd EEEE")
        return f
    }()

    static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return L("今天") }
        if calendar.isDateInYesterday(day) { return L("昨天") }
        if let days = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: Date())).day, days < 7 {
            return weekday.string(from: day)
        }
        return longDate.string(from: day)
    }
}
