import SwiftUI
import UniformTypeIdentifiers

enum TextFile {
    static let maxSize: Int64 = 2_000_000
    private static let extraExtensions: Set<String> = [
        "md", "markdown", "yaml", "yml", "toml", "ini", "conf", "cfg", "env", "log", "csv", "tsv", "sql",
        "swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "rb", "java", "kt", "c", "h", "cpp", "hpp", "m",
        "sh", "zsh", "bash", "fish", "lua", "php", "vue", "css", "scss", "html", "xml", "json", "gitignore",
    ]

    static func isText(_ item: FileItem) -> Bool {
        guard !item.isNavigable, (item.size ?? 0) <= maxSize else { return false }
        if extraExtensions.contains(item.fileExtension.lowercased()) { return true }
        guard let type = item.contentType else { return false }
        return type.conforms(to: .text) && !type.conforms(to: .rtf) && !type.conforms(to: .html) || type.conforms(to: .sourceCode)
    }

    /// UTF-8, then GB18030 (common for Chinese text from Windows), then Latin-1.
    static func read(_ url: URL) -> (String, String.Encoding)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(data: data, encoding: gb) { return (text, gb) }
        return String(data: data, encoding: .isoLatin1).map { ($0, .isoLatin1) }
    }

    /// Saves, keeping the previous version in the Trash so the edit is undoable.
    static func save(_ text: String, to url: URL, encoding: String.Encoding) throws -> [UndoStep] {
        let fm = FileManager.default
        let backup = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(url.lastPathComponent)
        try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: url, to: backup)
        var trashed: NSURL?
        try fm.trashItem(at: backup, resultingItemURL: &trashed)
        try text.write(to: url, atomically: true, encoding: encoding)
        guard let original = trashed as URL? else { return [] }
        return [.trash(url), .move(from: original, to: url)]
    }
}

/// Lightweight syntax coloring: comments, strings, numbers and common keywords.
enum SyntaxHighlighter {
    private static let keywords = Set("""
    func let var if else for while return import class struct enum case switch default break continue in of
    def from as with try catch except finally throw throws async await public private static const new this self
    true false nil null None True False and or not is function export package interface extends implements fn
    impl use mod pub match where type guard defer do echo then fi done local
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    private static let patterns: [(NSRegularExpression, Color)] = [
        (try! NSRegularExpression(pattern: #""(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`[^`]*`"#), .red),
        (try! NSRegularExpression(pattern: #"\b\d+(?:\.\d+)?\b"#), .purple),
        (try! NSRegularExpression(pattern: #"//[^\n]*|/\*[\s\S]*?\*/|(?m)^\s*#(?!!)[^\n]*|(?<=\s)#[^\n]*"#), .gray),
    ]

    static func highlight(_ text: String) -> AttributedString {
        let limited = text.count > 200_000 ? String(text.prefix(200_000)) : text
        var result = AttributedString(limited)
        let ns = limited as NSString
        let full = NSRange(location: 0, length: ns.length)
        func apply(_ range: NSRange, _ color: Color) {
            guard let r = Range(range, in: limited), let ar = Range(r, in: result) else { return }
            result[ar].foregroundColor = color
        }
        let words = try! NSRegularExpression(pattern: #"\b[A-Za-z_]+\b"#)
        for match in words.matches(in: limited, range: full) where keywords.contains(ns.substring(with: match.range)) {
            apply(match.range, .pink)
        }
        for (regex, color) in patterns {
            for match in regex.matches(in: limited, range: full) { apply(match.range, color) }
        }
        return result
    }
}

/// Inspector preview for text and code: colored read-only view, Markdown preview, and in-place editing.
struct TextPreview: View {
    let item: FileItem

    @State private var text = ""
    @State private var encoding: String.Encoding = .utf8
    @State private var draft = ""
    @State private var editing = false
    @State private var showMarkdown = true
    @State private var error: String?

    private var isMarkdown: Bool { ["md", "markdown"].contains(item.fileExtension.lowercased()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if isMarkdown, !editing {
                    Picker("", selection: $showMarkdown) {
                        Text("预览").tag(true)
                        Text("源码").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
                if editing {
                    Button("取消") { editing = false }
                    Button("存储") { save() }
                        .keyboardShortcut("s")
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("编辑", systemImage: "pencil") {
                        draft = text
                        editing = true
                    }
                }
            }
            .controlSize(.small)

            Group {
                if editing {
                    TextEditor(text: $draft)
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                } else {
                    ScrollView {
                        Group {
                            if isMarkdown, showMarkdown {
                                MarkdownBlocks(text: text)
                            } else {
                                Text(SyntaxHighlighter.highlight(text)).font(.system(size: 11, design: .monospaced))
                            }
                        }
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(8)
                    }
                }
            }
            .frame(height: 300)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))

            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .task(id: item.url) {
            editing = false
            let url = item.url
            let loaded = await Task.detached { TextFile.read(url) }.value
            text = loaded?.0 ?? "（无法以文本方式读取）"
            encoding = loaded?.1 ?? .utf8
        }
    }

    private func save() {
        do {
            let steps = try TextFile.save(draft, to: item.url, encoding: encoding)
            FileHistory.shared.record("编辑“\(item.name)”", steps: steps)
            text = draft
            editing = false
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Minimal block-level Markdown: headings, lists, quotes, fenced code, rules; inline syntax via AttributedString.
private struct MarkdownBlocks: View {
    let text: String

    private enum Block {
        case heading(Int, String), bullet(String), quote(String), code(String), rule, paragraph(String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var code: [String]?
        for line in text.components(separatedBy: .newlines).prefix(3000) {
            if line.hasPrefix("```") {
                if let lines = code { result.append(.code(lines.joined(separator: "\n"))); code = nil } else { code = [] }
                continue
            }
            if code != nil { code?.append(line); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let hashes = trimmed.firstIndex(where: { $0 != "#" }), trimmed.hasPrefix("#"), trimmed[hashes] == " " {
                result.append(.heading(trimmed.distance(from: trimmed.startIndex, to: hashes), String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces)))
            } else if ["- ", "* ", "+ "].contains(where: trimmed.hasPrefix) {
                result.append(.bullet(String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix(">") {
                result.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if trimmed == "---" || trimmed == "***" {
                result.append(.rule)
            } else {
                result.append(.paragraph(trimmed))
            }
        }
        if let lines = code { result.append(.code(lines.joined(separator: "\n"))) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let content):
                    inline(content).font(.system(size: max(13, 20 - CGFloat(level) * 2), weight: .bold))
                case .bullet(let content):
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); inline(content) }.font(.system(size: 12))
                case .quote(let content):
                    inline(content).font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
                case .code(let content):
                    Text(content).font(.system(size: 11, design: .monospaced))
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                case .rule:
                    Divider()
                case .paragraph(let content):
                    inline(content).font(.system(size: 12))
                }
            }
        }
    }

    private func inline(_ markdown: String) -> Text {
        Text((try? AttributedString(markdown: markdown)) ?? AttributedString(markdown))
    }
}
