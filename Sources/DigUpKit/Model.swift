import Foundation

/// What a file is, for indexing and for grouping results.
public enum FileKind: String, CaseIterable, Sendable, Codable {
    case screenshot, image, pdf, doc, audio, video

    /// The order of the first indexing pass: photos and video first (the photos & video MVP), then the rest.
    static let indexingOrderSQL = """
        CASE kind WHEN 'image' THEN 0 WHEN 'video' THEN 1 WHEN 'screenshot' THEN 2 WHEN 'pdf' THEN 3
        WHEN 'doc' THEN 4 WHEN 'audio' THEN 5 ELSE 6 END
        """

    /// Photos and videos only — DigUp's photos & video MVP default set.
    public static let photosAndVideo: Set<FileKind> = [.image, .video]
}

/// One searchable piece of a file.
public enum SegmentKind: String, Sendable {
    case name             // file name + folder names (keyword search only)
    case image            // the image itself
    case ocr              // text Apple Vision read from a screenshot
    case page             // a PDF page's text
    case pageImage = "page_image"  // a PDF page rendered as an image (scans, slides)
    case chunk            // a piece of a document's text
    case audio            // a window of audio (a file or a video's soundtrack)
    case frame            // a video keyframe
}

/// What produced a segment's vector. Scores are normalized per modality because text vectors score higher than
/// image or audio vectors for the same topic (measured: 0.75–0.86 vs 0.67–0.78).
public enum Modality: String, Sendable, CaseIterable {
    case none, text, image, audio
}

/// Indexing settings. Anything that changes vectors is part of `fingerprint`; an index never mixes settings.
public struct IndexOptions: Sendable {
    public var includeDatasets = false
    public var minImageSide = 256
    /// Long files are read a step at a time: the first step in the first pass (every file gets searchable sooner), the
    /// rest after everything else (`Indexer.finishLongFiles`). PDFs up to `bigPDFPages` are read whole at once.
    public var bigPDFPages = 50
    public var pdfStep = 30                // pages
    public var docStep = 40                // chunks, ~64,000 characters
    /// Only machine-made giants get this far: a file's pages or chunks past these are left out.
    public var maxPages = 5_000
    public var maxChunks = 5_000           // ~8 million characters
    public var minPageText = 200           // fewer characters than this: embed the rendered page instead
    public var photoBudget = 140           // vision soft tokens: 70 / 140 / 280 / 560 / 1120
    public var screenshotBudget = 280
    public var pageBudget = 280
    public var frameBudget = 70
    public var frameInterval = 3.0         // seconds between sampled video frames (near-duplicates are dropped)
    public var audioWindow = 30.0          // the model silently ignores audio past 30 s of one input
    public var audioHop = 25.0
    public var excludedFolders: [String] = []
    public var excludedExtensions: Set<String> = []
    /// When non-empty, only these kinds are indexed. The app defaults to photos and video
    /// (`FileKind.photosAndVideo`); empty keeps DigUp's full set (CLI / evals).
    public var kinds: Set<FileKind> = []

    public init() {}

    /// Whether this index should take a file of this kind.
    public func indexes(_ kind: FileKind) -> Bool {
        kinds.isEmpty || kinds.contains(kind)
    }

    /// File extensions as people write them ("HEIC, .txt *.md") → ["heic", "txt", "md"].
    public static func extensions(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { word in
            word.drop { $0 == "*" || $0 == "." }.lowercased()
        }.filter { !$0.isEmpty })
    }

    /// Settings that change vectors (budgets and windows). Quality and faces are not in here: those can be redone
    /// while the embedding cache, keyed by file contents, still applies.
    var vectorFingerprint: String {
        "photo\(photoBudget) shot\(screenshotBudget) page\(pageBudget) frame\(frameBudget)/\(frameInterval)s audio\(audioWindow)/\(audioHop)s"
    }

    var fingerprint: String {
        // Same string as before when `kinds` is empty (CLI / evals), so a full index isn't rebuilt for nothing.
        // `qN`: photo quality; `fN`: face crops. Bumping either re-reads photos. Their embeddings stay in the cache.
        var stamp = "\(vectorFingerprint) q\(PhotoQuality.version) f\(FaceDetector.version)"
        if !kinds.isEmpty {
            stamp = "kinds:" + kinds.map(\.rawValue).sorted().joined(separator: ",") + " " + stamp
        }
        return stamp
    }
}

/// The model and the vector settings an index was built with. Quality (`qN`) and faces (`fN`) are separate: they
/// re-read photos, and the embeddings already stored for those file contents are reused.
struct IndexStamp: Equatable, Sendable {
    var model: String
    var vectors: String
    var quality: Int?
    var faces: Int?
    /// `kinds:…`, when the index takes only some kinds.
    var kinds: String?

    static func parse(_ fingerprint: String) -> IndexStamp {
        let parts = fingerprint.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let model = parts.count == 2 ? parts[0].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        var tokens = (parts.count == 2 ? parts[1] : Substring(fingerprint))
            .split(whereSeparator: \.isWhitespace).map(String.init)
        var kinds: String?
        if tokens.first?.hasPrefix("kinds:") == true { kinds = tokens.removeFirst() }
        var quality: Int?
        var faces: Int?
        while let last = tokens.last {
            if let number = Self.mark(last, prefix: "q") { quality = number; tokens.removeLast(); continue }
            if let number = Self.mark(last, prefix: "f") { faces = number; tokens.removeLast(); continue }
            break
        }
        return IndexStamp(model: model, vectors: tokens.joined(separator: " "), quality: quality, faces: faces,
                          kinds: kinds)
    }

    /// Same embedding model and the same budgets. A quality or face bump does not make old vectors unusable.
    func sameEmbeddings(as other: IndexStamp) -> Bool {
        model == other.model && vectors == other.vectors
    }

    private static func mark(_ token: String, prefix: Character) -> Int? {
        guard token.first == prefix, token.count > 1, token.dropFirst().allSatisfy(\.isNumber) else { return nil }
        return Int(token.dropFirst())
    }
}

/// EmbeddingGemma 2's task prompts (model card). Media inputs take no prompt.
public enum Prompts {
    public static func query(_ text: String) -> String { "task: search result | query: \(text)" }

    public static func document(title: String?, text: String) -> String {
        "title: \((title?.isEmpty ?? true) ? "none" : title!) | text: \(text)"
    }
}
