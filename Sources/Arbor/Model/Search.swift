import Foundation

enum SearchScope: String, CaseIterable, Identifiable {
    case folder, subfolders, spotlight

    var id: Self { self }

    var title: String {
        switch self {
        case .folder: "当前文件夹"
        case .subfolders: "包含子文件夹"
        case .spotlight: "整台 Mac（Spotlight）"
        }
    }
}

enum NameMatcher {
    /// Case/diacritic-insensitive substring match; Chinese names also match pinyin and initials.
    static func matches(_ name: String, _ query: String) -> Bool {
        if name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
        guard name.unicodeScalars.contains(where: { $0.value > 0x2E7F }) else { return false }
        let key = SearchKey(name)
        let q = query.lowercased().filter { !$0.isWhitespace }
        return !q.isEmpty && (key.pinyin.contains(q) || key.initials.hasPrefix(q))
    }
}

/// Walks a folder tree off the main thread, streaming matches in batches.
enum RecursiveSearch {
    static let resultLimit = 5000

    static func run(root: URL, query: String, includeHidden: Bool, cancel: CancelFlag,
                    onBatch: @escaping @Sendable ([FileItem]) -> Void, onDone: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !includeHidden { options.insert(.skipsHiddenFiles) }
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: FileItem.resourceKeys, options: options, errorHandler: { _, _ in true })
            var batch: [FileItem] = []
            var total = 0
            var lastFlush = Date()
            var truncated = false
            while let url = enumerator?.nextObject() as? URL {
                if cancel.isCancelled { return }
                guard NameMatcher.matches(url.lastPathComponent, query) else { continue }
                batch.append(FileItem(url: url))
                total += 1
                if total >= resultLimit { truncated = true; break }
                if batch.count >= 200 || Date().timeIntervalSince(lastFlush) > 0.25 {
                    onBatch(batch)
                    batch.removeAll()
                    lastFlush = Date()
                }
            }
            if cancel.isCancelled { return }
            if !batch.isEmpty { onBatch(batch) }
            onDone(truncated)
        }
    }
}

/// Spotlight search across the Mac by name or content (NSMetadataQuery must live on the main thread).
@MainActor
final class SpotlightSearch: NSObject {
    private let query = NSMetadataQuery()
    private let onResults: ([URL]) -> Void
    private var observers: [NSObjectProtocol] = []

    convenience init(text: String, onResults: @escaping ([URL]) -> Void) {
        self.init(predicate: NSPredicate(format: "(kMDItemDisplayName CONTAINS[cd] %@) OR (kMDItemTextContent CONTAINS[cd] %@)", text, text),
                  onResults: onResults)
    }

    init(predicate: NSPredicate, onResults: @escaping ([URL]) -> Void) {
        self.onResults = onResults
        super.init()
        query.predicate = predicate
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.collect() }
            })
        }
        query.start()
    }

    func stop() {
        query.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func collect() {
        query.disableUpdates()
        let count = min(query.resultCount, 2000)
        let urls = (0..<count).compactMap { index -> URL? in
            (query.result(at: index) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey)
                .flatMap { $0 as? String }.map { URL(fileURLWithPath: $0) }
        }
        query.enableUpdates()
        onResults(urls)
    }
}

/// "按条件选择" rules.
struct SelectionCondition: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case any, files, folders
        var id: Self { self }
        var title: String { ["any": "全部", "files": "仅文件", "folders": "仅文件夹"][rawValue]! }
    }

    enum Age: String, CaseIterable, Identifiable {
        case any, today, week, month, older
        var id: Self { self }
        var title: String {
            ["any": "不限", "today": "今天", "week": "最近 7 天", "month": "最近 30 天", "older": "30 天以前"][rawValue]!
        }
    }

    enum SizeRule: String, CaseIterable, Identifiable {
        case any, larger, smaller
        var id: Self { self }
        var title: String { ["any": "不限", "larger": "大于", "smaller": "小于"][rawValue]! }
    }

    var pattern = ""
    var useRegex = false
    var kind: Kind = .any
    var age: Age = .any
    var sizeRule: SizeRule = .any
    var sizeMB: Double = 10
    var addToSelection = false

    /// Patterns with * or ? are wildcards ("*.jpg"); otherwise a plain "contains".
    func matches(_ item: FileItem, now: Date = .now) -> Bool {
        if !pattern.isEmpty {
            if useRegex {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                      regex.firstMatch(in: item.name, range: NSRange(item.name.startIndex..., in: item.name)) != nil
                else { return false }
            } else if pattern.contains("*") || pattern.contains("?") {
                guard NSPredicate(format: "SELF LIKE[cd] %@", pattern).evaluate(with: item.name) else { return false }
            } else if !NameMatcher.matches(item.name, pattern) {
                return false
            }
        }
        switch kind {
        case .any: break
        case .files: if item.isNavigable { return false }
        case .folders: if !item.isNavigable { return false }
        }
        if age != .any {
            guard let modified = item.modified else { return false }
            let days = now.timeIntervalSince(modified) / 86_400
            switch age {
            case .today: if !Calendar.current.isDate(modified, inSameDayAs: now) { return false }
            case .week: if days > 7 { return false }
            case .month: if days > 30 { return false }
            case .older: if days <= 30 { return false }
            case .any: break
            }
        }
        if sizeRule != .any {
            guard let size = item.size else { return false }
            let limit = Int64(sizeMB * 1_000_000)
            if sizeRule == .larger ? size <= limit : size >= limit { return false }
        }
        return true
    }
}
