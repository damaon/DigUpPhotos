import AppKit
import DigUpKit

/// One search result as the panel and the window show it: a file, the part of it that matched, and why.
struct ResultRow: Identifiable, Equatable {
    let id: String          // the file's path
    let url: URL
    let name: String
    let folder: String      // "~/Downloads/Screenshots"
    let kind: FileKind
    let segment: SegmentKind
    let segmentID: Int64
    let loc: Double?        // PDF page, or seconds into audio or video
    let locEnd: Double?
    let excerpt: String?    // matched words are wrapped in « »
    let matchedMeaning: Bool
    let matchedWords: Bool
    /// Why it's here when people or a time were picked with nothing typed (`Searcher.photos(of:)`): not as a match.
    let browsed: Browsed?
    let modified: Date
    let size: Int64
    let info: [String: String]
    /// The query's words (`Searcher.terms`): what the preview highlights on a page or in a passage.
    let terms: [String]

    init(_ hit: SearchHit, terms: [String] = [], browsed: Browsed? = nil) {
        id = hit.path
        url = URL(fileURLWithPath: hit.path)
        name = url.lastPathComponent
        folder = tildePath(url.deletingLastPathComponent().path)
        kind = hit.kind
        segment = hit.segment
        segmentID = hit.segmentID
        loc = hit.loc
        locEnd = hit.locEnd
        excerpt = hit.excerpt.flatMap { $0.isEmpty ? nil : $0 }
        matchedMeaning = hit.matchedMeaning
        matchedWords = hit.keywordRank != nil
        self.browsed = browsed
        modified = Date(timeIntervalSince1970: hit.modified)
        size = hit.size
        info = hit.info
        self.terms = terms
    }

    /// The name to show: left to right as Finder shows it, also when it starts in Arabic ("ملاحظة.md", not "md.ملاحظة").
    var title: String { "\u{200E}" + name }

    /// What a result's tile is called: when a photo or video was taken ("Jul 12, 2023 at 14:32"), which says more than
    /// "IMG_4052.HEIC"; the name for anything else, or when the camera didn't say.
    var tileTitle: String {
        guard kind == .image || kind == .video, let taken else { return title }
        return taken.formatted(date: .abbreviated, time: .shortened)
    }

    /// The words keyword search found in the excerpt (marked « »), as they're written there.
    var foundWords: [String] {
        guard let excerpt else { return [] }
        var words: [String] = []
        var rest = excerpt[...]
        while let open = rest.firstIndex(of: "«"), let close = rest[open...].firstIndex(of: "»") {
            let word = String(rest[rest.index(after: open)..<close])
            if !word.isEmpty, !words.contains(word) { words.append(word) }
            rest = rest[rest.index(after: close)...]
        }
        return words
    }

    /// The page or moment that matched, as a badge: "p. 3", "0:06", "♪ 0:25" (a video's sound).
    var place: String? {
        guard let loc else { return nil }
        switch segment {
        case .page, .pageImage: return "p. \(Int(loc))"
        case .frame: return Self.clock(loc)
        case .audio: return kind == .video ? "♪ \(Self.clock(loc))" : Self.clock(loc)
        default: return nil
        }
    }

    /// What the preview shows: the moment or the page that matched, else the file.
    var previewKey: String { "\(id)|\(loc.map { "\($0)" } ?? "")" }

    var duration: Double? { info["duration"].flatMap(Double.init) }

    /// Why it's here, in a few words: "Matches the picture", "Matches the frame at 0:06".
    var reason: String {
        if let browsed { return browsed.reason }
        guard matchedMeaning else { return matchedWords ? "Has your words" : "Matches its name" }
        let place = loc.map(Self.clock) ?? ""
        let page = loc.map { "page \(Int($0))" } ?? "a page"
        switch segment {
        case .image: return kind == .screenshot ? "Matches what's on screen" : "Matches the picture"
        case .ocr: return "Matches the text in it"
        case .frame: return "Matches the frame at \(place)"
        case .audio: return kind == .video ? "Matches the sound at \(place)" : "Matches what's heard at \(place)"
        case .page: return "Matches the text on \(page)"
        case .pageImage: return "Matches \(page)"
        case .chunk: return "Matches its text"
        case .name: return "Matches its name"
        }
    }

    /// Capture date from EXIF / video metadata when DigUp stored it; otherwise the file's mtime.
    var taken: Date? { Self.parseTaken(info["taken"]) }

    /// GPS from EXIF / video metadata, when DigUp stored it.
    var capturePlace: String? {
        guard let lat = info["lat"].flatMap(Double.init), let lon = info["lon"].flatMap(Double.init) else { return nil }
        return CaptureInfo.format(latitude: lat, longitude: lon)
    }

    /// Local look score for photos (`PhotoQuality`), 0…100.
    var quality: Int? {
        guard kind == .image else { return nil }
        return info["quality"].flatMap(Int.init)
    }

    /// Short label for details: "Nice · 82", "OK · 54", "Soft · 31".
    var qualityLabel: String? {
        guard let quality else { return nil }
        let word: String
        switch quality {
        case 75...: word = "Nice"
        case 50..<75: word = "OK"
        default: word = "Soft"
        }
        return "\(word) · \(quality)"
    }

    /// Sharpness, light, contrast, and face framing, each 0…100. Nil until the photo has been scored with those parts.
    /// Composition is "not scored" when no face was found.
    var lookBreakdown: String? {
        guard kind == .image,
              let sharp = info["q_sharp"].flatMap(Int.init),
              let light = info["q_light"].flatMap(Int.init),
              let contrast = info["q_contrast"].flatMap(Int.init) else { return nil }
        let composition: String
        if let faces = info["q_faces"].flatMap(Int.init), faces > 0, let frame = info["q_frame"].flatMap(Int.init) {
            composition = "\(frame)"
        } else {
            composition = "not scored"
        }
        return "Sharpness \(sharp) · Light \(light) · Contrast \(contrast) · Composition \(composition)"
    }

    /// "Photo · Oct 1, 2026 at 14:32 · 37.77°N 122.42°W · 1440 × 900 · 2.1 MB", "Video · … · 0:42 · 23 MB"
    var details: String {
        let when = taken?.formatted(date: .abbreviated, time: .shortened)
            ?? modified.formatted(date: .abbreviated, time: .omitted)
        var parts = [kind.title, when]
        if let capturePlace { parts.append(capturePlace) }
        if let qualityLabel { parts.append(qualityLabel) }
        if let width = info["width"], let height = info["height"] { parts.append("\(width) × \(height)") }
        // A long file still being read (`Indexer.finishLongFiles`): what isn't read yet can't match.
        let readTo = info["read_to"].flatMap(Int.init)
        if let pages = info["pages"].flatMap(Int.init) {
            parts.append((pages == 1 ? "1 page" : "\(pages) pages") + (readTo.map { ", \($0) read so far" } ?? ""))
        } else if readTo != nil {
            parts.append("partly read so far")
        }
        if let duration { parts.append(Self.clock(duration)) }
        if size > 0 { parts.append(bytes(size)) }
        return parts.joined(separator: " · ")
    }

    /// EXIF `YYYY:MM:DD HH:MM:SS` or ISO-8601 from video metadata.
    static func parseTaken(_ text: String?) -> Date? {
        CaptureInfo.date(from: text)
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Why photos are shown when people or a time were picked and nothing typed.
struct Browsed: Equatable {
    let reason: String
    let symbol: String

    static let people = Browsed(reason: "Has the people you picked", symbol: "person.2")
    static let time = Browsed(reason: "Taken in the time you picked", symbol: "calendar")
}

/// How results are grouped in the panel, and the kind filters in the window.
enum ResultGroupKind: CaseIterable {
    case screenshots, images, documents, video, audio

    /// Photos & video MVP: the window's kind filters when DigUp indexes only pictures and video.
    static let photosAndVideo: [ResultGroupKind] = [.images, .video]
    /// Every kind DigUp can index in the main store (when "Photos and videos only" is off).
    static let allFiles: [ResultGroupKind] = [.screenshots, .images, .documents, .video, .audio]
    /// Default chips: photos and video (the MVP focus).
    static let files: [ResultGroupKind] = photosAndVideo

    /// Kind filter chips for the current mode.
    static func files(photosAndVideoOnly: Bool) -> [ResultGroupKind] {
        photosAndVideoOnly ? photosAndVideo : allFiles
    }

    init(_ kind: FileKind) {
        switch kind {
        case .screenshot: self = .screenshots
        case .image: self = .images
        case .pdf, .doc: self = .documents
        case .video: self = .video
        case .audio: self = .audio
        }
    }

    var title: String {
        switch self {
        case .screenshots: "Screenshots"
        case .images: "Photos"
        case .documents: "Documents"
        case .video: "Video"
        case .audio: "Audio"
        }
    }

    var symbol: String {
        switch self {
        case .screenshots: FileKind.screenshot.symbol
        case .images: FileKind.image.symbol
        case .documents: FileKind.doc.symbol
        case .video: FileKind.video.symbol
        case .audio: FileKind.audio.symbol
        }
    }

    var kinds: Set<FileKind> {
        switch self {
        case .screenshots: [.screenshot]
        case .images: [.image]
        case .documents: [.pdf, .doc]
        case .video: [.video]
        case .audio: [.audio]
        }
    }
}

struct ResultGroup: Identifiable, Equatable {
    let kind: ResultGroupKind
    let rows: [ResultRow]
    /// Strong results of this kind, shown or not (the panel shows a few).
    var total: Int
    var id: ResultGroupKind { kind }
}

/// Search results the way they're shown: the strong ones grouped by kind (the best hit's group first, as many rows per
/// group as there's room for), and the weaker ones (below half the top score) folded underneath.
struct ResultSet: Equatable {
    var groups: [ResultGroup] = []
    /// The strong ones in score order (the window's grid; the panel shows `groups`).
    var ranked: [ResultRow] = []
    var weaker: [ResultRow] = []

    static let empty = ResultSet()

    init() {}

    /// `browsed`: the hits are people's or a time's photos, with nothing typed, all strong; why they're here.
    init(_ hits: [SearchHit], query: String = "", rowsPerGroup: Int = .max, browsed: Browsed? = nil) {
        let strong = browsed == nil ? Searcher.strongCount(hits) : hits.count
        let terms = Searcher.terms(query)
        var order: [ResultGroupKind] = []
        var byGroup: [ResultGroupKind: [ResultRow]] = [:]
        ranked = hits.prefix(strong).map { ResultRow($0, terms: terms, browsed: browsed) }
        for row in ranked {
            let group = ResultGroupKind(row.kind)
            if byGroup[group] == nil { order.append(group) }
            byGroup[group, default: []].append(row)
        }
        groups = order.map {
            ResultGroup(kind: $0, rows: Array(byGroup[$0]!.prefix(rowsPerGroup)), total: byGroup[$0]!.count)
        }
        weaker = hits.dropFirst(strong).map { ResultRow($0, terms: terms) }
    }

    var strongRows: [ResultRow] { groups.flatMap(\.rows) }
    var isEmpty: Bool { groups.isEmpty && weaker.isEmpty }
    var count: Int { strongRows.count + weaker.count }
}

/// The results on screen as a plain file list: absolute paths, one per line, the way `ls` prints names.
enum FileList {
    static func text(_ rows: [ResultRow]) -> String {
        var seen = Set<String>()
        let paths = rows.map(\.id).filter { seen.insert($0).inserted }
        guard !paths.isEmpty else { return "" }
        return paths.joined(separator: "\n") + "\n"
    }

    /// Puts that list on `pasteboard` and returns how many paths it holds.
    @discardableResult
    static func copy(_ rows: [ResultRow], to pasteboard: NSPasteboard = .general) -> Int {
        let text = text(rows)
        guard !text.isEmpty else { return 0 }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return text.filter { $0 == "\n" }.count
    }

    /// A `.txt` name from the query, safe to offer in a save panel.
    static func suggestedName(for query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = ""
        for scalar in trimmed.unicodeScalars {
            if scalar.value < 32 || scalar == "/" || scalar == ":" {
                if name.last != "-" { name.append("-") }
            } else {
                name.append(Character(scalar))
            }
        }
        let base = String(name.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return (base.isEmpty ? "files" : base) + ".txt"
    }
}

extension FileKind {
    var title: String {
        switch self {
        case .screenshot: "Screenshot"
        case .image: "Photo"
        case .pdf: "PDF"
        case .doc: "Document"
        case .audio: "Audio"
        case .video: "Video"
        }
    }

    var symbol: String {
        switch self {
        case .screenshot: "camera.viewfinder"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .doc: "doc.text"
        case .audio: "waveform"
        case .video: "film"
        }
    }
}
