import Foundation

/// Everything indexing needs from the operating system to read a file: decoding pictures, finding faces, reading PDFs,
/// rich documents, sound and video. The core asks for it through this, so it builds anywhere; `AppleMedia` does it with
/// Apple's frameworks (docs/ARCHITECTURE.md). Pieces are written as files into `folder` for the model to read.
public protocol MediaReading: Sendable {
    /// A copy at most `maxPixel` on its longer side for the model (PNG or JPEG), with its capture date and place and,
    /// for photos, a look score and the faces on it. Throws `ExtractError.tooSmall` below `minSide`.
    func image(_ url: URL, maxPixel: Int, minSide: Int, to folder: URL, png: Bool, scoreQuality: Bool,
               detectFaces: Bool) throws -> PreparedImage
    /// The text on a picture (OCR, at full resolution): what screenshots are searched by.
    func screenText(of url: URL) -> String
    /// The pages in `range(pageCount)` (0-based): their text, or a picture of the ones with too little text.
    func pdfPages(of url: URL, range: (Int) -> Range<Int>, minText: Int, renderPixels: Int, to folder: URL)
        throws -> (pages: [DocumentPage], total: Int, title: String?)
    /// Plain text of a document (txt, md, html, rtf, docx, doc, odt).
    func documentText(of url: URL) throws -> String
    /// `window`-second pieces of the sound, `hop` seconds apart, as 16 kHz mono WAV files; silent ones are left out.
    func audioWindows(of url: URL, window: Double, hop: Double, to folder: URL) async throws
        -> (pieces: [MediaPiece], duration: Double)
    /// A frame every `interval` seconds, one per shot, as JPEG files.
    func keyframes(of url: URL, every interval: Double, maxPixel: Int, to folder: URL) async throws
        -> (frames: [MediaPiece], duration: Double, hasAudio: Bool)
    /// When and where a video was recorded.
    func capture(of url: URL) -> CaptureInfo
    /// How many pages a PDF has, cheaply (for estimates); nil when it can't tell.
    func pageCount(of url: URL) -> Int?
    /// How long a sound or video is, cheaply (for estimates); nil when it can't tell.
    func duration(of url: URL) -> Double?
    /// A JPEG at most `maxPixel` on its longer side, upright, written to `file`, for showing: a picture, a PDF's page
    /// `at` (1-based), or a video's frame `at` seconds in. Throws for anything else.
    func thumbnail(of url: URL, kind: FileKind, at: Double?, maxPixel: Int, to file: URL) throws
}

/// A picture made ready for the model by `MediaReading.image`.
public struct PreparedImage: Sendable {
    public let path: String
    public let width: Int
    public let height: Int
    public let capture: CaptureInfo
    /// Local look score for photos (`PhotoQuality`); nil for screenshots.
    public let quality: PhotoQuality?
    /// The faces on it, for people; empty for screenshots.
    public let faces: [DetectedFace]

    public init(path: String, width: Int, height: Int, capture: CaptureInfo, quality: PhotoQuality?,
                faces: [DetectedFace]) {
        self.path = path
        self.width = width
        self.height = height
        self.capture = capture
        self.quality = quality
        self.faces = faces
    }
}

/// A PDF page as `MediaReading.pdfPages` read it.
public struct DocumentPage: Sendable {
    public let number: Int        // 1-based
    public let text: String       // may be empty for scans
    public let imagePath: String? // set when the page had too little text and was rendered for the vision encoder
    public var ocr = false        // the text came from OCR: the text layer was garbled (`PageTextProblem.lostLetters`)
    /// Text read in glyph order (`PageTextProblem.glyphOrder`): too garbled to show or match words against, but
    /// enough of its words survive for a meaning vector beside the page's picture.
    public var garbled: String?

    public init(number: Int, text: String, imagePath: String?, ocr: Bool = false, garbled: String? = nil) {
        self.number = number
        self.text = text
        self.imagePath = imagePath
        self.ocr = ocr
        self.garbled = garbled
    }
}

/// A stretch of audio written to a temporary WAV for the model, or a video frame written to a JPEG.
public struct MediaPiece: Sendable {
    public let path: String
    public let start: Double
    public var end: Double

    public init(path: String, start: Double, end: Double) {
        self.path = path
        self.start = start
        self.end = end
    }
}

public enum ExtractError: Error, CustomStringConvertible {
    case unreadable(String)
    case tooSmall(Int, Int)
    case locked
    case empty(String)
    /// Not for the index after all, once read (code that a program made, or that holds a private key).
    case leftOut(String)

    public var description: String {
        switch self {
        case .unreadable(let why): "unreadable: \(why)"
        case .tooSmall(let width, let height): "small image \(width)×\(height)"
        case .locked: "password-protected"
        case .empty(let why): why
        case .leftOut(let why): why
        }
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Runs async media work from the synchronous indexer (one thread on purpose: simple and easy to reason about).
public func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await operation()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.result!.get()
}
