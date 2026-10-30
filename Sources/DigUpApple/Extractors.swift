import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision
import DigUpCore

enum ImageExtractor {
    /// Writes a downscaled copy for the model. ImageIO decodes straight to the thumbnail size, so a 48 MP photo never
    /// gets decoded at full resolution. HEIC, RAW, WebP and friends all work. Capture date and GPS stay with the
    /// original file's properties (not the thumbnail). Photos also get a local quality score and face crops.
    static func prepare(_ url: URL, maxPixel: Int, minSide: Int, to folder: URL, png: Bool,
                        scoreQuality: Bool = false, detectFaces: Bool = false) throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ExtractError.unreadable("not an image") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard max(width, height) >= minSide else { throw ExtractError.tooSmall(width, height) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw ExtractError.unreadable("can't decode image") }
        let faces = detectFaces ? FaceDetector.detect(in: thumbnail, source: source) : []
        // One detection: quality scoring uses those boxes instead of asking Vision again.
        let quality = scoreQuality
            ? PhotoQuality.assess(thumbnail, detectFaces: false, faceBoxes: faces.map(\.box))
            : nil
        let out = folder.appendingPathComponent(UUID().uuidString + (png ? ".png" : ".jpg"))
        try write(thumbnail, to: out, png: png)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let gps = CaptureInfo.gps(from: properties)
        return PreparedImage(path: out.path, width: width, height: height,
                        capture: CaptureInfo(taken: exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
                                             latitude: gps?.latitude, longitude: gps?.longitude),
                        quality: quality, faces: faces)
    }

    static func fullImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func write(_ image: CGImage, to url: URL, png: Bool) throws {
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)
        else { throw ExtractError.unreadable("can't write \(url.lastPathComponent)") }
        let properties = png ? nil : [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw ExtractError.unreadable("can't encode image") }
    }
}

enum OCR {
    /// Apple Vision text recognition: ~0.1 s for a 1440×900 screenshot on an M4 Pro.
    /// Runs on the full-resolution image; small UI text is what screenshots are full of.
    /// Accurate beats fast here: fast saved only 8% of screenshot indexing time once OCR overlapped with embedding,
    /// read 9% fewer characters, and lost an exact lookup ("externally-managed-environment") (2026-10-07).
    static func text(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Accurate recognition reads Arabic on this system (macOS 15 and later).
    static let readsArabic: Bool = {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages())?.contains { $0.hasPrefix("ar") } ?? false
    }()
}

enum PDFExtractor {
    /// Reads the pages in `range(pageCount)` (0-based). Pages with real text become text; scans and slides are
    /// rendered. Text layers PDFKit reads garbled are replaced: by OCR where letters were lost (Arabic ligatures), by
    /// the rendered page where the words came out in glyph order (Bengali, which OCR can't read). On the multilingual
    /// eval (2026-10-08), a glyph-order page as picture + garbled-text vector beat the picture alone: R@1 0.75 vs 0.73,
    /// MRR 0.84 vs 0.81 (an English query for a Bengali page found it only through the text vector).
    static func pages(of url: URL, range: (Int) -> Range<Int>, minText: Int, renderPixels: Int, to folder: URL)
        throws -> (pages: [DocumentPage], total: Int, title: String?) {
        guard let document = PDFDocument(url: url) else { throw ExtractError.unreadable("can't open PDF") }
        if document.isLocked { throw ExtractError.locked }
        var pages: [DocumentPage] = []
        for index in range(document.pageCount).clamped(to: 0..<document.pageCount) {
            guard let page = document.page(at: index) else { continue }
            var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var garbled: String?
            switch PageTextProblem.check(text) {
            case .lostLetters:
                // OCR's reading replaces the text layer only when it's real Arabic; otherwise the layer stays as it is.
                if OCR.readsArabic, let image = render(page, pixels: 2000) {
                    let read = OCR.text(in: image).trimmingCharacters(in: .whitespacesAndNewlines)
                    if read.count >= minText, PageTextProblem.check(read) == nil,
                       read.unicodeScalars.contains(where: { Script.arabic.contains($0.value) }) {
                        pages.append(DocumentPage(number: index + 1, text: read, imagePath: nil, ocr: true))
                        continue
                    }
                }
                if text.count >= minText {
                    pages.append(DocumentPage(number: index + 1, text: text, imagePath: nil))
                    continue
                }
            case .glyphOrder:
                (text, garbled) = ("", text)
            case nil:
                if text.count >= minText {
                    pages.append(DocumentPage(number: index + 1, text: text, imagePath: nil))
                    continue
                }
            }
            guard let image = render(page, pixels: renderPixels) else { continue }
            let out = folder.appendingPathComponent(UUID().uuidString + ".png")
            try ImageExtractor.write(image, to: out, png: true)
            pages.append(DocumentPage(number: index + 1, text: text, imagePath: out.path, garbled: garbled))
        }
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return (pages, document.pageCount, title)
    }

    /// The page as a picture, fitted into a square of `pixels`.
    static func render(_ page: PDFPage, pixels: Int) -> CGImage? {
        let side = CGFloat(pixels)
        return page.thumbnail(of: NSSize(width: side, height: side), for: .mediaBox)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

extension DocExtractor {
    /// Plain text from txt/md directly, HTML by stripping tags, and rtf/docx/doc/odt through the Cocoa text system.
    /// (Cocoa's HTML import runs WebKit and must be on the main thread; the app indexes on a background queue.)
    static func text(of url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        let type: NSAttributedString.DocumentType
        switch ext {
        case "docx": type = .officeOpenXML
        case "doc": type = .docFormat
        case "odt": type = .openDocument
        case "rtf": type = .rtf
        case "html", "htm": return plainText(fromHTML: try readText(url))
        default: return try readText(url)
        }
        return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
    }
}
