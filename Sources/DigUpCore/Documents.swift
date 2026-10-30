import Foundation

public enum DocExtractor {
    /// A text file in the encoding it says it's in, else Latin-1.
    public static func readText(_ url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        return try String(contentsOf: url, encoding: .isoLatin1)
    }

    /// Good enough for search: drops scripts, styles and comments, turns block ends into line breaks, strips the
    /// remaining tags, and decodes common entities.
    public static func plainText(fromHTML html: String) -> String {
        var text = html
        for pattern in [#"(?is)<script\b.*?</script\s*>"#, #"(?is)<style\b.*?</style\s*>"#, #"(?s)<!--.*?-->"#,
                        #"(?is)<head\b.*?</head\s*>"#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<(br|/p|/div|/li|/h[1-6]|/tr|/section|/article)\b[^>]*>"#,
                                         with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                        "&apos;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (entity, character) in entities { text = text.replacingOccurrences(of: entity, with: character) }
        text = decodeNumericEntities(text)
        return text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\n\s*"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        guard text.contains("&#") else { return text }
        let pattern = try! NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")
        var result = ""
        var last = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let codeRange = Range(match.range(at: 1), in: text)
            else { continue }
            let code = text[codeRange]
            let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
            result += text[last..<range.lowerBound]
            result += value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? " "
            last = range.upperBound
        }
        return result + text[last...]
    }

    /// Splits text into ~`size`-character pieces (~450 tokens) that overlap a little, breaking at whitespace.
    public static func chunks(_ text: String, size: Int = 1800, overlap: Int = 200, limit: Int) -> [String] {
        let clean = text
            .replacingOccurrences(of: #"[ \t\u{00A0}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n\s*\n\s*\n+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var chunks: [String] = []
        var start = clean.startIndex
        while start < clean.endIndex, chunks.count < limit {
            var end = clean.index(start, offsetBy: size, limitedBy: clean.endIndex) ?? clean.endIndex
            if end < clean.endIndex, let space = clean[start..<end].lastIndex(where: \.isWhitespace),
               clean.distance(from: start, to: space) > size / 2 {
                end = space
            }
            let chunk = clean[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(chunk) }
            guard end < clean.endIndex else { break }
            var next = clean.index(end, offsetBy: -overlap, limitedBy: start) ?? end
            if next <= start { next = end }
            // Start the next chunk on a word boundary.
            while next < end, !clean[next].isWhitespace { next = clean.index(after: next) }
            start = next < end ? next : end
        }
        return chunks
    }
}

/// One line, at most `limit` characters: for result lists.
func excerpt(_ text: String, limit: Int = 240) -> String {
    let line = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    return line.count > limit ? String(line.prefix(limit)) + "…" : line
}
