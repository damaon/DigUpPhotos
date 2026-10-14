import Accelerate
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
}

/// Hybrid search: meaning (EmbeddingGemma's vectors) + words (FTS5).
///
/// Meaning is the model's cosine similarity, put on one scale per query (`meaning`): every vector is scored anyway, so
/// the distribution comes for free, and only segments that stand out (`zGate`) count as meaning matches. That also
/// gives an honest "nothing found". Words rescue what a vector can't hold exactly: codes, IDs and names.
public final class Searcher {
    let store: IndexStore
    private var matrix: VectorStorage?   // rows × 768 float16, row-major
    private var rowFile: [Int64] = []
    private var rowSegment: [Int64] = []
    private var rowModality: [Modality] = []
    /// False for the vectors the later pass adds (`Indexer.finishLongFiles`): scored, but they don't set the scale.
    private var rowSetsScale: [Bool] = []
    private var fileKind: [Int64: FileKind] = [:]
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
        try store.db.query("SELECT id, kind FROM files") { row in
            fileKind[row.int(0)] = FileKind(rawValue: row.text(1) ?? "")
        }
        vectorSource = try store.meta("vector_source")
    }

    /// How much finding the query's words counts against meaning (`search`).
    public static let wordWeight = 2.0

    /// Hybrid search. `people`: only photos that contain every listed person on the same image (AND). Nil or empty
    /// means no people filter.
    public func search(_ text: String, queryVector: [Float]?, kinds: Set<FileKind>? = nil,
                       people: Set<Int64>? = nil, limit: Int = 20, zGate: Double = 2.0, wordWeight: Double? = nil,
                       prefixLast: Bool = false, negativeVectors: [[Float]] = []) throws -> [SearchHit] {
        let wordWeight = wordWeight ?? Self.wordWeight
        if queryVector != nil, !vectorsLoaded { try reload() }
        let fileKind = self.fileKind
        // AND: a photo must include Person A and Person B when both are selected.
        let peopleFiles = try store.filesContaining(allPeople: people ?? [])
        let allowed = { (file: Int64) -> Bool in
            guard kinds == nil || fileKind[file].map({ kinds!.contains($0) }) ?? false else { return false }
            if let peopleFiles { return peopleFiles.contains(file) }
            return true
        }

        // Meaning: score every vector on this query's scale (`meaning`), keep each file's best segment.
        var best: [Int64: (z: Double, cosine: Double, row: Int)] = [:]
        if let query = queryVector, query.count == Vectors.dimension, !rowFile.isEmpty {
            let scores = score(query)
            let meaning = Self.meaning(scores, rowModality, setsScale: rowSetsScale)
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
        let hinted = Self.kindHints(text)
        let wantNice = Self.wantsNicePhotos(text)
        var candidates = Set(best.filter { $0.value.z >= zGate }.keys)
        for (file, share) in coverage where share >= 0.5 { candidates.insert(file) }
        let quality = try photoQuality(of: candidates, kinds: fileKind)
        var scored: [Int64: Double] = [:]
        for file in candidates {
            var score = meaningWeight * max(best[file]?.z ?? 0, 0) + wordsWeight * pow(coverage[file] ?? 0, 1.5)
            if let kind = fileKind[file], hinted.contains(kind) { score += 1 }
            if let q = quality[file] {
                // Mild by default so meaning still leads; "best/beautiful/ładne" leans harder on look.
                score += (wantNice ? 1.4 : 0.35) * (q / 100)
            }
            scored[file] = score
        }
        // "without rice": the ask is rank 1, each excluded concept is rank 2, and a file's place is rank 1 minus
        // how well it matches the exclusion (its meaning, or the word itself when that's stronger).
        let excluded = Self.ranked(text).excluded
        if !excluded.isEmpty {
            var penalty: [Int64: Double] = [:]
            for vector in negativeVectors where vector.count == Vectors.dimension {
                let scores = score(vector)
                let meaning = Self.meaning(scores, rowModality, setsScale: rowSetsScale)
                for row in 0..<scores.count where allowed(rowFile[row]) {
                    let z = meaning[row]
                    guard z > 0 else { continue }
                    let file = rowFile[row]
                    if z > (penalty[file] ?? 0) { penalty[file] = z }
                }
            }
            let patterns = Self.patterns(Self.terms(excluded.joined(separator: " ")), prefixLast: prefixLast)
            if !patterns.isEmpty {
                try store.db.query("""
                    SELECT DISTINCT s.file FROM fts JOIN segments s ON s.id = fts.rowid
                    WHERE fts MATCH ?
                    """, [.text(patterns.joined(separator: " OR "))]) { row in
                    let file = row.int(0)
                    guard allowed(file) else { return }
                    penalty[file] = max(penalty[file] ?? 0, zGate)
                }
            }
            for (file, down) in penalty where scored[file] != nil {
                scored[file]! -= down
            }
        }

        let wordRank = Dictionary(words.enumerated().map { ($0.element.file, ($0.offset + 1, $0.element)) },
                                  uniquingKeysWith: { first, _ in first })
        var hits: [SearchHit] = []
        for (file, score) in scored.sorted(by: { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) })
            .prefix(limit) {
            let semantic = best[file]
            let keyword = wordRank[file]
            // Point at the best meaning segment if it stands out; else at the segment the words matched.
            let useMeaning = semantic.map { $0.z >= zGate || keyword == nil } ?? false
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
                                  excerpt: snippet ?? storedExcerpt, modified: modified, size: size, info: info))
        }
        return hits
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
    public static func strongCount(_ hits: [SearchHit], ratio: Double = 0.5) -> Int {
        guard let top = hits.first?.score, top > 0 else { return hits.count }
        return hits.prefix { $0.score >= top * ratio }.count
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
                    vDSP_mmul(matrix.block, 1, query.baseAddress!, 1, scores.baseAddress! + row, 1,
                              vDSP_Length(count), 1, vDSP_Length(Vectors.dimension))
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
        return centered.map { ($0 - mean) / deviation }
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

    /// A query split into what to find and what to rank below it.
    /// "best photos without rice" → find "best photos", then subtract matches of "rice".
    public struct RankedQuery: Sendable, Equatable {
        public var positive: String
        public var excluded: [String]

        public init(positive: String, excluded: [String]) {
            self.positive = positive
            self.excluded = excluded
        }
    }

    /// Words that start an exclusion: the rest of the query is ranked against the part before them.
    static let negationWords: Set<String> = ["without", "except", "minus", "not", "bez", "poza", "nie"]

    /// "best photos without rice" → positive "best photos", excluded ["rice"].
    /// With no exclusion, `positive` is the text as written.
    public static func ranked(_ text: String) -> RankedQuery {
        var prepared = SearchText.normalized(text)
        prepared = prepared.replacingOccurrences(of: "w/o", with: " without ", options: [.caseInsensitive])
        let words = prepared.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        var positive: [String] = []
        var excluded: [String] = []
        var excluding = false
        for word in words {
            let lower = word.lowercased()
            if negationWords.contains(lower) {
                excluding = true
                continue
            }
            if excluding {
                if lower == "and" || lower == "or" || lower == "nor" || lower == "i" { continue }
                excluded.append(lower)
            } else {
                positive.append(word)
            }
        }
        guard excluding else { return RankedQuery(positive: text, excluded: []) }
        return RankedQuery(positive: positive.joined(separator: " "), excluded: excluded)
    }

    /// Phrases to embed, positive first. Exclusions follow, so their vectors can be subtracted.
    public static func embedPhrases(_ text: String) -> [String] {
        let query = ranked(text)
        guard !query.excluded.isEmpty else { return [text] }
        return (query.positive.isEmpty ? [] : [query.positive]) + query.excluded
    }

    static let stopwords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "with", "and", "or", "my", "me", "that", "this",
        "these", "those", "from", "about", "where", "what", "which", "who", "when", "is", "was", "are", "were", "be",
        "it", "its", "some", "any", "find", "show", "file", "files", "photo", "photos", "picture", "image", "images",
        "screenshot", "screenshots", "video", "videos", "pdf", "document", "documents", "recording",
        // Aesthetic asks ("best photos of…"): they steer ranking via `wantsNicePhotos`, not keyword search.
        "best", "nicest", "nice", "beautiful", "pretty", "gorgeous", "stunning", "lovely", "favorite", "favourite",
        "sharpest", "clearest", "aesthetic", "ładne", "ładnych", "ładny", "ładna", "najładniejsze", "najładniejszych",
        "piękne", "pięknych", "fajne", "najlepsze", "najlepszych", "without", "except", "minus", "not", "bez", "poza",
        "nie",
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
        let ask = ranked(text).positive
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
        let ask = ranked(text).positive
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
        let ask = ranked(text).positive
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
