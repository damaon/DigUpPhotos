import Foundation
import Testing
@testable import DigUpCore

/// Fixtures/sample.* were made from one HTML page by macOS's textutil, so they are what Word, Pages and TextEdit write.
@Suite struct RichTextTests {
    static func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    @Test(arguments: ["sample.docx", "sample.odt", "sample.rtf"])
    func readsWhatCocoaReads(name: String) throws {
        let lines = try RichText.text(of: Self.fixture(name)).split(separator: "\n").map {
            $0.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces)
        }
        #expect(lines.first == "Faktura za remont łazienki")
        #expect(lines.contains("Zażółć gęślą jaźń & “cudzysłów” — myślnik."))
        #expect(lines.contains { $0.hasPrefix("Kwota:") && $0.hasSuffix("1 250 zł") })
        #expect(lines.contains { $0.hasSuffix("płytki") })
        #expect(lines.last == "Ostatni akapit.")
    }

    @Test func inflatesWhatZlibDeflates() {
        // zlib.compressobj(9, DEFLATED, -15) of "Zazolc gesla jazn. " × 20 + "The end." (fixed codes, back-references).
        let deflated: [UInt8] = [139, 74, 172, 202, 207, 73, 86, 72, 79, 45, 206, 73, 84, 200, 74, 172, 202, 211, 83, 136,
                                 26, 21, 162, 143, 80, 72, 70, 170, 66, 106, 94, 138, 30, 0]
        let expected = String(repeating: "Zazolc gesla jazn. ", count: 20) + "The end."
        #expect(Inflate.inflate(deflated[...]).map { String(decoding: $0, as: UTF8.self) } == expected)
        #expect(Inflate.inflate(deflated.dropLast(5)) == nil)
    }

    @Test func rtfKeepsUnicodeAndCodePages() {
        let rtf = #"{\rtf1\ansi\ansicpg1250{\fonttbl\f0 Arial;}{\*\generator x;}Za\'bf\'f3\'b3\'e6 \u281?\uc2\u347xx\par drugi}"#
        #expect(RichText.rtf(Array(rtf.utf8)) == "Zażółć ęś\ndrugi")
    }

    /// Japanese, Chinese, Korean and Thai RTF name their code page by the font's \\fcharset.
    @Test(arguments: [(128, "\\'93\\'fa\\'96\\'7b", "日本"), (134, "\\'d6\\'d0\\'ce\\'c4", "中文"),
                      (129, "\\'c7\\'d1\\'b1\\'b9", "한국"), (222, "\\'e4\\'b7\\'c2", "ไทย")])
    func rtfReadsFontCharsets(charset: Int, bytes: String, text: String) {
        let rtf = "{\\rtf1\\ansi\\ansicpg1252{\\fonttbl\\f0\\fnil\\fcharset0 A;\\f1\\fnil\\fcharset\(charset) B;}"
            + "\\f0 x \\f1 \(bytes)\\f0  y}"
        #expect(RichText.rtf(Array(rtf.utf8)) == "x \(text) y")
    }

    @Test func xmlEntitiesAndSpaces() {
        let xml = Array(#"<a><text:p>a<text:s c="3"/>b &amp; &#x142;</text:p><text:p/><text:h>c</text:h></a>"#.utf8)
        #expect(RichText.text(ofXML: xml, words: nil, paragraphs: ["text:p", "text:h"], tabs: [], breaks: [],
                              spaces: "text:s") == "a b & ł\nc")
    }
}
