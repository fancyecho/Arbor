import Foundation

/// Ways to put file paths on the clipboard.
enum PathStyle: String, CaseIterable, Identifiable {
    case path, tilde, quoted, escaped, name, stem, parent, fileURL

    var id: Self { self }

    var title: String {
        switch self {
        case .path: "完整路径"
        case .tilde: "以 ~ 开头的路径"
        case .quoted: "带引号的路径"
        case .escaped: "终端转义路径"
        case .name: "文件名"
        case .stem: "文件名（不含扩展名）"
        case .parent: "所在文件夹路径"
        case .fileURL: "file:// 链接"
        }
    }

    var example: String {
        switch self {
        case .path: "/Users/me/My File.txt"
        case .tilde: "~/My File.txt"
        case .quoted: "\"/Users/me/My File.txt\""
        case .escaped: "/Users/me/My\\ File.txt"
        case .name: "My File.txt"
        case .stem: "My File"
        case .parent: "/Users/me"
        case .fileURL: "file:///Users/me/My%20File.txt"
        }
    }
}

enum PathFormatter {
    /// Shell-ready styles are joined with spaces (paste straight into a command); others one per line.
    static func format(_ urls: [URL], _ style: PathStyle) -> String {
        let parts = urls.map { format($0, style) }
        let separator = (style == .quoted || style == .escaped) ? " " : "\n"
        return (style == .parent ? Array(NSOrderedSet(array: parts)) as? [String] ?? parts : parts).joined(separator: separator)
    }

    static func format(_ url: URL, _ style: PathStyle) -> String {
        let path = url.standardizedFileURL.path
        switch style {
        case .path: return path
        case .tilde: return (path as NSString).abbreviatingWithTildeInPath
        case .quoted: return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        case .escaped: return shellEscaped(path)
        case .name: return url.lastPathComponent
        case .stem: return url.deletingPathExtension().lastPathComponent
        case .parent: return url.deletingLastPathComponent().standardizedFileURL.path
        case .fileURL: return URL(fileURLWithPath: path).absoluteString
        }
    }

    /// Backslash-escapes characters the shell treats specially (as Terminal does on drag-and-drop).
    static func shellEscaped(_ path: String) -> String {
        let special = Set(" !\"#$&'()*,;<>?[\\]^`{|}~\t")
        return String(path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    /// Single-quotes a value for a POSIX shell: it's → 'it'\''s'.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
