import CoreGraphics
import CoreServices
import Foundation

/// Seconds of indexing per unit, measured 2026-10-07 on an M4 Pro with llama.cpp (Q8_0), reading files while the
/// model embeds (a full index of the 365-file testbed: 160 s, per-kind sums below). The app will calibrate these with
/// a few seconds of real work on first launch.
public struct Costs: Sendable {
    public var image = 0.12              // 140 tokens, decode included
    public var screenshot = 0.32         // 280 tokens; its OCR (0.24 s) runs alongside and sets the pace
    public var pdfPage = 0.09            // text pages are cheap, rendered scans cost an image
    public var docChunk = 0.095
    public var audioSecond = 0.0089      // a 30 s window every 25 s
    public var videoSecond = 0.019       // a 70-token keyframe per shot (at most one per 3 s) + the soundtrack
    public init() {}
}

public struct Estimate: Sendable {
    public var files: [FileKind: Int] = [:]
    public var pdfPages = 0           // pages the first pass will read
    public var pdfPagesTotal = 0
    public var audioSeconds = 0.0
    public var videoSeconds = 0.0
    public var docChunks = 0          // chunks the first pass will read
    public var seconds = 0.0          // the first pass
    /// Long PDFs and documents, which get their first step in the first pass, and how long the rest of them takes
    /// once everything else is in (`Indexer.finishLongFiles`).
    public var longFiles = 0
    public var laterSeconds = 0.0

    public init() {}

    public static func + (a: Estimate, b: Estimate) -> Estimate {
        var sum = a
        sum.files.merge(b.files, uniquingKeysWith: +)
        sum.pdfPages += b.pdfPages
        sum.pdfPagesTotal += b.pdfPagesTotal
        sum.audioSeconds += b.audioSeconds
        sum.videoSeconds += b.videoSeconds
        sum.docChunks += b.docChunks
        sum.seconds += b.seconds
        sum.longFiles += b.longFiles
        sum.laterSeconds += b.laterSeconds
        return sum
    }
}

/// First-index time from metadata alone: counts, PDF page counts and media durations come from Spotlight (falling
/// back to the file header when Spotlight hasn't seen a file yet), so nothing is decoded.
public enum Estimator {
    public static func estimate(_ candidates: [Candidate], options: IndexOptions, costs: Costs = Costs()) -> Estimate {
        var estimate = Estimate()
        for file in candidates {
            estimate.files[file.kind, default: 0] += 1
            switch file.kind {
            case .image: estimate.seconds += costs.image
            case .screenshot: estimate.seconds += costs.screenshot
            case .pdf:
                let total = pages(of: file.path)
                let all = min(total, options.maxPages)
                let first = total > options.bigPDFPages ? min(options.pdfStep, all) : all
                estimate.pdfPagesTotal += total
                estimate.pdfPages += first
                estimate.seconds += Double(first) * costs.pdfPage
                if all > first {
                    estimate.longFiles += 1
                    estimate.laterSeconds += Double(all - first) * costs.pdfPage
                }
            case .doc:
                let all = max(1, min(options.maxChunks, Int(file.size / 2000)))
                let first = min(all, options.docStep)
                estimate.docChunks += first
                estimate.seconds += Double(first) * costs.docChunk
                if all > first {
                    estimate.longFiles += 1
                    estimate.laterSeconds += Double(all - first) * costs.docChunk
                }
            case .audio:
                let seconds = duration(of: file.path)
                estimate.audioSeconds += seconds
                estimate.seconds += seconds * costs.audioSecond
            case .video:
                let seconds = duration(of: file.path)
                estimate.videoSeconds += seconds
                estimate.seconds += seconds * costs.videoSecond
            }
        }
        return estimate
    }

    /// Estimates for each subfolder one level down, and for the files right in `folder` (under its own path), from
    /// the same look at each file: the folder lists show where a big first pass comes from.
    /// Subfolders are named under `folder` as given, though the walk reports real paths (/private/var for /var).
    public static func estimates(bySubfolder candidates: [Candidate], of folder: String, options: IndexOptions,
                                 costs: Costs = Costs()) -> [String: Estimate] {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        let real = FolderSelection.realPath(folder) + "/"
        var groups: [String: [Candidate]] = [:]
        for file in candidates {
            let rest = file.path.hasPrefix(prefix) ? file.path.dropFirst(prefix.count)
                : file.path.hasPrefix(real) ? file.path.dropFirst(real.count) : nil
            let key = rest.flatMap { rest in rest.firstIndex(of: "/").map { prefix + rest[..<$0] } } ?? folder
            groups[key, default: []].append(file)
        }
        return groups.mapValues { estimate($0, options: options, costs: costs) }
    }

    static func pages(of path: String) -> Int {
        if let pages = spotlight(path, kMDItemNumberOfPages), pages > 0 { return Int(pages) }
        return CGPDFDocument(URL(fileURLWithPath: path) as CFURL)?.numberOfPages ?? 1
    }

    static func duration(of path: String) -> Double {
        if let seconds = spotlight(path, kMDItemDurationSeconds), seconds > 0 { return seconds }
        return MediaInfo.duration(of: URL(fileURLWithPath: path)) ?? 0
    }

    private static func spotlight(_ path: String, _ attribute: CFString) -> Double? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return (MDItemCopyAttribute(item, attribute) as? NSNumber)?.doubleValue
    }
}
