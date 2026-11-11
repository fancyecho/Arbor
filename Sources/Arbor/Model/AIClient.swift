import Foundation
import Security

/// Which kind of API the user's model speaks.
enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Anthropic's Messages API.
    case anthropic
    /// `/chat/completions` as offered by OpenAI, DeepSeek, Qwen, Kimi, OpenRouter, Ollama, LM Studio…
    case openAICompatible

    var id: Self { self }

    var title: String {
        switch self {
        case .anthropic: "Anthropic (Claude)"
        case .openAICompatible: L("OpenAI 兼容接口")
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .anthropic: "https://api.anthropic.com"
        case .openAICompatible: "https://api.openai.com/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: "claude-opus-5-5"
        case .openAICompatible: ""
        }
    }
}

/// The user's model settings. The API key lives in the Keychain, never in defaults.
struct AIConfig: Equatable, Sendable {
    var provider: AIProvider
    var baseURL: String
    var model: String
    var apiKey: String

    /// Local servers (Ollama, LM Studio) don't need a key.
    var isUsable: Bool {
        !model.trimmingCharacters(in: .whitespaces).isEmpty && URL(string: baseURL) != nil
            && (!apiKey.isEmpty || isLocal)
    }

    var isLocal: Bool {
        guard let host = URL(string: baseURL)?.host() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }
}

enum AIError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case refused
    case badReply(String)
    /// The model answered, but not with a JSON object (or with nothing but whitespace).
    case unreadable(raw: String)
    case truncated

    /// A readable piece of a reply: whitespace collapsed, nil when there's nothing but whitespace.
    static func snippet(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return words.count > 160 ? String(words.prefix(160)) + "…" : words
    }

    var errorDescription: String? {
        switch self {
        case .notConfigured: L("还没有设置大模型。在「设置 › AI」里填写接口和密钥。")
        case .http(let code, let message): L("接口返回了错误（\(code)）：\(message)")
        case .refused: L("模型拒绝了这个请求。")
        case .badReply(let detail): L("没看懂模型的回复：\(detail)")
        case .unreadable(let raw):
            Self.snippet(raw).map { L("模型的回复不是要求的格式：\($0)") } ?? L("模型返回了空白内容。换个模型，或者稍后再试。")
        case .truncated: L("模型的回复被截断了，请再试一次。")
        }
    }
}

/// Sends one request and returns the model's JSON reply as an object.
enum AIClient {
    /// `schema` is a JSON Schema for the reply; Anthropic enforces it, OpenAI-compatible servers get it in
    /// the prompt and are asked for a JSON object.
    static func json(system: String, user: String, schema: [String: Any], config: AIConfig,
                     maxTokens: Int = 4096) async throws -> [String: Any] {
        try await conversation(system: system, messages: [("user", user)], schema: schema, config: config, maxTokens: maxTokens)
    }

    /// A multi-turn exchange (`messages` alternate user / assistant, starting and ending with the user).
    static func conversation(system: String, messages: [(role: String, content: String)], schema: [String: Any],
                             config: AIConfig, maxTokens: Int = 4096) async throws -> [String: Any] {
        guard config.isUsable else { throw AIError.notConfigured }
        let turns = merged(messages)
        let text: String
        switch config.provider {
        case .anthropic: text = try await anthropic(system: system, messages: turns, schema: schema, config: config, maxTokens: maxTokens)
        case .openAICompatible: text = try await openAI(system: system, messages: turns, schema: schema, config: config, maxTokens: maxTokens)
        }
        return try parseObject(text)
    }

    /// Joins consecutive messages from the same side (the APIs want them to alternate).
    static func merged(_ messages: [(role: String, content: String)]) -> [[String: String]] {
        var result: [[String: String]] = []
        for message in messages {
            if let last = result.last, last["role"] == message.role {
                result[result.count - 1]["content"] = (last["content"] ?? "") + "\n\n" + message.content
            } else {
                result.append(["role": message.role, "content": message.content])
            }
        }
        return result
    }

    /// The JSON object in a reply. Tolerates reasoning models' `<think>` blocks, ```json fences, chatter around
    /// the object, and (as a last resort) JSON5 leniencies such as trailing commas.
    static func parseObject(_ text: String) throws -> [String: Any] {
        var body = text
        // Reasoning models put their thinking in the content: drop it (and an unfinished block).
        while let open = body.range(of: "<think>") {
            if let close = body.range(of: "</think>", range: open.upperBound..<body.endIndex) {
                body.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                body.removeSubrange(open.lowerBound..<body.endIndex)
            }
        }
        body = body.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        for candidate in objectCandidates(in: body) {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
            if let object = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: Any] {
                return object
            }
        }
        throw AIError.unreadable(raw: text)
    }

    /// Every balanced `{…}` in the text, outermost first, ignoring braces inside strings.
    static func objectCandidates(in text: String) -> [String] {
        let chars = Array(text)
        var result: [String] = []
        var index = 0
        while index < chars.count {
            guard chars[index] == "{" else { index += 1; continue }
            var depth = 0, inString = false, escaped = false, end: Int?
            for j in index..<chars.count {
                let c = chars[j]
                if inString {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                    continue
                }
                if c == "\"" { inString = true } else if c == "{" { depth += 1 } else if c == "}" {
                    depth -= 1
                    if depth == 0 { end = j; break }
                }
            }
            if let end {
                result.append(String(chars[index...end]))
                index = end + 1
            } else {
                // Never closed (cut off): still worth a lenient try.
                result.append(String(chars[index...]))
                break
            }
        }
        return result
    }

    // MARK: Anthropic

    /// Models that take `fallbacks: "default"` (a declined request is re-run on another model server-side).
    private static let fallbackModels = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    private static func anthropic(system: String, messages: [[String: String]], schema: [String: Any], config: AIConfig,
                                  maxTokens: Int) async throws -> String {
        let url = endpoint(config.baseURL, path: "v1/messages")
        var request = URLRequest(url: url, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages,
            // Short, well-defined jobs: low effort keeps the bar snappy.
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]],
        ]
        let official = url.host() == "api.anthropic.com"
        if official, fallbackModels.contains(config.model) {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let reply = try await send(request)
        if reply["stop_reason"] as? String == "refusal" { throw AIError.refused }
        if reply["stop_reason"] as? String == "max_tokens" { throw AIError.truncated }
        let blocks = reply["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIError.unreadable(raw: "") }
        return text
    }

    // MARK: OpenAI-compatible

    private static func openAI(system: String, messages: [[String: String]], schema: [String: Any], config: AIConfig,
                               maxTokens: Int) async throws -> String {
        var request = URLRequest(url: endpoint(config.baseURL, path: "chat/completions"), timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if !config.apiKey.isEmpty { request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "authorization") }
        let schemaText = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "messages": [["role": "system", "content": system + "\n\nReply with one JSON object only, matching this JSON Schema:\n" + schemaText]]
                + messages,
            "response_format": ["type": "json_object"],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let reply = try await send(request)
        guard let choice = (reply["choices"] as? [[String: Any]])?.first else { throw AIError.badReply(L("没有返回内容")) }
        if choice["finish_reason"] as? String == "length" { throw AIError.truncated }
        // Reasoning models (DeepSeek-R1, QwQ…) may return only `reasoning_content` and an empty answer.
        guard let message = choice["message"] as? [String: Any], let text = message["content"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.unreadable(raw: "")
        }
        return text
    }

    // MARK: HTTP

    /// `https://host/v1` + `chat/completions`, without doubling or dropping slashes.
    static func endpoint(_ base: String, path: String) -> URL {
        var base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        // Anthropic base URLs are usually given without /v1; don't add it twice.
        if path.hasPrefix("v1/"), base.hasSuffix("/v1") { base.removeLast(3) }
        return URL(string: base + "/" + path) ?? URL(string: "https://invalid.invalid")!
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let error = object?["error"]
            let message = (error as? [String: Any])?["message"] as? String ?? (error as? String)
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw AIError.http(status, message)
        }
        guard let object else { throw AIError.badReply(String(decoding: data.prefix(160), as: UTF8.self)) }
        return object
    }
}

// MARK: - Keychain

/// The API key, stored as a generic password in the login keychain.
enum AIKeychain {
    private static let service = "app.arbor.Arbor.ai"

    static func load(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ key: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
