import Foundation

/// Pure renaming rules for the batch rename sheet. Kept free of UI so it is easy to test.
struct BatchRenameRule: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case replace, add, sequence, letterCase
        var id: Self { self }
        var title: String {
            switch self {
            case .replace: L("替换文本")
            case .add: L("添加文本")
            case .sequence: L("格式化序号")
            case .letterCase: L("大小写")
            }
        }
    }

    enum CaseStyle: String, CaseIterable, Identifiable {
        case lower, upper, capitalized
        var id: Self { self }
        var title: String {
            switch self {
            case .lower: L("全部小写")
            case .upper: L("全部大写")
            case .capitalized: L("单词首字母大写")
            }
        }
    }

    var mode: Mode = .replace

    // replace
    var find = ""
    var replacement = ""
    var useRegex = false
    var caseSensitive = false

    // add
    var prefix = ""
    var suffix = ""

    // sequence
    var baseName = L("文件")
    var startIndex = 1
    var digits = 2
    var numberFirst = false
    var separator = " "

    // letter case
    var caseStyle: CaseStyle = .lower

    /// Apply to the extension too (off by default, like Finder).
    var includeExtension = false

    func apply(to names: [String]) -> [String] {
        names.enumerated().map { index, name in apply(to: name, index: index) }
    }

    private func apply(to name: String, index: Int) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let splitExtension = !includeExtension && !ext.isEmpty && !name.hasPrefix(".")
        let stem = splitExtension ? ns.deletingPathExtension : name
        let newStem: String

        switch mode {
        case .replace:
            newStem = replace(in: stem)
        case .add:
            newStem = prefix + stem + suffix
        case .sequence:
            let number = String(format: "%0\(max(digits, 1))d", startIndex + index)
            if baseName.isEmpty {
                newStem = number
            } else {
                newStem = numberFirst ? number + separator + baseName : baseName + separator + number
            }
        case .letterCase:
            switch caseStyle {
            case .lower: newStem = stem.lowercased()
            case .upper: newStem = stem.uppercased()
            case .capitalized: newStem = stem.capitalized
            }
        }
        return splitExtension ? newStem + "." + ext : newStem
    }

    private func replace(in text: String) -> String {
        guard !find.isEmpty else { return text }
        if useRegex {
            let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            guard let regex = try? NSRegularExpression(pattern: find, options: options) else { return text }
            let range = NSRange(text.startIndex..., in: text)
            return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
        }
        return text.replacingOccurrences(of: find, with: replacement, options: caseSensitive ? [] : [.caseInsensitive])
    }

    var regexError: String? {
        guard mode == .replace, useRegex, !find.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: find)
            return nil
        } catch {
            return L("正则表达式无效")
        }
    }
}

enum BatchRenamer {
    enum Problem: Equatable {
        case invalid, duplicate, exists
        var message: String {
            switch self {
            case .invalid: L("名称无效")
            case .duplicate: L("与其他新名称重复")
            case .exists: L("已存在同名项目")
            }
        }
    }

    /// Validates each new name against the others and against files already in the folder.
    static func problems(urls: [URL], newNames: [String]) -> [Problem?] {
        let renamedPaths = Set(urls.map { $0.standardizedFileURL.path.lowercased() })
        var counts: [String: Int] = [:]
        for (url, name) in zip(urls, newNames) {
            counts[url.deletingLastPathComponent().appendingPathComponent(name).path.lowercased(), default: 0] += 1
        }
        return zip(urls, newNames).map { url, name in
            if (try? FileOperations.validate(name: name)) == nil { return .invalid }
            let targetPath = url.deletingLastPathComponent().appendingPathComponent(name).path
            let target = targetPath.lowercased()
            if counts[target, default: 0] > 1 { return .duplicate }
            // A file outside the batch already has this name.
            if !renamedPaths.contains(target), FileManager.default.fileExists(atPath: targetPath) {
                return name.lowercased() == url.lastPathComponent.lowercased() ? nil : .exists
            }
            return nil
        }
    }

    /// Renames in two phases (to temporary names first) so swaps like a↔b succeed.
    static func perform(urls: [URL], newNames: [String]) throws -> [URL] {
        let fm = FileManager.default
        var staged: [(temp: URL, final: URL)] = []
        for (url, name) in zip(urls, newNames) where name != url.lastPathComponent {
            let temp = url.deletingLastPathComponent().appendingPathComponent(".arbor-rename-\(UUID().uuidString)")
            try fm.moveItem(at: url, to: temp)
            staged.append((temp, url.deletingLastPathComponent().appendingPathComponent(name)))
        }
        var results: [URL] = []
        for entry in staged {
            try fm.moveItem(at: entry.temp, to: entry.final)
            results.append(entry.final)
        }
        return results
    }
}
