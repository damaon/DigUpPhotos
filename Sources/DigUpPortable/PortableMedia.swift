import DigUpCore
import Foundation

/// `MediaReading` without Apple's frameworks, for Linux (and Windows later): pictures through stb_image and libheif
/// (WebP and TIFF through ffmpeg, raw photos by their embedded JPEG), EXIF through the core's reader, faces through
/// YuNet and SFace on ONNX Runtime (`PortableFaces`), PDFs through poppler-utils, sound and video through ffmpeg, text
/// in pictures through tesseract when it's installed; Word, OpenDocument and RTF through the core's `RichText`. docs/ARCHITECTURE.md has the plan.
public struct PortableMedia: MediaReading {
    public init() {}

    public func image(_ url: URL, maxPixel: Int, minSide: Int, to folder: URL, png: Bool, scoreQuality: Bool,
                      detectFaces: Bool) throws -> PreparedImage {
        guard let size = Picture.size(of: url) else { throw ExtractError.unreadable("can't decode image") }
        guard max(size.width, size.height) >= minSide else { throw ExtractError.tooSmall(size.width, size.height) }
        guard let (full, exif) = Picture.decode(url) else { throw ExtractError.unreadable("can't decode image") }
        let picture = full.fitted(in: maxPixel)
        let faces = detectFaces ? PortableFaces.detect(in: picture, full: full) : []
        let quality = scoreQuality ? PhotoQuality.assess(picture.fitted(in: 256).gray, faceBoxes: faces.map(\.box)) : nil
        // BMP whether or not `png` asks for lossless: it is lossless, and the model reads it as it is.
        let out = folder.appendingPathComponent(UUID().uuidString + ".bmp")
        try picture.writeBMP(to: out)
        return PreparedImage(path: out.path, width: size.width, height: size.height, capture: exif.capture,
                             quality: quality, faces: faces)
    }

    public func screenText(of url: URL) -> String {
        guard Tools.find("tesseract") != nil, let data = try? Tools.run("tesseract", [url.path, "stdout"]) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func pdfPages(of url: URL, range: (Int) -> Range<Int>, minText: Int, renderPixels: Int, to folder: URL)
        throws -> (pages: [DocumentPage], total: Int, title: String?) {
        let info = try pdfInfo(url)
        var pages: [DocumentPage] = []
        for index in range(info.pages).clamped(to: 0..<info.pages) {
            let number = String(index + 1)
            var text = String(decoding: try Tools.run("pdftotext", ["-q", "-enc", "UTF-8", "-f", number, "-l", number,
                                                                    url.path, "-"]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var garbled: String?
            // As on macOS, less OCR: a text layer that lost letters stays as it is when it's long enough.
            if PageTextProblem.check(text) == .glyphOrder { (text, garbled) = ("", text) }
            if garbled == nil, text.count >= minText {
                pages.append(DocumentPage(number: index + 1, text: text, imagePath: nil))
                continue
            }
            let out = folder.appendingPathComponent(UUID().uuidString)
            try Tools.run("pdftoppm", ["-q", "-f", number, "-l", number, "-scale-to", String(renderPixels), "-png",
                                       "-singlefile", url.path, out.path])
            pages.append(DocumentPage(number: index + 1, text: text, imagePath: out.path + ".png", garbled: garbled))
        }
        return (pages, info.pages, info.title)
    }

    public func documentText(of url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return DocExtractor.plainText(fromHTML: try DocExtractor.readText(url))
        case "docx", "odt", "rtf": return try RichText.text(of: url)
        // Word 97-2003: antiword or catdoc, when one is installed.
        case "doc":
            for (tool, arguments) in [("antiword", ["-w", "0"]), ("catdoc", ["-w", "-d", "utf-8"])] where Tools.find(tool) != nil {
                return String(decoding: try Tools.run(tool, arguments + [url.path]), as: UTF8.self)
            }
            throw ExtractError.unreadable("old Word files need antiword or catdoc")
        default: return try DocExtractor.readText(url)
        }
    }

    public func thumbnail(of url: URL, kind: FileKind, at: Double?, maxPixel: Int, to file: URL) throws {
        switch kind {
        case .image, .screenshot:
            guard let (picture, _) = Picture.decode(url) else { throw ExtractError.unreadable("can't decode image") }
            try picture.fitted(in: maxPixel).writeJPEG(to: file)
        case .pdf:
            let page = String(max(1, Int(at ?? 1)))
            let out = file.deletingPathExtension()
            try Tools.run("pdftoppm", ["-q", "-f", page, "-l", page, "-scale-to", String(maxPixel), "-jpeg",
                                       "-singlefile", url.path, out.path])
            if out.appendingPathExtension("jpg") != file {
                try? FileManager.default.removeItem(at: file)
                try FileManager.default.moveItem(at: out.appendingPathExtension("jpg"), to: file)
            }
        case .video:
            let seconds = at ?? min(0.5, (duration(of: url) ?? 1) / 2)
            try Tools.run("ffmpeg", ["-v", "error", "-nostdin", "-y", "-ss", String(seconds), "-i", url.path,
                                     "-frames:v", "1", "-vf", "scale=w=\(maxPixel):h=\(maxPixel):force_original_aspect_ratio=decrease",
                                     "-q:v", "4", file.path])
        default:
            throw ExtractError.unreadable("no picture of a \(kind.rawValue)")
        }
    }

    public func audioWindows(of url: URL, window: Double, hop: Double, to folder: URL) async throws
        -> (pieces: [MediaPiece], duration: Double) {
        try SoundWindows.cut(url, window: window, hop: hop, to: folder)
    }

    public func keyframes(of url: URL, every interval: Double, maxPixel: Int, to folder: URL) async throws
        -> (frames: [MediaPiece], duration: Double, hasAudio: Bool) {
        let probe = try Probe(url)
        guard probe.duration > 0, probe.hasVideo else { return ([], probe.duration, probe.hasAudio) }
        let maxFrames = 1200
        let step = max(interval, probe.duration / Double(maxFrames))
        let scratch = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // The first frame at or after each step from `first` (as macOS asks for 0.5 s, then a step apart): the k-th
        // file is from `first + k·step`, within a frame. ffmpeg turns them upright.
        let first = min(0.5, probe.duration / 2)
        try Tools.run("ffmpeg", ["-v", "error", "-nostdin", "-ss", String(first), "-i", url.path, "-an",
                                 "-vf", "select='gte(t,selected_n*\(step))',scale=w=\(maxPixel):h=\(maxPixel):"
                                    + "force_original_aspect_ratio=decrease",
                                 "-fps_mode", "vfr", "-frames:v", String(maxFrames),
                                 scratch.appendingPathComponent("%06d.bmp").path])
        let names = try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted()
        var frames: [MediaPiece] = []
        var lastHash: UInt64?
        for (index, name) in names.enumerated() {
            let file = scratch.appendingPathComponent(name)
            guard let (picture, _) = Picture.decode(file) else { continue }
            let hash = picture.averageHash
            if let lastHash, (hash ^ lastHash).nonzeroBitCount <= 4 { continue }
            lastHash = hash
            let out = folder.appendingPathComponent(UUID().uuidString + ".bmp")
            try FileManager.default.moveItem(at: file, to: out)
            let start = first + Double(index) * step
            frames.append(MediaPiece(path: out.path, start: start, end: probe.duration))
        }
        for index in frames.indices.dropLast() { frames[index].end = frames[index + 1].start }
        return (frames, probe.duration, probe.hasAudio)
    }

    public func capture(of url: URL) -> CaptureInfo {
        (try? Probe(url))?.capture ?? CaptureInfo()
    }

    public func pageCount(of url: URL) -> Int? {
        (try? pdfInfo(url))?.pages
    }

    public func duration(of url: URL) -> Double? {
        (try? Probe(url)).flatMap { $0.duration > 0 ? $0.duration : nil }
    }

    private func pdfInfo(_ url: URL) throws -> (pages: Int, title: String?) {
        let text: String
        do {
            text = String(decoding: try Tools.run("pdfinfo", ["-enc", "UTF-8", url.path]), as: UTF8.self)
        } catch ToolError.failed(_, let why) where why.lowercased().contains("password") {
            throw ExtractError.locked
        }
        var pages = 0
        var title: String?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "Pages" { pages = Int(parts[1]) ?? 0 }
            if parts[0] == "Title", !parts[1].isEmpty { title = parts[1] }
        }
        return (pages, title)
    }
}

/// What ffprobe says about a sound or video file.
struct Probe {
    var duration = 0.0
    var hasVideo = false
    var hasAudio = false
    var capture = CaptureInfo()

    init(_ url: URL) throws {
        let data = try Tools.run("ffprobe", ["-v", "error", "-print_format", "json", "-show_format", "-show_streams",
                                             url.path])
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let format = json["format"] as? [String: Any] ?? [:]
        duration = Double(format["duration"] as? String ?? "") ?? 0
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            // A cover picture in a music file is a "video" stream of one frame; it isn't a video.
            let disposition = stream["disposition"] as? [String: Any]
            if stream["codec_type"] as? String == "video", disposition?["attached_pic"] as? Int != 1 { hasVideo = true }
            if stream["codec_type"] as? String == "audio" { hasAudio = true }
        }
        let tags = format["tags"] as? [String: String] ?? [:]
        let created = tags["com.apple.quicktime.creationdate"] ?? tags["creation_time"]
        capture.taken = created.flatMap(Self.internetDate)
        if let place = tags["com.apple.quicktime.location.ISO6709"] ?? tags["location"],
           let gps = CaptureInfo.parseISO6709(place) {
            capture.latitude = gps.latitude
            capture.longitude = gps.longitude
        }
    }

    /// "2024-07-14T18:03:27.000000Z" (or with an offset) as macOS writes capture times: "2024-07-14T18:03:27Z".
    static func internetDate(_ text: String) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: text) ?? plain.date(from: text) else { return nil }
        return plain.string(from: date)
    }
}

/// Sound cut into windows the way `AudioExtractor` does it on macOS: 16 kHz mono, streamed from ffmpeg, silent
/// windows left out, the tail kept when it adds at least `minimum` seconds.
enum SoundWindows {
    static let sampleRate = 16_000.0

    static func cut(_ url: URL, window: Double, hop: Double, minimum: Double = 2, to folder: URL) throws
        -> (pieces: [MediaPiece], duration: Double) {
        let probe = try Probe(url)
        guard probe.hasAudio else { return ([], probe.duration) }
        let running = try Tools.start("ffmpeg", ["-v", "error", "-nostdin", "-i", url.path, "-vn", "-ac", "1",
                                                 "-ar", String(Int(sampleRate)), "-f", "s16le", "-"])
        let windowSamples = Int(window * sampleRate), hopSamples = Int(hop * sampleRate)
        var buffer: [Int16] = []
        var offset = 0
        var pieces: [MediaPiece] = []
        var pending = Data()
        func emit(_ count: Int) throws {
            let slice = buffer[0..<count]
            guard rms(slice) > 0.003 else { return }
            let out = folder.appendingPathComponent(UUID().uuidString + ".wav")
            try writeWAV(slice, to: out)
            pieces.append(MediaPiece(path: out.path, start: Double(offset) / sampleRate,
                                     end: Double(offset + count) / sampleRate))
        }
        while true {
            let chunk = running.stdout.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            let whole = pending.count / 2 * 2
            pending.prefix(whole).withUnsafeBytes { bytes in
                buffer.append(contentsOf: bytes.bindMemory(to: Int16.self).map { Int16(littleEndian: $0) })
            }
            pending = pending.count > whole ? pending.suffix(from: pending.startIndex + whole) : Data()
            while buffer.count >= windowSamples {
                try emit(windowSamples)
                buffer.removeFirst(hopSamples)
                offset += hopSamples
            }
        }
        try running.finish("ffmpeg")
        let alreadyCovered = offset == 0 ? 0 : windowSamples - hopSamples
        if buffer.count - alreadyCovered >= Int(minimum * sampleRate) { try emit(buffer.count) }
        return (pieces, probe.duration > 0 ? probe.duration : Double(offset + buffer.count) / sampleRate)
    }

    private static func rms(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples { let value = Double(sample) / 32768; sum += value * value }
        return (sum / Double(samples.count)).squareRoot()
    }

    private static func writeWAV(_ samples: ArraySlice<Int16>, to url: URL) throws {
        var data = Data(capacity: 44 + samples.count * 2)
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        append("RIFF"); append32(UInt32(36 + samples.count * 2)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1); append32(rate); append32(rate * 2); append16(2); append16(16)
        append("data"); append32(UInt32(samples.count * 2))
        for sample in samples { append16(UInt16(bitPattern: sample)) }
        try data.write(to: url)
    }
}
