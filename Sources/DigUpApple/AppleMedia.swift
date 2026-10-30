import CoreGraphics
import CoreServices
import DigUpCore
import Foundation

/// `MediaReading` with Apple's frameworks: ImageIO and Vision for pictures and faces, PDFKit, the Cocoa text system,
/// and AVFoundation. Page counts and durations for estimates come from Spotlight first (nothing is decoded), falling
/// back to the file when Spotlight hasn't seen it yet.
public struct AppleMedia: MediaReading {
    public init() {}

    public func image(_ url: URL, maxPixel: Int, minSide: Int, to folder: URL, png: Bool, scoreQuality: Bool,
                      detectFaces: Bool) throws -> PreparedImage {
        try ImageExtractor.prepare(url, maxPixel: maxPixel, minSide: minSide, to: folder, png: png,
                                   scoreQuality: scoreQuality, detectFaces: detectFaces)
    }

    public func screenText(of url: URL) -> String {
        ImageExtractor.fullImage(url).map(OCR.text(in:)) ?? ""
    }

    public func pdfPages(of url: URL, range: (Int) -> Range<Int>, minText: Int, renderPixels: Int, to folder: URL)
        throws -> (pages: [DocumentPage], total: Int, title: String?) {
        try PDFExtractor.pages(of: url, range: range, minText: minText, renderPixels: renderPixels, to: folder)
    }

    public func documentText(of url: URL) throws -> String {
        try DocExtractor.text(of: url)
    }

    public func audioWindows(of url: URL, window: Double, hop: Double, to folder: URL) async throws
        -> (pieces: [MediaPiece], duration: Double) {
        try await AudioExtractor.windows(of: url, window: window, hop: hop, to: folder)
    }

    public func keyframes(of url: URL, every interval: Double, maxPixel: Int, to folder: URL) async throws
        -> (frames: [MediaPiece], duration: Double, hasAudio: Bool) {
        try await VideoExtractor.keyframes(of: url, every: interval, maxPixel: maxPixel, to: folder)
    }

    public func capture(of url: URL) -> CaptureInfo {
        MediaInfo.capture(of: url)
    }

    public func pageCount(of url: URL) -> Int? {
        if let pages = spotlight(url, kMDItemNumberOfPages), pages > 0 { return Int(pages) }
        return CGPDFDocument(url as CFURL)?.numberOfPages
    }

    public func duration(of url: URL) -> Double? {
        if let seconds = spotlight(url, kMDItemDurationSeconds), seconds > 0 { return seconds }
        return MediaInfo.duration(of: url)
    }

    private func spotlight(_ url: URL, _ attribute: CFString) -> Double? {
        guard let item = MDItemCreate(kCFAllocatorDefault, url.path as CFString) else { return nil }
        return (MDItemCopyAttribute(item, attribute) as? NSNumber)?.doubleValue
    }
}
