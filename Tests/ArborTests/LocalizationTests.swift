import XCTest
@testable import Arbor

/// Every `L("…")` in the app has an English translation, and translations keep their placeholders.
final class LocalizationTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static var english: [String: String] {
        let path = root.appendingPathComponent("Resources/en.lproj/Localizable.strings").path
        return NSDictionary(contentsOfFile: path) as? [String: String] ?? [:]
    }

    @MainActor func testEveryStringHasEnglish() throws {
        let english = Self.english
        XCTAssertGreaterThan(english.count, 500)
        let sources = FileManager.default.enumerator(at: Self.root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
        var keys: [String: String] = [:]
        for case let url as URL in sources where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for key in LiteralScanner(text).localizedKeys() { keys[key] = url.lastPathComponent }
        }
        XCTAssertGreaterThan(keys.count, 500)
        // Settings stores these by their Chinese names and shows them through L(key:).
        for id in ContextMenuBuilder.customizable { keys[id] = "ContextMenuBuilder.customizable" }
        for entry in ShortcutCatalog.entries { keys[entry.title] = "ShortcutCatalog" }

        let missing = keys.filter { english[$0.key] == nil }.map { "\($0.value): \($0.key)" }.sorted()
        XCTAssert(missing.isEmpty, "No English for:\n" + missing.joined(separator: "\n"))
        let unused = english.keys.filter { keys[$0] == nil }.sorted()
        XCTAssert(unused.isEmpty, "Translations nothing uses:\n" + unused.joined(separator: "\n"))
    }

    func testTranslationsKeepTheirPlaceholders() {
        for (key, value) in Self.english {
            let wanted = key.components(separatedBy: "%@").count - 1
            let plain = value.components(separatedBy: "%@").count - 1
            let positional = (1...9).filter { value.contains("%\($0)$@") }.count
            XCTAssertEqual(plain + positional, wanted, "\(key) → \(value)")
            XCTAssertEqual(key.contains("%.1f"), value.contains("%.1f"), key)
        }
    }

    func testFillingIn() {
        XCTAssertEqual(Localization.fill("%@ {file|files}", ["1"]), "1 file")
        XCTAssertEqual(Localization.fill("%@ {file|files}", ["12"]), "12 files")
        XCTAssertEqual(Localization.fill("%2$@ in %1$@ {folder|folders}", ["3", "a"]), "a in 3 folders")
        XCTAssertEqual(Localization.fill("%@% used", ["42"]), "42% used")
        XCTAssertEqual(Localization.fill("已选 %@ / %@ 项", ["2", "9"]), "已选 2 / 9 项")
    }

    func testKeysFromInterpolation() {
        let count = 3, name = "Docs"
        XCTAssertEqual(LocalizedText("\(count) 个文件，在“\(name)”").key, "%@ 个文件，在“%@”")
        XCTAssertEqual(L("\(count) 个文件"), "3 个文件") // tests run outside the app bundle: Chinese
        XCTAssertEqual(L(key: "图片##places"), "图片")
    }

    func testScannerReadsKeysLikeTheCompiler() {
        let source = #"""
        // L("注释")
        let a = L("你好 \(name)！\n")
        let b = L("外 \(flag ? L("内") : "x") 尾")
        /* L("块注释") */ let c = "不翻译"
        """#
        XCTAssertEqual(Set(LiteralScanner(source).localizedKeys()), ["你好 %@！\n", "外 %@ 尾", "内"])
    }
}

/// Finds the keys of `L("…")` literals in Swift source: the literal text with each interpolation as `%@`.
/// Skips comments; handles interpolations that contain strings (and `L(…)` calls) of their own.
struct LiteralScanner {
    private let chars: [Character]
    private var keys: [String] = []

    init(_ source: String) { chars = Array(source) }

    func localizedKeys() -> [String] {
        var scanner = self
        _ = scanner.scanCode(from: 0, untilClosingParen: false)
        return scanner.keys
    }

    private func starts(_ text: String, at index: Int) -> Bool {
        let pattern = Array(text)
        guard index + pattern.count <= chars.count else { return false }
        return Array(chars[index..<index + pattern.count]) == pattern
    }

    /// Returns the index of the `)` that ends an interpolation, or the end of the source.
    private mutating func scanCode(from start: Int, untilClosingParen: Bool) -> Int {
        var index = start
        var depth = 0
        while index < chars.count {
            if starts("//", at: index) {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            if starts("/*", at: index) {
                var nesting = 0
                while index < chars.count {
                    if starts("/*", at: index) { nesting += 1; index += 2 } else if starts("*/", at: index) {
                        nesting -= 1; index += 2
                        if nesting == 0 { break }
                    } else { index += 1 }
                }
                continue
            }
            let character = chars[index]
            if character == "\"" {
                let isLocalized = index >= 2 && chars[index - 2] == "L" && chars[index - 1] == "("
                    && (index < 3 || !(chars[index - 3].isLetter || chars[index - 3].isNumber))
                let (key, end) = scanLiteral(from: index)
                if isLocalized { keys.append(key) }
                index = end
                continue
            }
            if untilClosingParen {
                if character == "(" { depth += 1 }
                if character == ")" {
                    if depth == 0 { return index }
                    depth -= 1
                }
            }
            index += 1
        }
        return index
    }

    /// Reads a one-line string literal starting at its opening quote; returns its key and the index after it.
    private mutating func scanLiteral(from start: Int) -> (String, Int) {
        var index = start + 1
        var key = ""
        while index < chars.count, chars[index] != "\"" {
            if chars[index] == "\\" {
                let next = chars[index + 1]
                switch next {
                case "(":
                    key += "%@"
                    index = scanCode(from: index + 2, untilClosingParen: true) + 1
                    continue
                case "n": key += "\n"
                case "t": key += "\t"
                case "0": key += "\0"
                case "u":
                    let close = chars[index...].firstIndex(of: "}")!
                    let hex = String(chars[(index + 3)..<close])
                    key += String(Character(Unicode.Scalar(UInt32(hex, radix: 16)!)!))
                    index = close + 1
                    continue
                default: key.append(next)
                }
                index += 2
                continue
            }
            key.append(chars[index])
            index += 1
        }
        return (key, index + 1)
    }
}
