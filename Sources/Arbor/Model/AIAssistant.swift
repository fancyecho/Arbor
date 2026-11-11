import AppKit
import PDFKit
import UniformTypeIdentifiers
import Vision

/// What the model decided a request means. Only ever searches, selects or navigates: nothing it says
/// can move, rename or delete a file.
struct AICommand: Sendable {
    enum Action: String, Sendable { case search, navigate, select, answer }

    struct Query: Sendable {
        var keywords: [String] = []
        var kinds: [String] = []
        var extensions: [String] = []
        var withinDays = 0
        var after: Date?
        var before: Date?
        var minBytes: Int64 = 0
        var maxBytes: Int64 = 0
        var downloadedFrom = ""
        var wholeHome = false

        var isEmpty: Bool {
            keywords.isEmpty && kinds.isEmpty && extensions.isEmpty && withinDays == 0 && after == nil && before == nil
                && minBytes == 0 && maxBytes == 0 && downloadedFrom.isEmpty
        }
    }

    var action: Action
    var reply: String
    var path: String
    var query: Query
}

enum AIAssistant {
    static let kinds = ["image", "screenshot", "video", "audio", "pdf", "document", "spreadsheet", "presentation",
                        "code", "archive", "app", "folder"]

    // MARK: Commands

    static func commandSchema() -> [String: Any] {
        let string: [String: Any] = ["type": "string"]
        let strings: [String: Any] = ["type": "array", "items": string]
        let query: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["keywords", "kinds", "extensions", "withinDays", "after", "before", "minMB", "maxMB",
                         "downloadedFrom", "wholeHome"],
            "properties": [
                "keywords": strings,
                "kinds": ["type": "array", "items": ["type": "string", "enum": kinds]],
                "extensions": strings,
                "withinDays": ["type": "integer"],
                "after": string,
                "before": string,
                "minMB": ["type": "number"],
                "maxMB": ["type": "number"],
                "downloadedFrom": string,
                "wholeHome": ["type": "boolean"],
            ],
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["action", "reply", "path", "query"],
            "properties": [
                "action": ["type": "string", "enum": ["search", "navigate", "select", "answer"]],
                "reply": string,
                "path": string,
                "query": query,
            ],
        ]
    }

    static func command(from object: [String: Any]) throws -> AICommand {
        guard let raw = object["action"] as? String, let action = AICommand.Action(rawValue: raw) else {
            throw AIError.badReply(L("没有说明要做什么"))
        }
        let q = object["query"] as? [String: Any] ?? [:]
        // Models sometimes send absurd numbers; clamp before converting so Int() can't trap.
        func number(_ key: String, max upper: Double) -> Double {
            let value = (q[key] as? NSNumber)?.doubleValue ?? Double(q[key] as? String ?? "") ?? 0
            return value.isFinite ? min(max(value, 0), upper) : 0
        }
        var query = AICommand.Query()
        query.keywords = (q["keywords"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        query.kinds = (q["kinds"] as? [String] ?? []).filter(kinds.contains)
        query.extensions = (q["extensions"] as? [String] ?? []).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
            .filter { !$0.isEmpty }
        query.withinDays = Int(number("withinDays", max: 36_500))
        query.after = (q["after"] as? String).flatMap(day.date(from:))
        query.before = (q["before"] as? String).flatMap(day.date(from:))
        query.minBytes = Int64(number("minMB", max: 100_000_000) * 1_000_000)
        query.maxBytes = Int64(number("maxMB", max: 100_000_000) * 1_000_000)
        query.downloadedFrom = (q["downloadedFrom"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        query.wholeHome = q["wholeHome"] as? Bool ?? false
        return AICommand(action: action, reply: object["reply"] as? String ?? "", path: object["path"] as? String ?? "",
                         query: query)
    }

    /// Spotlight predicate for a search.
    static func predicate(for query: AICommand.Query) -> NSPredicate? {
        guard !query.isEmpty else { return nil }
        var parts: [NSPredicate] = []
        for keyword in query.keywords {
            parts.append(NSPredicate(format: "(kMDItemDisplayName CONTAINS[cd] %@) OR (kMDItemTextContent CONTAINS[cd] %@)", keyword, keyword))
        }
        var kindParts: [NSPredicate] = []
        for kind in query.kinds {
            if kind == "screenshot" {
                kindParts.append(NSPredicate(format: "kMDItemIsScreenCapture == 1"))
            } else {
                for type in contentTypes(kind) { kindParts.append(NSPredicate(format: "kMDItemContentTypeTree == %@", type)) }
            }
        }
        if let kinds = any(kindParts) { parts.append(kinds) }
        if let extensions = any(query.extensions.map { NSPredicate(format: "kMDItemFSName LIKE[c] %@", "*." + $0) }) {
            parts.append(extensions)
        }
        if let since = since(query) { parts.append(NSPredicate(format: "kMDItemFSContentChangeDate >= %@", since as NSDate)) }
        if let before = query.before { parts.append(NSPredicate(format: "kMDItemFSContentChangeDate < %@", before as NSDate)) }
        if query.minBytes > 0 { parts.append(NSPredicate(format: "kMDItemFSSize >= %lld", query.minBytes)) }
        if query.maxBytes > 0 { parts.append(NSPredicate(format: "kMDItemFSSize <= %lld", query.maxBytes)) }
        if !query.downloadedFrom.isEmpty { parts.append(NSPredicate(format: "kMDItemWhereFroms CONTAINS[cd] %@", query.downloadedFrom)) }
        return all(parts)
    }

    /// Spotlight rejects an OR / AND group with a single member (it throws), so one condition stays bare.
    private static func any(_ parts: [NSPredicate]) -> NSPredicate? {
        parts.count > 1 ? NSCompoundPredicate(orPredicateWithSubpredicates: parts) : parts.first
    }

    private static func all(_ parts: [NSPredicate]) -> NSPredicate? {
        parts.count > 1 ? NSCompoundPredicate(andPredicateWithSubpredicates: parts) : parts.first
    }

    /// The folder's items a selection query picks.
    static func matches(_ items: [FileItem], _ query: AICommand.Query) -> [FileItem] {
        let since = since(query)
        return items.filter { item in
            if !query.keywords.isEmpty, !query.keywords.allSatisfy({ NameMatcher.matches(item.name, $0) }) { return false }
            if !query.extensions.isEmpty, !query.extensions.contains(item.fileExtension.lowercased()) { return false }
            if !query.kinds.isEmpty, !query.kinds.contains(where: { matchesKind(item, $0) }) { return false }
            if let since, (item.modified ?? .distantPast) < since { return false }
            if let before = query.before, (item.modified ?? .distantFuture) >= before { return false }
            if query.minBytes > 0, (item.size ?? 0) < query.minBytes { return false }
            if query.maxBytes > 0, (item.size ?? .max) > query.maxBytes { return false }
            return true
        }
    }

    private static func since(_ query: AICommand.Query) -> Date? {
        let fromDays = query.withinDays > 0
            ? Calendar.current.date(byAdding: .day, value: -(query.withinDays - 1), to: Calendar.current.startOfDay(for: Date()))
            : nil
        return [fromDays, query.after].compactMap { $0 }.max()
    }

    private static func contentTypes(_ kind: String) -> [String] {
        switch kind {
        case "image": ["public.image"]
        case "video": ["public.movie"]
        case "audio": ["public.audio"]
        case "pdf": ["com.adobe.pdf"]
        case "document": ["com.adobe.pdf", "public.plain-text", "public.rtf", "org.openxmlformats.wordprocessingml.document",
                          "com.microsoft.word.doc", "com.apple.iwork.pages.sffpages", "net.daringfireball.markdown"]
        case "spreadsheet": ["public.spreadsheet"]
        case "presentation": ["public.presentation"]
        case "code": ["public.source-code", "public.script"]
        case "archive": ["public.archive"]
        case "app": ["com.apple.application-bundle"]
        case "folder": ["public.folder"]
        default: []
        }
    }

    private static func matchesKind(_ item: FileItem, _ kind: String) -> Bool {
        if kind == "folder" { return item.isNavigable }
        if kind == "screenshot" {
            let name = item.name.lowercased()
            return item.contentType?.conforms(to: .image) == true
                && (name.hasPrefix("screenshot") || name.hasPrefix("截屏") || name.hasPrefix("屏幕快照") || name.hasPrefix("screen shot"))
        }
        guard let type = item.contentType else { return false }
        return contentTypes(kind).compactMap(UTType.init).contains { type.conforms(to: $0) }
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: Renaming

    static func renameSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["names"],
            "properties": [
                "names": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["index", "name"],
                        "properties": ["index": ["type": "integer"], "name": ["type": "string"]],
                    ],
                ],
            ],
        ]
    }

    static func renamePrompt(language: String, style: String) -> String {
        """
        You name files for a macOS file manager. For each file, propose a short, descriptive name based on what it \
        contains, in \(language) unless the content is clearly in another language. Keep the original extension \
        exactly. No slashes or colons. Prefer 2–6 words; put a date first (YYYY-MM-DD) only when the content is \
        dated, like a receipt, invoice or meeting notes. \(style)
        Reply with "names": one entry per file, using the file's index.
        """
    }

    /// One line of context per file: its name and what we could read from it locally (text, PDF text, OCR).
    static func describe(_ urls: [URL]) async -> String {
        var lines: [String] = []
        for (index, url) in urls.enumerated() {
            let excerpt = await excerpt(of: url)
            var line = "[\(index)] \(url.lastPathComponent)"
            if let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate {
                line += " (created \(day.string(from: created)))"
            }
            if !excerpt.isEmpty { line += "\n    content: " + excerpt }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func excerpt(of url: URL, limit: Int = 700) async -> String {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType

        if type?.conforms(to: .pdf) == true, let document = PDFDocument(url: url) {
            let text = (0..<min(document.pageCount, 2)).compactMap { document.page(at: $0)?.string }.joined(separator: " ")
            return clean(text, limit)
        }
        if type?.conforms(to: .image) == true { return clean(await recognizeText(url), limit) }
        if type?.conforms(to: .text) == true || type?.conforms(to: .sourceCode) == true,
           let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 4000)) ?? Data()
            return clean(String(decoding: data, as: UTF8.self), limit)
        }
        return ""
    }

    private static func clean(_ text: String, _ limit: Int) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }

    /// Text in a picture (screenshots, scans), read on this Mac with Vision.
    private static func recognizeText(_ url: URL) async -> String {
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(url: url)
            try? handler.perform([request])
            return (request.results ?? []).prefix(40).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }.value
    }

    /// The reply's names, by position, keeping each file's extension and fixing characters macOS won't take.
    static func names(from object: [String: Any], for urls: [URL]) -> [String?] {
        var result = [String?](repeating: nil, count: urls.count)
        for entry in object["names"] as? [[String: Any]] ?? [] {
            guard let index = (entry["index"] as? NSNumber)?.intValue, urls.indices.contains(index),
                  var name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            let ext = urls[index].pathExtension
            if !ext.isEmpty, (name as NSString).pathExtension.lowercased() != ext.lowercased() {
                name += "." + ext
            }
            result[index] = name
        }
        return result
    }
}
