import AppKit

/// Finder tags. Standard tag names come from the system so they match Finder's language.
enum FinderTags {
    struct Tag: Hashable {
        let name: String
        let color: NSColor
    }

    /// Finder's sidebar order: red, orange, yellow, green, blue, purple, gray.
    static let standard: [Tag] = {
        let labels = NSWorkspace.shared.fileLabels
        let colors = NSWorkspace.shared.fileLabelColors
        return [6, 7, 5, 2, 4, 3, 1].compactMap { index in
            guard labels.indices.contains(index), colors.indices.contains(index) else { return nil }
            return Tag(name: labels[index], color: colors[index])
        }
    }()

    static func color(for name: String) -> NSColor? {
        standard.first { $0.name == name }?.color
    }

    static func tags(of url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    static func setTags(_ tags: [String], on url: URL) throws {
        try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
    }

    /// Adds `tag` to every item, or removes it from all of them if they all have it already.
    static func toggle(_ tag: String, on urls: [URL]) throws {
        let allHave = urls.allSatisfy { tags(of: $0).contains(tag) }
        for url in urls {
            var current = tags(of: url)
            if allHave {
                current.removeAll { $0 == tag }
            } else if !current.contains(tag) {
                current.append(tag)
            }
            try setTags(current, on: url)
        }
    }

    /// A small filled circle for menus.
    static func dot(_ color: NSColor, size: CGFloat = 12) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

/// "颜色规则": tint file names that match a pattern, e.g. `*.psd; *.ai` in purple.
struct ColorRule: Codable, Hashable, Identifiable {
    enum Tint: String, Codable, CaseIterable, Identifiable {
        case red, orange, yellow, green, blue, purple, gray
        var id: Self { self }
        var title: String {
            ["red": L("红色"), "orange": L("橙色"), "yellow": L("黄色"), "green": L("绿色"), "blue": L("蓝色"), "purple": L("紫色"), "gray": L("灰色")][rawValue]!
        }
        var color: NSColor {
            switch self {
            case .red: .systemRed
            case .orange: .systemOrange
            case .yellow: .systemYellow
            case .green: .systemGreen
            case .blue: .systemBlue
            case .purple: .systemPurple
            case .gray: .systemGray
            }
        }
    }

    var id = UUID()
    var pattern: String
    var tint: Tint
    var enabled = true

    /// "*.psd; *.ai" → case-insensitive whole-name regexes.
    var regexes: [NSRegularExpression] {
        pattern.split(whereSeparator: { $0 == ";" || $0 == "," }).compactMap { part in
            let glob = part.trimmingCharacters(in: .whitespaces)
            guard !glob.isEmpty else { return nil }
            let escaped = NSRegularExpression.escapedPattern(for: glob)
                .replacingOccurrences(of: "\\*", with: ".*")
                .replacingOccurrences(of: "\\?", with: ".")
            return try? NSRegularExpression(pattern: "^" + escaped + "$", options: [.caseInsensitive])
        }
    }

    func matches(_ name: String) -> Bool {
        enabled && regexes.contains { $0.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil }
    }
}

/// Compiled rules, rebuilt only when the rules change.
@MainActor
enum ColorRules {
    private static var compiled: (rules: [ColorRule], regexes: [([NSRegularExpression], NSColor)]) = ([], [])

    static func color(for name: String) -> NSColor? {
        let rules = AppSettings.shared.colorRules
        if compiled.rules != rules {
            compiled = (rules, rules.filter(\.enabled).map { ($0.regexes, $0.tint.color) })
        }
        let range = NSRange(name.startIndex..., in: name)
        return compiled.regexes.first { $0.0.contains { $0.firstMatch(in: name, range: range) != nil } }?.1
    }
}
