import Foundation
import Security

/// The OpenRouter API key, in the Keychain. An empty field removes it. Queries are sent only when one is saved.
nonisolated enum OpenRouterKey {
    private static let service = "com.abdurrahim.DigUpPhotos.openrouter"
    private static let account = "apiKey"

    static func load() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8) else { return "" }
        return key
    }

    static func save(_ key: String) {
        let trimmed = normalize(key)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !trimmed.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Drops a copied "Bearer " prefix and surrounding quotes.
    static func normalize(_ key: String) -> String {
        var text = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") { text = String(text.dropFirst().dropLast()) }
        if text.lowercased().hasPrefix("bearer ") {
            text = String(text.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Nil when the text is empty or looks like an OpenRouter key. A message when it doesn't.
    static func formatProblem(_ key: String) -> String? {
        if key.isEmpty { return nil }
        if !key.hasPrefix("sk-or-") { return "OpenRouter keys start with sk-or-." }
        if key.count < 30 { return "This key looks incomplete." }
        return nil
    }

    /// True when the key is worth sending. A half-typed field never calls the API.
    static func usable(_ key: String) -> Bool {
        let key = normalize(key)
        return !key.isEmpty && formatProblem(key) == nil
    }

    /// Asks OpenRouter whether the key is accepted. The message is what Settings shows.
    static func verify(_ key: String) async -> (ok: Bool, message: String) {
        let key = normalize(key)
        if key.isEmpty { return (false, "Off. Questions are searched as you type them.") }
        if let problem = formatProblem(key) { return (false, problem) }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: return (true, "Key works.")
            case 401: return (false, "OpenRouter rejected this key.")
            case 402: return (false, "OpenRouter says this key has no credit.")
            default: return (false, "OpenRouter returned \(status).")
            }
        } catch {
            return (false, "Couldn't reach OpenRouter.")
        }
    }
}

/// A typed question after Luna, if a key is saved. `search` is what gets embedded.
nonisolated struct QueryReading: Sendable, Equatable {
    var search: String
    /// The formal line, when it differs from what was typed.
    var interpreted: String?
    /// Why the line was not searched, or why OpenRouter refused.
    var note: String?

    static func asTyped(_ text: String) -> QueryReading {
        QueryReading(search: text, interpreted: nil, note: nil)
    }

    static func note(for error: Error) -> String {
        if let error = error as? RewriteError {
            switch error {
            case .rejected(401): return "OpenRouter rejected the API key."
            case .rejected(402): return "OpenRouter says this key has no credit."
            case .rejected(let status): return "OpenRouter returned \(status)."
            }
        }
        return "Couldn't reach OpenRouter."
    }
}

/// Turns a typed photo question into `and` / `or` / `-` with Luna (`openai/gpt-5.6-luna`).
nonisolated enum QueryRewrite {
    private static let instructions = """
        Rewrite a photo search into one formal query line.
        - and: both things must match
        - or: either thing is enough
        - a leading hyphen hides that thing: without, except, not, no, minus, bez, poza, nie, and "but not"
        - "without A or B" hides both A and B
        - a hyphen inside a word stays: well-known
        - a plain description stays as written
        - parentheses group an or that is also hidden
        Output only the formal query. No explanation.

        photos of a wedding without the cake
        photos of a wedding - cake

        a bird or a plane but not a kite
        (a bird or a plane) - a kite
        """

    /// What Luna said, and whether every word of it came from the question (plus a, an, the).
    struct Reply: Sendable {
        var line: String
        var trusted: Bool
    }

    /// Luna's line, or a thrown error when OpenRouter refuses the call.
    static func line(_ typed: String, apiKey: String) async throws -> Reply? {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "openai/gpt-5.6-luna",
            "max_tokens": 80,
            "temperature": 0,
            "reasoning": ["effort": "none"],
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": typed],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw RewriteError.rejected(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        let formal = content.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !formal.isEmpty else { return nil }
        return Reply(line: formal, trusted: accepts(formal, for: typed))
    }

    /// Every word of the rewrite has to come from the question. `and`, `or`, a leading hyphen, and a/an/the are allowed.
    static func accepts(_ formal: String, for typed: String) -> Bool {
        guard formal.count <= 400, !formal.contains(". ") else { return false }
        let fillers: Set<String> = ["a", "an", "the"]
        let source = Set(words(typed))
        for word in words(formal) where word != "and" && word != "or" && !fillers.contains(word) {
            let bare = word.hasPrefix("-") ? String(word.dropFirst()) : word
            if !bare.isEmpty, !fillers.contains(bare), !source.contains(bare) { return false }
        }
        return true
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "-") }.map(String.init)
    }
}

private nonisolated enum RewriteError: Error, CustomStringConvertible {
    case rejected(Int)

    var description: String {
        switch self {
        case .rejected(let status): return "OpenRouter returned \(status)"
        }
    }
}
