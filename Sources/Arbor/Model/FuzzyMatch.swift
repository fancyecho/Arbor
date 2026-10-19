import Foundation

/// Precomputed forms of a string for matching: plain, full pinyin and pinyin initials,
/// so "新建文件夹" matches "xinjian", "xjwjj" and "文件".
struct SearchKey {
    let text: String
    let pinyin: String
    let initials: String

    init(_ string: String) {
        text = string.lowercased()
        let latin = string.applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?
            .lowercased() ?? text
        let words = latin.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        pinyin = words.joined()
        initials = String(words.compactMap(\.first))
    }
}

enum Fuzzy {
    private static var cache: [String: SearchKey] = [:]
    private static let lock = NSLock()

    static func key(_ string: String) -> SearchKey {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[string] { return hit }
        let key = SearchKey(string)
        if cache.count > 5000 { cache.removeAll() }
        cache[string] = key
        return key
    }

    /// 0…1 match quality, or nil if `query` doesn't match `candidate` at all.
    static func score(_ query: String, _ candidate: String) -> Double? {
        let q = query.lowercased().filter { !$0.isWhitespace }
        guard !q.isEmpty else { return 0.5 }
        let key = key(candidate)
        if key.text.hasPrefix(q) { return 1.0 }
        if let range = key.text.range(of: q) {
            let offset = key.text.distance(from: key.text.startIndex, to: range.lowerBound)
            return 0.9 - min(Double(offset), 20) * 0.01
        }
        if key.initials.hasPrefix(q) { return 0.8 }
        if key.pinyin.hasPrefix(q) { return 0.78 }
        if key.pinyin.contains(q) || key.initials.contains(q) { return 0.65 }
        if let s = subsequence(q, key.text) { return 0.3 + 0.3 * s }
        if let s = subsequence(q, key.pinyin) { return 0.2 + 0.3 * s }
        return nil
    }

    /// Characters of `query` appear in order in `text`; rewards consecutive runs.
    private static func subsequence(_ query: String, _ text: String) -> Double? {
        var it = text.makeIterator()
        var consecutive = 0, best = 0, previousMatched = false
        for char in query {
            var found = false
            while let next = it.next() {
                if next == char {
                    found = true
                    consecutive = previousMatched ? consecutive + 1 : 1
                    best = max(best, consecutive)
                    previousMatched = true
                    break
                }
                previousMatched = false
            }
            if !found { return nil }
        }
        return Double(best) / Double(max(query.count, 1))
    }

    /// zoxide-style folder matching: every token must match a path component, in order,
    /// and the last token must match the folder's own name. "pro arb" → …/project/Arbor.
    static func pathScore(_ query: String, _ path: String) -> Double? {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard let last = tokens.last else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard let name = components.last, let lastScore = score(last, name) else { return nil }
        var index = 0
        for token in tokens.dropLast() {
            guard let found = components[index..<max(index, components.count - 1)]
                .firstIndex(where: { score(token, $0) ?? 0 >= 0.6 }) else { return nil }
            index = found + 1
        }
        return lastScore
    }
}

/// Remembers how often and how recently folders are visited (like zoxide) for smart jumps.
@MainActor
final class Frecency {
    static let shared = Frecency()

    private struct Entry: Codable {
        var count: Double
        var last: Date
    }

    private var entries: [String: Entry]
    private let defaults = AppDefaults.store
    private let limit = 500

    private init() {
        entries = defaults.data(forKey: "frecency")
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func visit(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard path != "/" else { return }
        var entry = entries[path] ?? Entry(count: 0, last: .now)
        entry.count += 1
        entry.last = .now
        entries[path] = entry
        if entries.count > limit {
            let keep = entries.sorted { score($0.value) > score($1.value) }.prefix(limit * 9 / 10)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        defaults.set(try? JSONEncoder().encode(entries), forKey: "frecency")
    }

    func forget(_ path: String) {
        entries[path] = nil
    }

    /// Folders by descending frecency.
    func ranked() -> [(path: String, score: Double)] {
        entries.map { ($0.key, score($0.value)) }.sorted { $0.1 > $1.1 }
    }

    private func score(_ entry: Entry) -> Double {
        let age = Date.now.timeIntervalSince(entry.last)
        let weight: Double = age < 3600 ? 4 : age < 86_400 ? 2 : age < 604_800 ? 0.5 : 0.25
        return entry.count * weight
    }
}
