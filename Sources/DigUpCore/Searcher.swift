import Foundation

public struct SearchHit: Sendable {
    public let path: String
    public let kind: FileKind
    public let score: Double          // fused rank score, for ordering only
    public let z: Double?             // how far the best segment stands out for this query (`Searcher.meaning`)
    public let cosine: Double?
    public let keywordRank: Int?      // 1-based rank among keyword matches
    public let segment: SegmentKind
    /// The segment the hit points at (its text is `Searcher.text(ofSegment:)`).
    public let segmentID: Int64
    public let loc: Double?           // PDF page, or seconds into audio/video
    public let locEnd: Double?
    public let excerpt: String?
    /// The file's modification date (seconds since 1970), and what indexing learned about it: "width", "height",
    /// "taken", "lat", "lon", "quality", "pages", "duration"… (see `Indexer`).
    public let modified: Double
    public let size: Int64
    public let info: [String: String]
    /// Here because its picture or text means what was asked (at `Searcher.search`'s gates), not only for its words.
    public var matchedMeaning = false
    /// How far its cosine is above the query's average (z × the scale's deviation; `Searcher.minLift`).
    public var lift: Double?
}

/// Hybrid search: meaning (EmbeddingGemma's vectors) + words (FTS5).
///
/// Meaning is the model's cosine similarity, put on one scale per query (`meaning`): every vector is scored anyway, so
/// the distribution comes for free, and only segments that stand out (`zGate`) and are close enough to the query
/// (`minLift`) count as meaning matches. That also gives an honest "nothing found". Words rescue what a vector can't
/// hold exactly: codes, IDs and names.
public final class Searcher {
    let store: IndexStore
    private var matrix: VectorStorage?   // rows × 768 float16, row-major
    private var rowFile: [Int64] = []
    private var rowSegment: [Int64] = []
    private var rowModality: [Modality] = []
    /// False for the vectors the later pass adds (`Indexer.finishLongFiles`): scored, but they don't set the scale.
    private var rowSetsScale: [Bool] = []
    private var fileKind: [Int64: FileKind] = [:]
    /// When each file was taken (`info.taken`), else when it was last changed: what date filters and browsing go by.
    private var fileDate: [Int64: Date] = [:]
    public private(set) var vectorSource: String?
    /// False after `releaseVectors()` (or `loadVectors: false`): keyword search still works, and the next search with
    /// a query vector loads them again.
    public private(set) var vectorsLoaded = false

    public var vectorCount: Int { rowFile.count }

    /// With `loadVectors: false` only keyword search is ready; vectors load on the first meaning search. The app
    /// uses that to stay small while idle: 20k vectors are ~30 MB.
    public init(store: IndexStore, loadVectors: Bool = true) throws {
        self.store = store
        if loadVectors { try reload() } else { try reloadFiles() }
    }

    /// Reads the files and all vectors again (after indexing added some).
    public func reload() throws {
        releaseVectors()
        try reloadFiles()
        var rows = 0
        try store.db.query("SELECT COUNT(*) FROM segments WHERE vec IS NOT NULL") { rows = Int($0.int(0)) }
        guard let matrix = VectorStorage(rows: rows) else {
            vectorsLoaded = true   // nothing to load
            return
        }
        let rowBytes = Vectors.dimension * MemoryLayout<Float16>.stride
        let steps = IndexOptions()
        try store.db.query("""
            SELECT s.id, s.file, s.modality, s.vec, s.kind, s.loc, f.kind, CAST(json_extract(f.info, '$.pages') AS INTEGER)
            FROM segments s JOIN files f ON f.id = s.file WHERE s.vec IS NOT NULL ORDER BY s.id
            """) { row in
            guard let blob = row.blob(3), blob.count == rowBytes, rowFile.count < rows else { return }
            blob.copyBytes(to: UnsafeMutableRawBufferPointer(start: matrix.halves + rowFile.count * Vectors.dimension,
                                                             count: rowBytes))
            rowSegment.append(row.int(0))
            rowFile.append(row.int(1))
            rowModality.append(Modality(rawValue: row.text(2) ?? "") ?? .none)
            // Past the first step of a long PDF (its pages) or document (its chunks).
            let (kind, place) = (row.text(4), row.isNull(5) ? 0 : Int(row.double(5)))
            let later = row.text(6) == "pdf"
                ? kind != SegmentKind.chunk.rawValue && Int(row.int(7)) > steps.bigPDFPages && place > steps.pdfStep
                : kind == SegmentKind.chunk.rawValue && place > steps.docStep
            rowSetsScale.append(!later)
        }
        self.matrix = matrix
        vectorsLoaded = true
    }

    /// Frees the vectors' memory; keyword search keeps working.
    public func releaseVectors() {
        matrix = nil
        rowFile = []
        rowSegment = []
        rowModality = []
        rowSetsScale = []
        vectorsLoaded = false
    }

    private func reloadFiles() throws {
        fileKind.removeAll(keepingCapacity: true)
        fileDate.removeAll(keepingCapacity: true)
        var dates = CaptureDates()
        try store.db.query("SELECT id, kind, mtime, json_extract(info, '$.taken') FROM files") { row in
            fileKind[row.int(0)] = FileKind(rawValue: row.text(1) ?? "")
            fileDate[row.int(0)] = dates.date(row.text(3)) ?? Date(timeIntervalSince1970: row.double(2))
        }
        vectorSource = try store.meta("vector_source")
    }

    /// How much finding the query's words counts against meaning (`search`).
    public static let wordWeight = 2.0

    /// How far above the query's average cosine (its `meaning` scale's center) a segment must be to match it. Standing
    /// out (`zGate`) alone let everything through: a library has no giraffe, but its top 2% for "giraffe" still stand
    /// out, so every query found 50 or more photos. On 58 queries over 13,389 vectors (2026-10-30), the best photo for
    /// what wasn't there sat 0.075 ("asdf qwer zxcv") to 0.095 (tiger, "latarnia morska") above it, and for what was,
    /// 0.096 ("plaża") to 0.19: Polish words land lower than English ones ("kot" 0.101, "cat" 0.151). 0.09 keeps every
    /// one that was there and leaves a few weak matches, not 60, for the closest misses.
    public static let minLift = 0.09

    /// The z a segment needs to match on a query whose scale has this `deviation`: `zGate`, or more when the query's
    /// scores are spread so narrowly that standing out is less than `minLift`.
    static func gate(_ zGate: Double, deviation: Double, minLift: Double = minLift) -> Double {
        max(zGate, minLift / deviation)
    }

    /// Hybrid search. `people`: only photos that contain every listed person on the same image (AND). Nil or empty
    /// means no people filter. `dates`: only files taken (or, without a capture date, changed) then.
    public func search(_ text: String, queryVector: [Float]?, kinds: Set<FileKind>? = nil,
                       people: Set<Int64>? = nil, dates: DateSpan? = nil, limit: Int = 20, zGate: Double = 2.0,
                       minLift: Double = Searcher.minLift, wordWeight: Double? = nil,
                       prefixLast: Bool = false, clauseVectors: [[Float]] = []) throws -> [SearchHit] {
        let wordWeight = wordWeight ?? Self.wordWeight
        if queryVector != nil, !vectorsLoaded { try reload() }
        let fileKind = self.fileKind, fileDate = self.fileDate
        // AND: a photo must include Person A and Person B when both are selected.
        let peopleFiles = try store.filesContaining(allPeople: people ?? [])
        let allowed = { (file: Int64) -> Bool in
            guard kinds == nil || fileKind[file].map({ kinds!.contains($0) }) ?? false else { return false }
            if let dates, !(fileDate[file].map(dates.contains) ?? false) { return false }
            if let peopleFiles { return peopleFiles.contains(file) }
            return true
        }

        // Meaning: score every vector on this query's scale (`meaning`), keep each file's best segment.
        var best: [Int64: (z: Double, cosine: Double, row: Int)] = [:]
        var meaningGate = zGate, deviation = 0.0
        if let query = queryVector, query.count == Vectors.dimension, !rowFile.isEmpty {
            let scores = score(query)
            let scaled = Self.scale(scores, rowModality, setsScale: rowSetsScale)
            let meaning = scaled.z
            deviation = scaled.deviation
            meaningGate = Self.gate(zGate, deviation: deviation, minLift: minLift)
            for row in 0..<scores.count where allowed(rowFile[row]) {
                let z = meaning[row]
                if z > (best[rowFile[row]]?.z ?? -.infinity) { best[rowFile[row]] = (z, Double(scores[row]), row) }
            }
        }

        // Words: FTS5 with Porter stemming over file names, folder names, OCR, page and document text.
        let terms = Self.terms(text)
        var words: [(file: Int64, segment: Int64, snippet: String?)] = []
        var coverage: [Int64: Double] = [:]   // share of the query's words found anywhere in the file
        let patterns = Self.patterns(terms, prefixLast: prefixLast)
        if !patterns.isEmpty {
            var seen = Set<Int64>()
            try store.db.query("""
                SELECT s.file, s.id, snippet(fts, 1, '«', '»', '…', 12), fts.original FROM fts
                JOIN segments s ON s.id = fts.rowid
                WHERE fts MATCH ? ORDER BY bm25(fts, 3.0, 1.0) LIMIT 1000
                """, [.text(patterns.joined(separator: " OR "))]) { row in
                let file = row.int(0)
                guard words.count < 100, allowed(file), seen.insert(file).inserted else { return }
                // Text that normalizing changed is quoted as it's written (with its hamza, harakat, joiners).
                let snippet = row.text(3).flatMap { SearchText.snippet($0, terms: terms) } ?? row.text(2)
                words.append((file, row.int(1), snippet))
            }
            if !words.isEmpty {
                let files = words.map { String($0.file) }.joined(separator: ",")
                for pattern in patterns {
                    try store.db.query("""
                        SELECT DISTINCT s.file FROM fts JOIN segments s ON s.id = fts.rowid
                        WHERE fts MATCH ? AND s.file IN (\(files))
                        """, [.text(pattern)]) { coverage[$0.int(0), default: 0] += 1 / Double(patterns.count) }
                }
            }
        }

        // A file qualifies by standing out in meaning, or by containing at least half of the query's words.
        // Score: meaning z + a bonus that grows with word coverage, + 1 for the kind the query asks for.
        // One common word can't beat a strong meaning match; all the words of an exact lookup usually do.
        // (This beat reciprocal-rank fusion on both evals, 2026-10-07: R@1 0.88 vs 0.73 synthetic, 0.86 vs 0.82 real.)
        // Photos also get a light boost from `info.quality` (0…100); queries that ask for nice/best photos lean on it more.
        let lookup = Self.isLookup(terms)
        let (meaningWeight, wordsWeight) = lookup ? (0.5, wordWeight * 2) : (1, wordWeight)
        let parsed = Self.parse(text)
        let hinted = Self.kindHints(text)
        let wantNice = Self.wantsNicePhotos(text)
        let phrases = parsed.expression.phrases
        let boolean = parsed.hasOperators && clauseVectors.count == phrases.count
            && clauseVectors.allSatisfy { $0.count == Vectors.dimension }
        var keywordHits = words
        var scored: [Int64: Double] = [:]
        if boolean {
            // Each phrase is its own embedding. `and` keeps a photo only when every part matches, `or` when any
            // does, and `-` drops a photo whose picture matches that embedding.
            let clauses = clauseVectors.map { matches(for: $0, zGate: zGate, minLift: minLift, allowed: allowed) }
            var matched: [Int64: (score: Double, z: Double, cosine: Double, row: Int)] = [:]
            let files = Set(clauses.flatMap(\.best.keys))
            for file in files where allowed(file) {
                if let hit = Self.evaluate(parsed.expression, file: file, clauses: clauses.map(\.best),
                                           gates: clauses.map(\.gate)) {
                    matched[file] = hit
                }
            }
            best = Dictionary(uniqueKeysWithValues: matched.map { ($0.key, (z: $0.value.z, cosine: $0.value.cosine, row: $0.value.row)) })
            let quality = try photoQuality(of: Set(matched.keys), kinds: fileKind)
            for (file, hit) in matched {
                var score = hit.score
                if let kind = fileKind[file], hinted.contains(kind) { score += 1 }
                if let q = quality[file] { score += (wantNice ? 1.4 : 0.35) * (q / 100) }
                scored[file] = score
            }
            keywordHits = []
        } else {
            var candidates = Set(best.filter { $0.value.z >= meaningGate }.keys)
            for (file, share) in coverage where share >= 0.5 { candidates.insert(file) }
            let quality = try photoQuality(of: candidates, kinds: fileKind)
            for file in candidates {
                var score = meaningWeight * max(best[file]?.z ?? 0, 0) + wordsWeight * pow(coverage[file] ?? 0, 1.5)
                if let kind = fileKind[file], hinted.contains(kind) { score += 1 }
                if let q = quality[file] {
                    // Mild by default so meaning still leads; "best/beautiful/ładne" leans harder on look.
                    score += (wantNice ? 1.4 : 0.35) * (q / 100)
                }
                scored[file] = score
            }
        }

        let wordRank = Dictionary(keywordHits.enumerated().map { ($0.element.file, ($0.offset + 1, $0.element)) },
                                  uniquingKeysWith: { first, _ in first })
        var hits: [SearchHit] = []
        for (file, score) in scored.sorted(by: { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) })
            .prefix(limit) {
            let semantic = best[file]
            let keyword = wordRank[file]
            // Point at the best meaning segment if it stands out; else at the segment the words matched.
            let meant = boolean || semantic.map { $0.z >= meaningGate } ?? false
            let useMeaning = semantic.map { _ in meant || keyword == nil } ?? false
            guard let segmentID = useMeaning ? semantic.map({ rowSegment[$0.row] }) : keyword?.1.segment else { continue }
            var path = "", kind = FileKind.doc, modified = 0.0, size: Int64 = 0, info: [String: String] = [:]
            try store.db.query("SELECT path, kind, mtime, size, info FROM files WHERE id = ?", [.int(file)]) {
                path = $0.text(0) ?? ""
                kind = FileKind(rawValue: $0.text(1) ?? "") ?? .doc
                modified = $0.double(2)
                size = $0.int(3)
                if let json = $0.text(4)?.data(using: .utf8) {
                    info = (try? JSONSerialization.jsonObject(with: json) as? [String: String]) ?? [:]
                }
            }
            var segment = SegmentKind.name, loc: Double?, locEnd: Double?, storedExcerpt: String?
            try store.db.query("SELECT kind, loc, loc_end, excerpt FROM segments WHERE id = ?", [.int(segmentID)]) {
                segment = SegmentKind(rawValue: $0.text(0) ?? "") ?? .name
                loc = $0.isNull(1) ? nil : $0.double(1)
                locEnd = $0.isNull(2) ? nil : $0.double(2)
                storedExcerpt = $0.text(3)
            }
            // Quote the matched words only when they come from the segment we point at, so a PDF hit on page 5
            // never shows page 2's words. A segment with no place and no text of its own (a screenshot's image
            // vector) can borrow them from its file's OCR text, which describes the same picture.
            var snippet = keyword.flatMap { $0.1.segment == segmentID ? $0.1.snippet : nil }
                .flatMap { $0.contains("«") ? excerpt($0, limit: 400) : nil }
            if snippet == nil, storedExcerpt == nil, loc == nil, let match = keyword?.1,
               let text = match.snippet, text.contains("«") {
                var matchedKind: String?
                try store.db.query("SELECT kind FROM segments WHERE id = ?", [.int(match.segment)]) {
                    matchedKind = $0.text(0)
                }
                if matchedKind != SegmentKind.name.rawValue { snippet = excerpt(text, limit: 400) }
            }
            hits.append(SearchHit(path: path, kind: kind, score: score, z: semantic?.z, cosine: semantic?.cosine,
                                  keywordRank: keyword?.0, segment: segment, segmentID: segmentID, loc: loc,
                                  locEnd: locEnd,
                                  excerpt: snippet ?? storedExcerpt, modified: modified, size: size, info: info,
                                  matchedMeaning: meant && semantic != nil,
                                  lift: deviation > 0 ? semantic.map { $0.z * deviation } : nil))
        }
        return PhotoCopies.one(hits, path: \.path, isPhoto: { $0.kind == .image })
    }

    /// Every photo and video with all of `people` on it (AND) and taken in `dates`, newest first: what picking people
    /// or a time shows before anything is typed. No people and no dates is everything. Each points at the picture (a
    /// video at its first frame), like a meaning hit, with the same score (none is a better match).
    public func photos(of people: Set<Int64> = [], in dates: DateSpan? = nil, kinds: Set<FileKind>? = nil,
                       limit: Int = 5000) throws -> [SearchHit] {
        let files = try store.filesContaining(allPeople: people)
        if let files, files.isEmpty { return [] }
        var found: [(date: Date, hit: SearchHit)] = []
        try store.db.query("""
            SELECT f.id, f.path, f.kind, f.mtime, f.size, f.info,
                (SELECT s.id FROM segments s WHERE s.file = f.id AND s.kind IN ('image', 'frame')
                 ORDER BY s.kind = 'frame', s.loc LIMIT 1)
            FROM files f WHERE f.kind IN ('image', 'screenshot', 'video')
            \(files.map { "AND f.id IN (\($0.map(String.init).joined(separator: ",")))" } ?? "")
            """) { row in
            let kind = FileKind(rawValue: row.text(2) ?? "") ?? .image
            guard kinds?.contains(kind) ?? true, !row.isNull(6),
                  let date = fileDate[row.int(0)], dates?.contains(date) ?? true else { return }
            let info = row.text(5)?.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
            found.append((date, SearchHit(path: row.text(1) ?? "", kind: kind, score: 1, z: nil, cosine: nil,
                                          keywordRank: nil, segment: kind == .video ? .frame : .image,
                                          segmentID: row.int(6), loc: nil, locEnd: nil, excerpt: nil,
                                          modified: row.double(3), size: row.int(4), info: info)))
        }
        let newest = found.sorted { $0.date != $1.date ? $0.date > $1.date : $0.hit.path > $1.hit.path }.map(\.hit)
        return Array(PhotoCopies.one(newest, path: \.path, isPhoto: { $0.kind == .image }).prefix(limit))
    }

    /// How many photos and videos were taken in each month: year → month (1…12) → count. The date filter's choices.
    public func photoMonths() -> [Int: [Int: Int]] {
        var months: [Int: [Int: Int]] = [:]
        let calendar = Calendar.current
        for (file, date) in fileDate where [.image, .screenshot, .video].contains(fileKind[file]) {
            let parts = calendar.dateComponents([.year, .month], from: date)
            guard let year = parts.year, let month = parts.month else { continue }
            months[year, default: [:]][month, default: 0] += 1
        }
        return months
    }

    /// Codes and IDs ("K7Q2LM", "TRX50") and long numbers ("4815162342": an order, a phone number) mean nothing to an
    /// embedding but everything to keyword search: a query made of them weighs words double and meaning half. Numbers
    /// count since 2026-10-09, when text of digits lost its vectors (`SearchText.hasWords`): a number in a data dump fell
    /// below unrelated meaning matches.
    static func isLookup(_ terms: [String]) -> Bool {
        !terms.isEmpty && terms.allSatisfy {
            $0.contains(where: \.isNumber) && ($0.contains(where: \.isLetter) || $0.count >= 4)
        }
    }

    /// How many of `hits` (best first) are strong: scoring at least `ratio` × the top hit. The rest pass the gates but
    /// trail far behind, and the app folds them under "weaker matches". On both evals (2026-10-07), 0.5 cut the list
    /// from 26.2 to 5.7 results per query and never folded an expected answer.
    ///
    /// A meaning match also trails when it's `foldLift` less close to the query than the closest: past the gates, a big
    /// library still has a hundred photos for "cat" or "elephant", and the last ones were screenshots and rooms
    /// (2026-10-30). Hits stay in score order, so the first that trails ends the strong ones.
    public static func strongCount(_ hits: [SearchHit], ratio: Double = 0.5) -> Int {
        guard let top = hits.first?.score, top > 0 else { return hits.count }
        let closest = hits.compactMap { $0.matchedMeaning ? $0.lift : nil }.max()
        return hits.prefix { hit in
            hit.score >= top * ratio
                && (hit.keywordRank != nil || !hit.matchedMeaning || closest.map { hit.lift ?? 0 >= $0 - foldLift } ?? true)
        }.count
    }

    /// How much less close than the closest a meaning match can be and still be strong (`strongCount`).
    public static let foldLift = 0.04

    /// One clause's best segment per file, and the z it needs to match (`gate`). `allowed` is the kind and people
    /// filter from `search`.
    private func matches(for vector: [Float], zGate: Double, minLift: Double, allowed: (Int64) -> Bool)
        -> (best: [Int64: (z: Double, cosine: Double, row: Int)], gate: Double) {
        guard vector.count == Vectors.dimension, !rowFile.isEmpty else { return ([:], zGate) }
        let scores = score(vector)
        let (meaning, deviation) = Self.scale(scores, rowModality, setsScale: rowSetsScale)
        var best: [Int64: (z: Double, cosine: Double, row: Int)] = [:]
        for row in 0..<scores.count where allowed(rowFile[row]) {
            let z = meaning[row]
            if z > (best[rowFile[row]]?.z ?? -.infinity) { best[rowFile[row]] = (z, Double(scores[row]), row) }
        }
        return (best, Self.gate(zGate, deviation: deviation, minLift: minLift))
    }

    /// Cosine similarity of `query` with every stored vector (all are L2-normalized): a matrix-vector product, done a
    /// block of rows at a time, each block turned into float32 first.
    private func score(_ query: [Float]) -> [Float] {
        let rows = rowFile.count
        var scores = [Float](repeating: 0, count: rows)
        guard let matrix, rows > 0 else { return scores }
        query.withUnsafeBufferPointer { query in
            scores.withUnsafeMutableBufferPointer { scores in
                var row = 0
                while row < rows {
                    let count = min(VectorStorage.blockRows, rows - row)
                    Vectors.floats(fromHalf: matrix.halves + row * Vectors.dimension, count: count * Vectors.dimension,
                                   to: matrix.block)
                    // (count × 768) · (768 × 1)
                    Linear.multiply(matrix.block, rows: count, columns: Vectors.dimension, by: query.baseAddress!,
                                    into: scores.baseAddress! + row)
                    row += count
                }
            }
        }
        return scores
    }

    /// This query's meaning scores: each vector's cosine similarity minus the average of its modality (text, image and
    /// audio vectors can sit at slightly different levels for the same query), in standard deviations of all of them
    /// together. Within a modality that's the model's own order. Scaling each modality by its own deviation instead
    /// inflated the narrow ones and buried PDF pages under pictures (2026-10-08, on the three evals: 91 → 94 of 105
    /// queries with the right answer first).
    ///
    /// The scale (the averages and the deviation) comes from the vectors in `setsScale` (all by default): `search` leaves
    /// out the later pages of long files, which are scored on it but don't move it. A book's hundreds of pages pulled the
    /// text average down for every query, and documents rose over screenshots everywhere (2026-10-09, the testbed's long
    /// files finished: real eval 24 → 22 of 26 first; 24 with the scale kept).
    static func meaning(_ scores: [Float], _ modality: [Modality], setsScale: [Bool]? = nil) -> [Double] {
        scale(scores, modality, setsScale: setsScale).z
    }

    /// `meaning`, and the deviation it divides by: a z times it is how far above the query's average a segment is.
    static func scale(_ scores: [Float], _ modality: [Modality], setsScale: [Bool]? = nil)
        -> (z: [Double], deviation: Double) {
        let means = modalityMeans(scores, modality, setsScale: setsScale)
        let centered = zip(scores, modality).map { Double($0) - means[$1, default: 0] }
        var count = 0.0, sum = 0.0
        for row in centered.indices where setsScale?[row] ?? true {
            count += 1
            sum += centered[row]
        }
        let mean = sum / max(count, 1)
        var squares = 0.0
        for row in centered.indices where setsScale?[row] ?? true {
            squares += (centered[row] - mean) * (centered[row] - mean)
        }
        let deviation = max((squares / max(count, 1)).squareRoot(), 0.02)
        return (centered.map { ($0 - mean) / deviation }, deviation)
    }

    /// The average score of each modality for this query. Small groups (< 20 vectors) take the average of all.
    static func modalityMeans(_ scores: [Float], _ modality: [Modality], setsScale: [Bool]? = nil) -> [Modality: Double] {
        var sum: [Modality: Double] = [:], count: [Modality: Int] = [:]
        for row in scores.indices where setsScale?[row] ?? true {
            sum[modality[row], default: 0] += Double(scores[row])
            count[modality[row], default: 0] += 1
        }
        let all = sum.values.reduce(0, +) / Double(max(count.values.reduce(0, +), 1))
        var out: [Modality: Double] = [:]
        for modality in Modality.allCases {
            if let n = count[modality], n >= 20 {
                out[modality] = sum[modality]! / Double(n)
            } else {
                out[modality] = all
            }
        }
        return out
    }

    /// The text of a page, a document's passage or a screenshot's OCR, as it's written: the preview shows the part of a
    /// document that matched.
    public func text(ofSegment id: Int64) throws -> String? {
        var text: String?
        try store.db.query("SELECT coalesce(original, body) FROM fts WHERE rowid = ?", [.int(id)]) { text = $0.text(0) }
        return text
    }

    /// A boolean query. A plain question with no `and`, `or`, `-`, or parentheses stays one phrase, embedded as written.
    /// `and` binds tighter than `or`. `-` (also a leading `-word`) excludes the next phrase or parenthesized group
    /// and combines with what came before: `person - screenshot` is a person and not a screenshot.
    /// `(person or cat) - screenshot` excludes screenshots from either.
    public indirect enum QueryExpr: Sendable, Equatable {
        case phrase(String)
        case and([QueryExpr])
        case or([QueryExpr])
        case not(QueryExpr)

        /// Every phrase, in the order `embedPhrases` embeds them. An exclusion still needs a vector.
        var phrases: [String] {
            switch self {
            case .phrase(let text): return text.isEmpty ? [] : [text]
            case .and(let parts), .or(let parts): return parts.flatMap(\.phrases)
            case .not(let inner): return inner.phrases
            }
        }

        /// Phrases that must be found. Exclusions are left out, so "screenshot" in `person - screenshot` is not a
        /// kind hint and not a keyword.
        var positivePhrases: [String] {
            switch self {
            case .phrase(let text): return text.isEmpty ? [] : [text]
            case .and(let parts), .or(let parts): return parts.flatMap(\.positivePhrases)
            case .not: return []
            }
        }

        public var summary: String {
            switch self {
            case .phrase(let text): return "“\(text)”"
            case .and(let parts): return parts.map(\.summary).joined(separator: " and ")
            case .or(let parts): return parts.map(\.summary).joined(separator: " or ")
            case .not(let inner): return "- \(inner.summary)"
            }
        }
    }

    public struct ParsedQuery: Sendable, Equatable {
        public var expression: QueryExpr
        /// False when the text has no operator and no parentheses: one embedding of the text as written.
        public var hasOperators: Bool
        public var positiveText: String { expression.positivePhrases.joined(separator: " ") }
    }

    /// `person - screenshot`, `person and screenshot`, `person or screenshot`, `(person or cat) - screenshot`.
    public static func parse(_ text: String) -> ParsedQuery {
        let tokens = QueryParser.tokenize(text)
        let operated = tokens.contains { token in
            switch token {
            case .and, .or, .minus, .lparen, .rparen: return true
            case .word: return false
            }
        }
        guard operated else { return ParsedQuery(expression: .phrase(text), hasOperators: false) }
        var parser = QueryParser(tokens: tokens)
        return ParsedQuery(expression: parser.parseOr(), hasOperators: true)
    }

    /// Whether `file` satisfies `expr`. `clauses` and `gates` line up with `expr.phrases`: a phrase matches at its gate.
    /// `and` requires every part; `or` any part; `not` hides a match instead of ranking it lower.
    static func evaluate(_ expr: QueryExpr, file: Int64,
                         clauses: [[Int64: (z: Double, cosine: Double, row: Int)]], gates: [Double])
        -> (score: Double, z: Double, cosine: Double, row: Int)? {
        var index = 0
        func walk(_ expr: QueryExpr) -> (ok: Bool, score: Double, z: Double, cosine: Double, row: Int?) {
            switch expr {
            case .phrase:
                let slot = index
                index += 1
                guard slot < clauses.count, slot < gates.count, let hit = clauses[slot][file] else { return (false, 0, 0, 0, nil) }
                return (hit.z >= gates[slot], hit.z, hit.z, hit.cosine, hit.row)
            case .not(let inner):
                let inner = walk(inner)
                return (!inner.ok, 0, 0, 0, nil)
            case .and(let parts):
                var limiting = Double.infinity
                var cosine = 0.0
                var row: Int?
                var ok = true
                var sawPositive = false
                for part in parts {
                    let piece = walk(part)
                    guard piece.ok else { ok = false; continue }
                    // An exclusion succeeds with no row. It hides matches and does not pull the score down.
                    guard piece.row != nil else { continue }
                    sawPositive = true
                    if piece.z < limiting { (limiting, cosine, row) = (piece.z, piece.cosine, piece.row) }
                }
                guard ok, sawPositive, let row else { return (false, 0, 0, 0, nil) }
                return (true, limiting, limiting, cosine, row)
            case .or(let parts):
                var best: (ok: Bool, score: Double, z: Double, cosine: Double, row: Int?) = (false, -.infinity, 0, 0, nil)
                for part in parts {
                    let piece = walk(part)
                    if piece.ok, piece.score >= best.score { best = piece }
                }
                guard best.ok, let row = best.row else { return (false, 0, 0, 0, nil) }
                return (true, best.score, best.z, best.cosine, row)
            }
        }
        let result = walk(expr)
        guard result.ok, let row = result.row else { return nil }
        return (result.score, result.z, result.cosine, row)
    }

    /// Phrases to embed, in `QueryExpr.phrases` order. A query with no operators embeds the original text as one vector.
    public static func embedPhrases(_ text: String) -> [String] {
        let query = parse(text)
        guard query.hasOperators else { return [text] }
        let phrases = query.expression.phrases
        return phrases.isEmpty ? [text] : phrases
    }

    /// Words, `and` / `or` / `-`, and parentheses. A hyphen inside a word (`well-known`) stays part of the word.
    private struct QueryParser {
        enum Token: Equatable {
            case word(String)
            case and, or, minus, lparen, rparen
        }

        var tokens: [Token]
        var index = 0

        static func tokenize(_ text: String) -> [Token] {
            var tokens: [Token] = []
            for raw in text.split(whereSeparator: \.isWhitespace) {
                var piece = String(raw)
                while piece.hasPrefix("(") {
                    tokens.append(.lparen)
                    piece.removeFirst()
                }
                var closing: [Token] = []
                while piece.hasSuffix(")") {
                    closing.append(.rparen)
                    piece.removeLast()
                }
                switch piece.lowercased() {
                case "": break
                case "and": tokens.append(.and)
                case "or": tokens.append(.or)
                case "-": tokens.append(.minus)
                default:
                    if piece.hasPrefix("-"), piece.count > 1 {
                        tokens.append(.minus)
                        tokens.append(.word(String(piece.dropFirst())))
                    } else {
                        tokens.append(.word(piece))
                    }
                }
                tokens.append(contentsOf: closing)
            }
            return tokens
        }

        private func peek() -> Token? { index < tokens.count ? tokens[index] : nil }

        private mutating func consume(_ token: Token) -> Bool {
            guard peek() == token else { return false }
            index += 1
            return true
        }

        fileprivate mutating func parseOr() -> QueryExpr {
            var parts = [parseAnd()]
            while consume(.or) { parts.append(parseAnd()) }
            return flatten({ .or($0) }, parts)
        }

        private mutating func parseAnd() -> QueryExpr {
            var parts = [parseUnary()]
            while true {
                if consume(.and) {
                    parts.append(parseUnary())
                } else if consume(.minus) {
                    parts.append(.not(parseUnary()))
                } else {
                    break
                }
            }
            return flatten({ .and($0) }, parts)
        }

        private mutating func parseUnary() -> QueryExpr {
            if consume(.minus) { return .not(parseUnary()) }
            return parsePrimary()
        }

        private mutating func parsePrimary() -> QueryExpr {
            if consume(.lparen) {
                let inner = parseOr()
                _ = consume(.rparen)
                return inner
            }
            var words: [String] = []
            while case .word(let word) = peek() {
                words.append(word)
                index += 1
            }
            return .phrase(words.joined(separator: " "))
        }

        /// Drops an empty phrase (`and` with nothing after it) and unwraps a single part.
        private func flatten(_ join: ([QueryExpr]) -> QueryExpr, _ parts: [QueryExpr]) -> QueryExpr {
            let kept = parts.filter { expr in
                if case .phrase(let text) = expr { return !text.isEmpty }
                return true
            }
            if kept.count == 1 { return kept[0] }
            if kept.isEmpty { return .phrase("") }
            return join(kept)
        }
    }

    static let stopwords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "with", "and", "or", "my", "me", "that", "this",
        "these", "those", "from", "about", "where", "what", "which", "who", "when", "is", "was", "are", "were", "be",
        "it", "its", "some", "any", "find", "show", "file", "files", "photo", "photos", "picture", "image", "images",
        "screenshot", "screenshots", "video", "videos", "pdf", "document", "documents", "recording",
        // Aesthetic asks ("best photos of…"): they steer ranking via `wantsNicePhotos`, not keyword search.
        "best", "nicest", "nice", "beautiful", "pretty", "gorgeous", "stunning", "lovely", "favorite", "favourite",
        "sharpest", "clearest", "aesthetic", "ładne", "ładnych", "ładny", "ładna", "najładniejsze", "najładniejszych",
        "piękne", "pięknych", "fajne", "najlepsze", "najlepszych",
        // Bengali and Arabic (normalized, as `terms` sees them)
        "এবং", "ও", "এই", "সেই", "একটি", "আমার", "থেকে", "জন্য", "সাথে", "মধ্যে", "কোথায়", "কোন", "কী", "কি", "যে",
        "ছবি", "স্ক্রিনশট", "ভিডিও", "ফাইল", "পিডিএফ",
        "في", "من", "على", "الى", "عن", "مع", "هذا", "هذه", "ذلك", "التي", "الذي", "اين", "ما",
        "صورة", "صور", "لقطة", "شاشة", "فيديو", "ملف", "مستند",
    ]

    /// The content words of a query, normalized as keyword search keeps its text (`SearchText`). Kind words
    /// ("screenshot", "video") and stopwords are dropped: they describe what to look for, not what's in it. Words of
    /// two letters or more count; a Bengali letter with its vowel sign ("মা") is two.
    public static func terms(_ text: String) -> [String] {
        let ask = parse(text).positiveText
        var seen = Set<String>()
        return SearchText.normalized(ask).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.unicodeScalars.count >= 2 && !stopwords.contains($0) && seen.insert($0).inserted }
    }

    /// FTS5 patterns for the query's words: quoted, and as prefixes for the last word while it's being typed and for
    /// words of languages that attach endings (`SearchText.inflects`).
    static func patterns(_ terms: [String], prefixLast: Bool) -> [String] {
        terms.enumerated().map { index, term in
            let prefix = (prefixLast && index == terms.count - 1) || SearchText.inflects(term)
            return "\"\(term)\"" + (prefix ? "*" : "")
        }
    }

    /// The query's words as an FTS5 OR-query.
    public static func ftsQuery(_ text: String, prefixLast: Bool = false) -> String? {
        let words = terms(text)
        guard !words.isEmpty else { return nil }
        return patterns(words, prefixLast: prefixLast).joined(separator: " OR ")
    }

    static let kindWords: [String: FileKind] = [
        "screenshot": .screenshot, "screenshots": .screenshot, "photo": .image, "photos": .image, "picture": .image,
        "pictures": .image, "image": .image, "images": .image, "pdf": .pdf, "pdfs": .pdf, "paper": .pdf,
        "papers": .pdf, "document": .doc, "documents": .doc, "note": .doc, "notes": .doc, "video": .video,
        "videos": .video, "clip": .video, "movie": .video, "audio": .audio, "song": .audio, "podcast": .audio,
        "voice": .audio, "sound": .audio,
        "স্ক্রিনশট": .screenshot, "ছবি": .image, "পিডিএফ": .pdf, "নোট": .doc, "ভিডিও": .video, "অডিও": .audio,
        "গান": .audio, "রেকর্ডিং": .audio,
        "لقطة": .screenshot, "صورة": .image, "صور": .image, "مستند": .doc, "ملاحظات": .doc, "فيديو": .video,
        "مقطع": .video, "صوت": .audio, "تسجيل": .audio, "اغنية": .audio,
    ]

    /// Kinds the query asks for ("…in a video", "screenshot of…", "ভিডিওতে"): a soft boost, not a filter. Bengali
    /// attaches case endings, so a Bengali kind word also counts at the start of a longer word.
    static func kindHints(_ text: String) -> Set<FileKind> {
        let ask = parse(text).positiveText
        return Set(SearchText.normalized(ask).lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .compactMap { word in
                kindWords[word] ?? kindWords.first { key, _ in
                    SearchText.inflects(key) && key.unicodeScalars.count >= 3 && word.hasPrefix(key)
                }?.value
            })
    }

    /// Words that ask for nicer photos ("best", "beautiful", "ładne"): lean harder on `info.quality`.
    static let niceWords: Set<String> = [
        "best", "nicest", "nice", "beautiful", "pretty", "gorgeous", "stunning", "lovely", "favorite", "favourite",
        "sharpest", "clearest", "aesthetic",
        "ładne", "ładnych", "ładny", "ładna", "najładniejsze", "najładniejszych", "piękne", "pięknych", "fajne",
        "najlepsze", "najlepszych",
    ]

    static func wantsNicePhotos(_ text: String) -> Bool {
        let ask = parse(text).positiveText
        let words = Set(SearchText.normalized(ask).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        return !words.isDisjoint(with: niceWords)
    }

    /// `info.quality` for photo candidates (0…100). Missing when the file isn't a photo or wasn't scored yet.
    private func photoQuality(of candidates: Set<Int64>, kinds: [Int64: FileKind]) throws -> [Int64: Double] {
        let photos = candidates.filter { kinds[$0] == .image }
        guard !photos.isEmpty else { return [:] }
        var quality: [Int64: Double] = [:]
        let list = photos.map(String.init).joined(separator: ",")
        try store.db.query("""
            SELECT id, json_extract(info, '$.quality') FROM files
            WHERE id IN (\(list)) AND json_extract(info, '$.quality') IS NOT NULL
            """) { row in
            if let value = row.text(1).flatMap(Double.init) { quality[row.int(0)] = value }
        }
        return quality
    }
}

/// Capture dates as indexing wrote them (`CaptureInfo.date`), read many at a time: one ISO-8601 reader for them all.
struct CaptureDates {
    private let iso = ISO8601DateFormatter()

    func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if text.contains("-") { return iso.date(from: text) ?? CaptureInfo.date(from: text) }
        return CaptureInfo.date(from: text)
    }
}
