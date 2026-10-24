import AppKit

/// Arbor's user-visible text is written in Chinese in the source; `L("…")` returns it in the app's language.
///
/// English lives in `Resources/en.lproj/Localizable.strings`, keyed by the Chinese text. Interpolated values
/// become `%@` in the key (`L("\(n) 个文件")` looks up `"%@ 个文件"`), whatever their type, and translations
/// place them with `%@` or, to reorder, `%1$@`, `%2$@`. A translation can follow a number with
/// `{singular|plural}` — `"%@ {file|files}"` — chosen by whether the value before it is 1.
///
/// The language is chosen once per launch (Settings › 通用 › 语言), like the system's own app language setting:
/// menus, alerts and system panels follow the same choice.
func L(_ text: LocalizedText) -> String {
    Localization.translate(text.key, text.arguments)
}

/// Looks up text that isn't a literal at the call site, e.g. a stored command name.
func L(key: String) -> String {
    Localization.translate(key, [])
}

struct LocalizedText: ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]

    init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    init(stringInterpolation: Interpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    struct Interpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        init(literalCapacity: Int, interpolationCount: Int) {}

        mutating func appendLiteral(_ literal: String) { key += literal }

        mutating func appendInterpolation(_ value: some Any) {
            key += "%@"
            arguments.append(String(describing: value))
        }

        mutating func appendInterpolation(_ value: String) {
            key += "%@"
            arguments.append(value)
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, chinese = "zh-Hans", english = "en"

    var id: Self { self }

    /// Each language names itself; "follow the system" is said in the current language.
    var title: String {
        switch self {
        case .system: L("跟随系统")
        case .chinese: "简体中文"
        case .english: "English"
        }
    }

    /// What Settings shows as chosen: the per-app `AppleLanguages` override, if it names one of ours.
    static var chosen: AppLanguage {
        guard let first = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"]
                as? [String], let code = first.first else { return .system }
        if code.hasPrefix("en") { return .english }
        if code.hasPrefix("zh") { return .chinese }
        return .system
    }

    /// Whether Arbor would run in English with this choice.
    var runsInEnglish: Bool {
        switch self {
        case .english: return true
        case .chinese: return false
        case .system:
            // The system-wide list, not this app's override.
            let languages = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                                   kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
            let match = languages.first { $0.hasPrefix("en") || $0.hasPrefix("zh") }
            return !(match?.hasPrefix("zh") ?? false)
        }
    }

    /// Arbor was Chinese-only before 1.0.5. People who already use it keep Chinese until they choose
    /// otherwise; new installs follow the system. Runs before anything is localized, so it applies at once.
    static func settleFirstLaunch() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "languageSettled") else { return }
        let domain = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        defaults.set(true, forKey: "languageSettled")
        if domain["AppleLanguages"] == nil, !domain.isEmpty {
            defaults.set([AppLanguage.chinese.rawValue], forKey: "AppleLanguages")
        }
    }

    /// Takes effect at the next launch (the same as choosing an app's language in System Settings).
    static func choose(_ language: AppLanguage) {
        if language == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
}

enum Localization {
    /// The language this launch runs in.
    static let isEnglish: Bool = {
        if let forced = ProcessInfo.processInfo.environment["ARBOR_LANGUAGE"] { return forced.hasPrefix("en") }
        return Bundle.main.preferredLocalizations.first?.hasPrefix("en") ?? false
    }()

    /// Chinese source text → English. Empty when running in Chinese (or outside the app bundle, e.g. tests).
    nonisolated(unsafe) static var table: [String: String] = isEnglish ? englishTable() : [:]

    static func englishTable() -> [String: String] {
        guard let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en")
                ?? ProcessInfo.processInfo.environment["ARBOR_STRINGS"],
              let table = NSDictionary(contentsOfFile: path) as? [String: String] else { return [:] }
        return table
    }

    /// A key can end in `##context` to tell apart Chinese words that English says differently
    /// (`"图片##places"` is the Pictures folder, `"图片"` the Images category); Chinese drops the suffix.
    static func translate(_ key: String, _ arguments: [String]) -> String {
        let text = table[key] ?? key.components(separatedBy: "##")[0]
        return arguments.isEmpty && !text.contains("{") ? text : fill(text, arguments)
    }

    /// Puts the arguments in place of `%@` / `%n$@`, then settles `{singular|plural}` choices.
    static func fill(_ template: String, _ arguments: [String]) -> String {
        var result = ""
        var next = 0
        var lastArgument: String?
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            if character == "%" {
                let rest = template[template.index(after: index)...]
                if rest.hasPrefix("@") {
                    let value = next < arguments.count ? arguments[next] : ""
                    next += 1
                    result += value
                    lastArgument = value
                    index = template.index(index, offsetBy: 2)
                    continue
                }
                if let dollar = rest.firstIndex(of: "$"), let position = Int(rest[rest.startIndex..<dollar]),
                   template[template.index(after: dollar)...].hasPrefix("@") {
                    let value = position - 1 < arguments.count && position > 0 ? arguments[position - 1] : ""
                    result += value
                    lastArgument = value
                    index = template.index(dollar, offsetBy: 2)
                    continue
                }
            }
            if character == "{", let close = template[index...].firstIndex(of: "}"),
               let bar = template[index..<close].firstIndex(of: "|") {
                let singular = template[template.index(after: index)..<bar]
                let plural = template[template.index(after: bar)..<close]
                let isOne = lastArgument.map { $0.trimmingCharacters(in: .whitespaces) == "1" } ?? false
                result += isOne ? singular : plural
                index = template.index(after: close)
                continue
            }
            result.append(character)
            index = template.index(after: index)
        }
        return result
    }
}
