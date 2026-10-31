import Foundation

/// Plain text of Word (docx), OpenDocument (odt) and RTF files without the Cocoa text system: where it isn't there
/// (`DigUpPortable`). Paragraphs become lines; formatting, pictures and fields' codes are left out.
public enum RichText {
    public static func text(of url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "docx": return try docx(url)
        case "odt": return try odt(url)
        case "rtf": return rtf([UInt8](try Data(contentsOf: url)))
        default: throw ExtractError.unreadable("not a rich document")
        }
    }

    static func docx(_ url: URL) throws -> String {
        guard let archive = ZipArchive(url), let xml = archive.read("word/document.xml") else {
            throw ExtractError.unreadable("not a Word document")
        }
        // The body, then footnotes and endnotes, which sit in files of their own.
        let parts = [xml] + ["word/footnotes.xml", "word/endnotes.xml"].compactMap(archive.read)
        return parts.map { text(ofXML: $0, words: ["w:t"], paragraphs: ["w:p"], tabs: ["w:tab"], breaks: ["w:br", "w:cr"],
                                    skipped: ["w:instrText", "w:delText"]) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func odt(_ url: URL) throws -> String {
        guard let archive = ZipArchive(url), let xml = archive.read("content.xml") else {
            throw ExtractError.unreadable("not an OpenDocument text")
        }
        return text(ofXML: xml, words: nil, paragraphs: ["text:p", "text:h"], tabs: ["text:tab"],
                    breaks: ["text:line-break"], spaces: "text:s", skipped: ["office:automatic-styles", "office:font-face-decls"])
    }

    /// Text in an XML document: inside `words` elements (all character data when nil), with a line after each of
    /// `paragraphs`, a tab for `tabs`, a line for `breaks`, `text:s c="N"` as N spaces, and nothing from `skipped`.
    static func text(ofXML xml: [UInt8], words: Set<String>?, paragraphs: Set<String>, tabs: Set<String>,
                     breaks: Set<String>, spaces: String? = nil, skipped: Set<String> = []) -> String {
        var out: [UInt8] = []
        var inWords = 0, inSkipped = 0
        var at = 0
        let count = xml.count
        while at < count {
            if xml[at] != UInt8(ascii: "<") {
                let start = at
                while at < count, xml[at] != UInt8(ascii: "<") { at += 1 }
                if inSkipped == 0, words == nil || inWords > 0 { out += xml[start..<at] }
                continue
            }
            // A tag: its name, whether it closes or is empty, and its attributes.
            var end = at + 1
            while end < count, xml[end] != UInt8(ascii: ">") { end += 1 }
            guard end < count else { break }
            let inside = xml[(at + 1)..<end]
            at = end + 1
            guard let first = inside.first, first != UInt8(ascii: "?"), first != UInt8(ascii: "!") else { continue }
            let closing = first == UInt8(ascii: "/")
            let empty = inside.last == UInt8(ascii: "/")
            let nameBytes = inside.drop(while: { $0 == UInt8(ascii: "/") })
                .prefix(while: { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "/") && $0 != 9 && $0 != 10 && $0 != 13 })
            let name = String(decoding: nameBytes, as: UTF8.self)
            if skipped.contains(name) {
                if closing { inSkipped -= 1 } else if !empty { inSkipped += 1 }
                continue
            }
            if words?.contains(name) == true, !empty { inWords += closing ? -1 : 1 }
            guard inSkipped == 0 else { continue }
            if closing {
                if paragraphs.contains(name) { out.append(10) }
            } else if tabs.contains(name) {
                out.append(9)
            } else if breaks.contains(name) || (empty && paragraphs.contains(name)) {
                out.append(10)
            } else if name == spaces {
                let attributes = String(decoding: inside, as: UTF8.self)
                let spaces = attributes.range(of: #"c="(\d+)""#, options: .regularExpression)
                    .flatMap { Int(attributes[$0].filter(\.isNumber)) } ?? 1
                out += [UInt8](repeating: 32, count: min(spaces, 100))
            }
        }
        return clean(decodeEntities(String(decoding: out, as: UTF8.self)))
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = text[...]
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            guard let semi = rest[amp...].prefix(12).firstIndex(of: ";") else {
                result.append("&")
                rest = rest[rest.index(after: amp)...]
                continue
            }
            let entity = rest[rest.index(after: amp)..<semi]
            let scalar: Unicode.Scalar? = switch entity {
            case "amp": "&"
            case "lt": "<"
            case "gt": ">"
            case "quot": "\""
            case "apos": "'"
            default:
                entity.hasPrefix("#x") ? UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
                    : entity.hasPrefix("#") ? UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init) : nil
            }
            if let scalar {
                result.unicodeScalars.append(scalar)
            } else {
                result += rest[amp...semi]
            }
            rest = rest[rest.index(after: semi)...]
        }
        return result + rest
    }

    /// Spaces run together, blank lines dropped, lines trimmed.
    static func clean(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: RTF

    /// Destinations that hold no text of the document.
    private static let hidden: Set<String> = ["fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "header",
                                              "footer", "headerl", "headerr", "footerl", "footerr", "listtable",
                                              "listoverridetable", "rsidtbl", "generator", "themedata", "colorschememapping",
                                              "latentstyles", "datastore", "xmlnstbl", "filetbl", "revtbl", "fldinst"]

    /// The text of an RTF document: control words dropped, `\par` and `\line` as lines, `\tab` as tabs, `\uN` as that
    /// character (skipping its `\ucN` fallback), and the rest, `\'hh` or not, read in the code page of its font's
    /// `\fcharset` (Shift-JIS for Japanese, say) or else the document's `\ansicpg`.
    static func rtf(_ bytes: [UInt8]) -> String {
        struct Group {
            var hidden = false
            var skip = 1
            var font: Int?
            var inFontTable = false
        }
        var stack = [Group()]
        var out = ""
        var pending: [UInt8] = []   // text bytes in `encoding`, decoded together (a code page of two-byte characters)
        var documentPage = 1252
        var fontPages: [Int: Int] = [:]
        var defaultFont: Int?
        var definingFont: Int?
        var skipFallback = 0
        func encoding() -> String.Encoding {
            codePage((stack[stack.count - 1].font ?? defaultFont).flatMap { fontPages[$0] } ?? documentPage)
        }
        func flush() {
            guard !pending.isEmpty else { return }
            out += String(bytes: pending, encoding: encoding()) ?? String(decoding: pending, as: UTF8.self)
            pending = []
        }
        func emit(_ text: String) {
            guard !stack[stack.count - 1].hidden else { return }
            flush()
            out += text
        }
        func isLetter(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
        }
        var at = 0
        while at < bytes.count {
            let byte = bytes[at]
            switch byte {
            case UInt8(ascii: "{"):
                flush()
                stack.append(stack[stack.count - 1])
                at += 1
                // {\*\destination ...}: one we don't know, so its text isn't the document's.
                if at + 1 < bytes.count, bytes[at] == UInt8(ascii: "\\"), bytes[at + 1] == UInt8(ascii: "*") {
                    stack[stack.count - 1].hidden = true
                }
            case UInt8(ascii: "}"):
                flush()
                if stack.count > 1 { stack.removeLast() }
                at += 1
            case UInt8(ascii: "\\"):
                at += 1
                guard at < bytes.count else { break }
                let next = bytes[at]
                if next == UInt8(ascii: "'"), at + 2 < bytes.count {
                    let hex = String(decoding: bytes[(at + 1)...(at + 2)], as: UTF8.self)
                    at += 3
                    if skipFallback > 0 { skipFallback -= 1; continue }
                    if let value = UInt8(hex, radix: 16), !stack[stack.count - 1].hidden { pending.append(value) }
                    continue
                }
                guard isLetter(next) else {
                    // A control symbol: \\ \{ \} as themselves, \~ a space, \- and the rest nothing.
                    switch next {
                    case UInt8(ascii: "\\"), UInt8(ascii: "{"), UInt8(ascii: "}"):
                        if !stack[stack.count - 1].hidden { pending.append(next) }
                    case UInt8(ascii: "~"): emit(" ")
                    case 10, 13: emit("\n")
                    default: break
                    }
                    at += 1
                    continue
                }
                var end = at
                while end < bytes.count, isLetter(bytes[end]) { end += 1 }
                let word = String(decoding: bytes[at..<end], as: UTF8.self)
                var numberEnd = end
                if numberEnd < bytes.count, bytes[numberEnd] == UInt8(ascii: "-") { numberEnd += 1 }
                while numberEnd < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[numberEnd]) {
                    numberEnd += 1
                }
                let parameter = Int(String(decoding: bytes[end..<numberEnd], as: UTF8.self))
                at = numberEnd
                if at < bytes.count, bytes[at] == 32 { at += 1 }   // the delimiting space is part of the word
                if word == "fonttbl" { stack[stack.count - 1].inFontTable = true }
                if hidden.contains(word) { stack[stack.count - 1].hidden = true; continue }
                switch word {
                case "par", "line", "row", "page", "sect": emit("\n")
                case "tab", "cell": emit("\t")
                case "emdash": emit("—")
                case "endash": emit("–")
                case "bullet": emit("•")
                case "lquote": emit("‘")
                case "rquote": emit("’")
                case "ldblquote": emit("“")
                case "rdblquote": emit("”")
                case "uc": stack[stack.count - 1].skip = parameter ?? 1
                case "u":
                    if var value = parameter {
                        if value < 0 { value += 65_536 }
                        emit(Unicode.Scalar(UInt32(value)).map { String(Character($0)) } ?? "")
                        skipFallback = stack[stack.count - 1].skip
                    }
                case "ansicpg": if let parameter { documentPage = parameter }
                case "deff": defaultFont = parameter
                case "f":
                    if stack[stack.count - 1].inFontTable {
                        definingFont = parameter
                    } else {
                        flush()
                        stack[stack.count - 1].font = parameter
                    }
                case "fcharset":
                    if let font = definingFont, let parameter, let page = charsetPages[parameter] {
                        fontPages[font] = page
                    }
                case "cpg":
                    if let font = definingFont, let parameter { fontPages[font] = parameter }
                default: break
                }
            case 10, 13:
                at += 1
            default:
                var end = at
                while end < bytes.count, ![UInt8(ascii: "\\"), UInt8(ascii: "{"), UInt8(ascii: "}"), 10, 13].contains(bytes[end]) {
                    end += 1
                }
                var start = at
                while skipFallback > 0, start < end { start += 1; skipFallback -= 1 }
                if start < end, !stack[stack.count - 1].hidden { pending += bytes[start..<end] }
                at = end
            }
        }
        flush()
        return clean(out.replacingOccurrences(of: "\t", with: " "))
    }

    /// `\fcharset` to the Windows code page it means (0, ANSI, is the document's `\ansicpg`).
    private static let charsetPages: [Int: Int] = [77: 10000, 128: 932, 129: 949, 130: 1361, 134: 936, 136: 950,
                                                   161: 1253, 162: 1254, 163: 1258, 177: 1255, 178: 1256, 186: 1257,
                                                   204: 1251, 222: 874, 238: 1250]

    /// A Windows code page as a String.Encoding: CoreFoundation's encodings (kCFStringEncoding…, flagged as NSString
    /// raw values), which Foundation decodes on every platform.
    static func codePage(_ page: Int) -> String.Encoding {
        let foundation: [Int: String.Encoding] = [
            1250: .windowsCP1250, 1251: .windowsCP1251, 1252: .windowsCP1252, 1253: .windowsCP1253,
            1254: .windowsCP1254, 932: .shiftJIS, 10000: .macOSRoman, 65001: .utf8,
        ]
        if let encoding = foundation[page] { return encoding }
        let coreFoundation: [Int: UInt] = [
            936: 0x0421, 949: 0x0422, 950: 0x0423, 874: 0x041D, 1255: 0x0505, 1256: 0x0506, 1257: 0x0507, 1258: 0x0508,
            1361: 0x0424, 437: 0x0400, 850: 0x0410, 852: 0x0411, 866: 0x0413,
        ]
        guard let value = coreFoundation[page] else { return .windowsCP1252 }
        return String.Encoding(rawValue: 0x8000_0000 | value)
    }
}
