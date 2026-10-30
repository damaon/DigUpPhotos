import DigUpApple
import DigUpCore
import Foundation
import LlamaRuntime

// DigUp's developer CLI. Every command works on an explicit index folder, so tests never touch the real one.

/// The index the app keeps (and the CLI uses without `--index`).
let defaultIndex = dataFolder.appendingPathComponent("index.noindex")

signal(SIGPIPE, SIG_IGN)   // a dead worker must surface as an error, not kill us

let usage = """
    digup: search your files by meaning (DigUp developer CLI)

      digup estimate <folder>... [--json]     what would be indexed, and how long the first pass takes
      digup index <folder>... [--limit N]     sync the index with these folders, embed what's new, then the rest
                                              of long PDFs and documents
      digup search <words>... [--kind K,K] [--person ID]... [-n 10] [--json]
                                              --person is AND (all on one photo)
      digup people [--rename ID=Name] [--regroup]
                                              list people from face clusters, name one, or group faces again
      digup status                            what's in the index
      digup eval <queries.json> [-n 10]       recall of known answers (see evals/)
      digup index-service <folder>... [--backfill] [--prune]
                                              the app's indexing helper (JSON lines; see IndexService)
      digup worker [--text-only]              the model as a process (JSON lines; the app's query encoder)
      digup mcp                               the index as an MCP server on stdin/stdout, for AI agents
                                              (tools: search, photos, people, status)

    Options:
      --index DIR          index folder (default: \(defaultIndex.path))
      --kind K,K           screenshot, image, pdf, doc, audio, video
      --person ID          only photos that include this person (repeatable: AND — all must be on the same photo)
      --include-datasets   don't skip folders that look like datasets
      --photos-video       index only photos and videos (screenshots, PDFs, documents and audio are skipped)
      --exclude DIR        don't index this folder (repeatable)
      --exclude-ext EXT    don't index files with this extension (repeatable, or comma-separated: "heic,txt")
      --reindex            drop vectors and embed everything again (after changing settings or model)
      --zgate Z            how far a meaning match must stand out (default 2.0)
      --minlift L          how far above the query's average cosine a meaning match must be (default 0.09)
      --word-weight W      bonus for containing all of the query's words (default 2.0)
      --shot-tokens N      vision tokens per screenshot (default 280; 560 was 2× slower, no better on real shots)

    The model: EmbeddingGemma 2 on llama.cpp, from $DIGUP_MODELS (only there, when set), else
    \(ModelFiles.installed.path) or the Hugging Face cache. DIGUP_WORKER_DIR=worker uses the
    mlx-vlm reference worker instead (evals).
    """

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Arguments {
    var positional: [String] = []
    var values: [String: String] = [:]
    var lists: [String: [String]] = [:]
    var flags: Set<String> = []
    static let valued: Set<String> = ["--index", "--limit", "--kind", "-n", "--zgate", "--minlift", "--word-weight", "--new-limit",
                                      "--linger", "--shot-tokens", "--rename"]
    static let repeated: Set<String> = ["--exclude", "--exclude-ext", "--person"]

    init(_ raw: ArraySlice<String>) throws {
        var index = raw.startIndex
        while index < raw.endIndex {
            let argument = raw[index]
            if Self.valued.contains(argument) || Self.repeated.contains(argument) {
                guard index + 1 < raw.endIndex else { throw CLIError("\(argument) needs a value") }
                if Self.repeated.contains(argument) {
                    lists[argument, default: []].append(raw[index + 1])
                } else {
                    values[argument] = raw[index + 1]
                }
                index += 2
            } else if argument.hasPrefix("--") || argument == "-h" {
                flags.insert(argument)
                index += 1
            } else {
                positional.append(argument)
                index += 1
            }
        }
    }

    var indexFolder: URL {
        values["--index"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
            ?? defaultIndex
    }

    func store() throws -> IndexStore {
        try IndexStore(directory: indexFolder)
    }

    var options: IndexOptions {
        var options = IndexOptions()
        options.includeDatasets = flags.contains("--include-datasets")
        if flags.contains("--photos-video") { options.kinds = FileKind.photosAndVideo }
        options.excludedFolders = (lists["--exclude"] ?? []).map { Self.folderURL($0).path }
        options.excludedExtensions = IndexOptions.extensions((lists["--exclude-ext"] ?? []).joined(separator: ","))
        if let tokens = values["--shot-tokens"].flatMap(Int.init) { options.screenshotBudget = tokens }
        return options
    }

    func folders() throws -> [URL] {
        guard !positional.isEmpty else { throw CLIError("which folders? e.g. digup index ~/DigUpTestbed") }
        return try positional.map {
            let url = Self.folderURL($0)
            guard Self.isFolder(url) else { throw CLIError("not a folder: \($0)") }
            guard Self.isReadable(url) else { throw CLIError("can't read \($0) (macOS privacy settings?)") }
            return url
        }
    }

    static func folderURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    static func isFolder(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// The folder can be listed. One that macOS won't let us read (Files and Folders privacy) looks empty to a crawl,
    /// which must never be mistaken for "everything in it was deleted". (The first look may bring up macOS's prompt.)
    static func isReadable(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil
    }

    /// Dev knobs for A/B runs in evals/.
    var zGate: Double { values["--zgate"].flatMap(Double.init) ?? 2.0 }
    var minLift: Double { values["--minlift"].flatMap(Double.init) ?? Searcher.minLift }
    var wordWeight: Double? { values["--word-weight"].flatMap(Double.init) }   // nil: the index's own (`Searcher`)

    func kinds() throws -> Set<FileKind>? {
        guard let list = values["--kind"] else { return nil }
        return Set(try list.split(separator: ",").map {
            guard let kind = FileKind(rawValue: $0.trimmingCharacters(in: .whitespaces)) else {
                throw CLIError("unknown kind \($0); use screenshot, image, pdf, doc, audio, video")
            }
            return kind
        })
    }

    /// `--person ID` (repeatable): photos must contain every listed person together.
    func people() throws -> Set<Int64>? {
        guard let list = lists["--person"], !list.isEmpty else { return nil }
        return Set(try list.map {
            guard let id = Int64($0) else { throw CLIError("person id must be a number: \($0)") }
            return id
        })
    }
}

// MARK: Formatting

let home = FileManager.default.homeDirectoryForCurrentUser.path
func tilde(_ path: String) -> String { path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path }
func pad(_ text: String, _ width: Int) -> String { text.count >= width ? text : text + String(repeating: " ", count: width - text.count) }
func lpad(_ text: String, _ width: Int) -> String { text.count >= width ? text : String(repeating: " ", count: width - text.count) + text }
func number(_ value: Int) -> String { value.formatted(.number) }

func duration(_ seconds: Double) -> String {
    switch seconds {
    case ..<90: "\(Int(seconds.rounded())) s"
    case ..<5400: "\(Int((seconds / 60).rounded())) min"
    default: String(format: "%.1f h", seconds / 3600)
    }
}

func clock(_ seconds: Double) -> String {
    let total = Int(seconds)
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                         : String(format: "%d:%02d", total / 60, total % 60)
}

func location(_ hit: SearchHit) -> String {
    switch hit.segment {
    case .page, .pageImage: hit.loc.map { "p. \(Int($0))" } ?? ""
    case .audio, .frame: hit.loc.map { "at \(clock($0))" + (hit.segment == .audio ? " (sound)" : "") } ?? ""
    case .chunk: hit.loc.map { "part \(Int($0))" } ?? ""
    case .ocr: "text in image"
    default: ""
    }
}

func skippedLine(_ skipped: [String: Int]) -> String {
    skipped.sorted { $0.value > $1.value }.map { "\(number($0.value)) \($0.key)" }.joined(separator: " · ")
}

// MARK: Commands

/// The embedding runtime: llama.cpp in this process, or the worker in $DIGUP_WORKER_DIR (the mlx-vlm reference).
func makeEmbedder(textOnly: Bool, log: URL, qos: QualityOfService = .default) throws -> any Embedder {
    if var config = try WorkerConfig.fromEnvironment() {
        config.log = log
        config.qos = qos
        return try EmbeddingWorker(config, textOnly: textOnly)
    }
    return try LlamaEmbedder(models: try LlamaModels.locate(), textOnly: textOnly, log: log)
}

/// `makeEmbedder`'s vector source when it's known without starting it: llama.cpp's always is.
func embedderSource() -> String? {
    ProcessInfo.processInfo.environment["DIGUP_WORKER_DIR"] == nil ? LlamaEmbedder.modelInfo.vectorSource : nil
}

func estimate(_ args: Arguments) throws {
    guard !args.positional.isEmpty else { throw CLIError("which folders? e.g. digup estimate ~/Documents") }
    let options = args.options
    var total = 0.0
    for folder in args.positional.map(Arguments.folderURL) {
        // One folder that isn't there or can't be read (a denied privacy prompt) mustn't sink the others.
        guard Arguments.isFolder(folder), Arguments.isReadable(folder) else {
            if args.flags.contains("--json") {
                emit(["folder": folder.path, "readable": false, "seconds": 0, "files": [String: Int](),
                      "pdf_pages": 0, "audio_seconds": 0, "video_seconds": 0])
            } else {
                print("\(tilde(folder.path))    can't read it (not there, or not allowed in macOS privacy settings)")
            }
            continue
        }
        let started = Date()
        let crawl = Crawler.crawl([folder], options: options)
        let parts = Estimator.estimates(bySubfolder: crawl.candidates, of: folder.path, options: options,
                                        reader: AppleMedia())
        let estimate = parts.values.reduce(Estimate(), +)
        // Biggest first; the app lists them under the folder, so that a long first pass can be cut down.
        let subfolders = parts.filter { $0.key != folder.path }.sorted {
            $0.value.seconds != $1.value.seconds ? $0.value.seconds > $1.value.seconds : $0.key < $1.key
        }
        total += estimate.seconds
        if args.flags.contains("--json") {
            func files(_ estimate: Estimate) -> [String: Int] {
                Dictionary(uniqueKeysWithValues: estimate.files.map { ($0.key.rawValue, $0.value) })
            }
            // One line per folder, as soon as it's done (the app's onboarding shows them as they come).
            emit(["folder": folder.path, "seconds": estimate.seconds, "readable": true, "files": files(estimate),
                  "pdf_pages": estimate.pdfPages, "pdf_pages_total": estimate.pdfPagesTotal,
                  "audio_seconds": estimate.audioSeconds, "video_seconds": estimate.videoSeconds,
                  "long_files": estimate.longFiles, "later_seconds": estimate.laterSeconds,
                  "subfolders": subfolders.prefix(500).map {
                      ["folder": $0.key, "seconds": $0.value.seconds, "files": files($0.value),
                       "long_files": $0.value.longFiles, "later_seconds": $0.value.laterSeconds] as [String: Any]
                  },
                  "skipped": crawl.skipped.values.reduce(0, +), "datasets": crawl.datasets.count,
                  "ms": Int(Date().timeIntervalSince(started) * 1000)])
            continue
        }
        var kinds: [String] = []
        for kind in FileKind.allCases {
            guard let count = estimate.files[kind], count > 0 else { continue }
            switch kind {
            case .pdf: kinds.append("\(number(count)) PDFs (\(number(estimate.pdfPagesTotal)) pages; \(number(estimate.pdfPages)) in the first pass)")
            case .audio: kinds.append("\(number(count)) audio (\(duration(estimate.audioSeconds)))")
            case .video: kinds.append("\(number(count)) video (\(duration(estimate.videoSeconds)))")
            default: kinds.append("\(number(count)) \(kind.rawValue)\(count == 1 ? "" : "s")")
            }
        }
        print("\(tilde(folder.path))    first index ≈ \(duration(estimate.seconds))")
        print("  " + (kinds.isEmpty ? "nothing to index" : kinds.joined(separator: " · ")))
        if estimate.longFiles > 0 {
            print("  then the rest of \(number(estimate.longFiles)) long \(estimate.longFiles == 1 ? "file" : "files") "
                  + "≈ \(duration(estimate.laterSeconds))")
        }
        if !subfolders.isEmpty {
            print("  biggest subfolders: " + subfolders.prefix(5).map {
                "\(($0.key as NSString).lastPathComponent) ≈ \(duration($0.value.seconds))"
            }.joined(separator: " · ") + (subfolders.count > 5 ? " · \(subfolders.count - 5) more" : ""))
        }
        if !crawl.skipped.isEmpty { print("  skipped: " + skippedLine(crawl.skipped)) }
        if !crawl.skippedFolders.isEmpty { print("  folders not walked: " + skippedLine(crawl.skippedFolders)) }
        for (folder, count) in crawl.datasets.sorted(by: { $0.value > $1.value }) {
            print("  looks like a dataset (skipped): \(tilde(folder)) (\(number(count)) files)")
        }
        print(String(format: "  (looked at it in %.2f s)", Date().timeIntervalSince(started)))
    }
    if args.positional.count > 1, !args.flags.contains("--json") { print("all together ≈ \(duration(total))") }
}

func index(_ args: Arguments) throws {
    let store = try args.store()
    if args.flags.contains("--reindex") { try store.resetAll() }
    let indexer = try Indexer(store: store, options: args.options, reader: AppleMedia(), makeEmbedder: {
        try makeEmbedder(textOnly: false, log: store.directory.appendingPathComponent("worker.log"))
    })
    indexer.embedderSource = embedderSource()
    try indexer.checkModel()
    let folders = try args.folders()
    let sync = try indexer.sync(folders)
    print("index: \(tilde(store.file.path))")
    print("sync: \(sync.added) new · \(sync.changed) changed · \(sync.moved) moved · \(sync.removed) removed · \(sync.unchanged) unchanged")
    if !sync.crawl.skipped.isEmpty { print("skipped: " + skippedLine(sync.crawl.skipped)) }
    for (folder, count) in sync.crawl.datasets { print("looks like a dataset (skipped): \(tilde(folder)) (\(number(count)) files)") }

    let limit = args.values["--limit"].flatMap(Int.init)
    var started = Date()
    let states = try indexer.run(limit: limit, onEvent: { event in
        let name = (event.path as NSString).lastPathComponent
        let note = event.note.map { "  (\($0))" } ?? ""
        print("[\(lpad("\(event.done)", 4))/\(event.total)] \(pad(event.kind.rawValue, 10)) \(pad(event.state, 7)) "
              + String(format: "%5.2fs  ", event.seconds) + name + note)
    })
    if states.isEmpty {
        print("nothing pending")
    } else {
        print("done in \(duration(Date().timeIntervalSince(started))): " + statesLine(states))
    }
    if try store.clusterPeople(force: true) { print("people: faces grouped again (digup people)") }
    // The rest of long files, as the app does once nothing is pending (not after a --limit run: things still are).
    guard limit == nil, try store.unfinishedCount().files > 0 else { return }
    started = Date()
    let finished = try indexer.finishLongFiles(onStep: { step in
        let name = (step.path as NSString).lastPathComponent
        let note = step.note.map { "  (\($0))" } ?? ""
        print("[rest \(lpad("\(step.done)", 5))/\(step.total)] \(pad(step.kind.rawValue, 4)) \(pad(step.state, 7)) "
              + String(format: "%5.2fs  ", step.seconds) + name + note)
    })
    print("the rest of long files in \(duration(Date().timeIntervalSince(started))): "
          + (finished.isEmpty ? "none finished" : statesLine(finished)))
}

func statesLine(_ states: [String: Int]) -> String {
    states.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: " · ")
}

/// Embeds queries with the text model alone (0.3B params, ~0.25 GB): the query encoder.
func queryVectors(_ queries: [String], store: IndexStore, searcher: Searcher) throws -> [[Float]]? {
    guard searcher.vectorCount > 0, !queries.isEmpty else { return nil }
    let worker = try makeEmbedder(textOnly: true, log: store.directory.appendingPathComponent("worker-query.log"))
    defer { worker.close() }
    if let source = searcher.vectorSource, source != worker.info.vectorSource {
        throw CLIError("index vectors come from \(source) but the query encoder is \(worker.info.vectorSource)")
    }
    return try worker.embedTexts(queries.map(Prompts.query))
}

func search(_ args: Arguments) throws {
    let query = args.positional.joined(separator: " ")
    guard !query.isEmpty else { throw CLIError("search for what?") }
    let store = try IndexStore(directory: args.indexFolder)
    let searcher = try Searcher(store: store)
    let started = Date()
    let parsed = Searcher.parse(query)
    let phrases = Searcher.embedPhrases(query)
    let vectors = try queryVectors(phrases, store: store, searcher: searcher)
    let encoded = Date()
    let hits = try searcher.search(query, queryVector: vectors?.first, kinds: try args.kinds(), people: try args.people(),
                                   limit: args.values["-n"].flatMap(Int.init) ?? 10, zGate: args.zGate, minLift: args.minLift,
                                   wordWeight: args.wordWeight,
                                   clauseVectors: parsed.hasOperators ? (vectors ?? []) : [])
    let searched = Date()
    if args.flags.contains("--json") {
        let rows: [[String: Any]] = hits.map { hit in
            var row: [String: Any] = ["path": hit.path, "kind": hit.kind.rawValue, "segment": hit.segment.rawValue,
                                      "score": hit.score]
            if let z = hit.z { row["z"] = z }
            if let cosine = hit.cosine { row["cosine"] = cosine }
            if let lift = hit.lift { row["lift"] = lift }
            row["meaning"] = hit.matchedMeaning
            if let rank = hit.keywordRank { row["keyword_rank"] = rank }
            if let loc = hit.loc { row["loc"] = loc }
            if let end = hit.locEnd { row["loc_end"] = end }
            if let excerpt = hit.excerpt { row["excerpt"] = excerpt }
            return row
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        print(String(data: data, encoding: .utf8) ?? "[]")
        return
    }
    if hits.isEmpty { print("no good matches") }
    for (rank, hit) in hits.enumerated() {
        let why = [hit.z.map { String(format: "z %.1f", $0) }, hit.keywordRank.map { "words #\($0)" }]
            .compactMap { $0 }.joined(separator: ", ")
        let place = location(hit)
        print("\(lpad("\(rank + 1)", 2)). \(pad(hit.kind.rawValue, 10)) \((hit.path as NSString).lastPathComponent)"
              + (place.isEmpty ? "" : "  [\(place)]") + "   (\(why))")
        print("      \(tilde((hit.path as NSString).deletingLastPathComponent))")
        if let excerpt = hit.excerpt, !excerpt.isEmpty { print("      “\(excerpt.prefix(160))”") }
    }
    print(String(format: "(%d vectors · query encoder %.2f s incl. start-up · search %.0f ms)", searcher.vectorCount,
                 encoded.timeIntervalSince(started), searched.timeIntervalSince(encoded) * 1000))
}

func people(_ args: Arguments) throws {
    let store = try IndexStore(directory: args.indexFolder)
    if let rename = args.values["--rename"] {
        let parts = rename.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = Int64(parts[0]) else {
            throw CLIError("--rename needs ID=Name, e.g. --rename 3=Anna")
        }
        try store.renamePerson(id, to: parts[1])
        print("renamed person \(id) to “\(parts[1])”")
        return
    }
    if args.flags.contains("--regroup") {
        try store.regroupPeople()
    }
    let people = try store.people()
    if people.isEmpty {
        print("no people yet (index photos with faces first)")
        return
    }
    for person in people {
        print("\(lpad("\(person.id)", 4))  \(pad(person.displayName, 24))  "
              + "\(person.photoCount) photos · \(person.faceCount) faces")
    }
}

func status(_ args: Arguments) throws {
    let store = try args.store()
    let counts = try store.counts()
    print("index: \(tilde(store.file.path))")
    print("vectors: \(number(counts.vectors)) in \(number(counts.segments)) segments")
    for kind in FileKind.allCases {
        guard let states = counts.byKindAndState[kind.rawValue] else { continue }
        let total = states.values.reduce(0, +)
        print("  \(pad(kind.rawValue, 11)) \(lpad(number(total), 6))   " + statesLine(states))
    }
    if counts.unfinished > 0 {
        print("long files still being read: \(number(counts.unfinished)) (\(number(counts.left)) pages and chunks left)")
    }
    if let fingerprint = try store.meta("fingerprint") { print("built with: \(fingerprint)") }
    print("this digup: llama.cpp \(LlamaEmbedder.buildTag), vectors \(LlamaEmbedder.vectorVersion)")
    print("size: \(ByteCountFormatter.string(fromByteCount: IndexStore.size(of: store.file), countStyle: .file))")
}

/// The app's indexing helper: sync + index on request, JSON events out (IndexService.swift).
func indexService(_ args: Arguments) throws -> Int32 {
    let model = SharedEmbedder {
        try makeEmbedder(textOnly: false, log: args.indexFolder.appendingPathComponent("worker.log"), qos: .utility)
    }
    let store = try IndexStore(directory: args.indexFolder)
    let indexer = try Indexer(store: store, options: args.options, reader: AppleMedia(),
                              makeEmbedder: { try model.embedder() })
    // A new app version may bring a new model: the index starts over by itself (keyword search on names goes on).
    indexer.embedderSource = embedderSource()
    indexer.resetOnModelChange = { indexed, now, reuseEmbeddings in
        emit(["event": "reindex", "from": indexed, "to": now, "reuse": reuseEmbeddings])
    }
    let roots = args.positional.map(Arguments.folderURL)
    // A chosen folder that isn't there now (an unplugged drive) is skipped, not an error, and its files stay
    // indexed. With --prune, files under none of the given folders leave the index (the app passes all its folders).
    let service = IndexService(main: IndexService.Part(store: store, indexer: indexer, roots: roots,
                                                       keepOnly: args.flags.contains("--prune") ? roots : nil),
                               model: model,
                               modelReady: { embedderSource() == nil || LlamaModels.complete },
                               backfill: args.flags.contains("--backfill"),
                               newFilesLimit: args.values["--new-limit"].flatMap(Int.init) ?? 50,
                               linger: args.values["--linger"].flatMap(Double.init) ?? 60)
    return service.serve()
}

// MARK: Eval

struct EvalFile: Decodable {
    struct Query: Decodable {
        let q: String
        let expect: [String]   // paths relative to `base`; "path@6-12" also requires the hit to start in [6, 12) s
        let tag: String?
        let kind: String?
    }
    let base: String
    let queries: [Query]
}

func evaluate(_ args: Arguments) throws {
    guard let file = args.positional.first else { throw CLIError("which eval file?") }
    let eval = try JSONDecoder().decode(EvalFile.self, from: Data(contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath)))
    let base = (eval.base as NSString).expandingTildeInPath
    let store = try IndexStore(directory: args.indexFolder)
    let searcher = try Searcher(store: store)
    let vectors = try queryVectors(eval.queries.map(\.q), store: store, searcher: searcher) ?? []
    let depth = args.values["-n"].flatMap(Int.init) ?? 10

    var byTag: [String: (n: Int, at1: Int, at5: Int, at10: Int, mrr: Double)] = [:]
    var shown = 0, listed = 0, folded = 0   // the app's weaker-matches fold (Searcher.strongCount), over all queries
    for (index, query) in eval.queries.enumerated() {
        let kinds = query.kind.flatMap { FileKind(rawValue: $0) }.map { Set([$0]) }
        let hits = try searcher.search(query.q, queryVector: index < vectors.count ? vectors[index] : nil, kinds: kinds,
                                       limit: depth, zGate: args.zGate, minLift: args.minLift, wordWeight: args.wordWeight)
        let strong = Searcher.strongCount(hits)
        shown += strong
        listed += hits.count
        let targets: [(path: String, range: ClosedRange<Double>?)] = query.expect.map { entry in
            let parts = entry.split(separator: "@", maxSplits: 1)
            let range = parts.count == 2 ? parts[1].split(separator: "-").compactMap { Double($0) } : []
            return (base + "/" + parts[0], range.count == 2 ? range[0]...range[1] : nil)
        }
        // A place to be at: a page or moment starts in the range.
        func at(_ hit: SearchHit, _ range: ClosedRange<Double>) -> Bool {
            guard let loc = hit.loc else { return false }
            return range.contains(loc)
        }
        let rank = hits.firstIndex { hit in
            targets.contains { target in
                hit.path == target.path && (target.range.map { at(hit, $0) } ?? true)
            }
        }.map { $0 + 1 }
        if let rank, rank > strong { folded += 1 }
        let tag = query.tag ?? "all"
        for key in Set([tag, "ALL"]) {
            var row = byTag[key] ?? (0, 0, 0, 0, 0)
            row.n += 1
            if let rank {
                if rank <= 1 { row.at1 += 1 }
                if rank <= 5 { row.at5 += 1 }
                if rank <= 10 { row.at10 += 1 }
                row.mrr += 1 / Double(rank)
            }
            byTag[key] = row
        }
        let top = hits.first.map { "\(($0.path as NSString).lastPathComponent)" + (location($0).isEmpty ? "" : " [\(location($0))]") } ?? "-"
        print("\(rank.map { lpad("#\($0)", 4) } ?? "miss")  \(pad(tag, 11)) \(pad("“\(query.q)”", 42)) top: \(top)")
    }
    print("")
    print("\(pad("tag", 12)) \(lpad("n", 3))  \(lpad("R@1", 5))  \(lpad("R@5", 5))  \(lpad("R@10", 5))  \(lpad("MRR", 5))")
    for (tag, row) in byTag.sorted(by: { ($0.key == "ALL" ? "~" : $0.key) < ($1.key == "ALL" ? "~" : $1.key) }) {
        let n = Double(row.n)
        print("\(pad(tag, 12)) \(lpad("\(row.n)", 3))  " + String(format: "%5.2f  %5.2f  %5.2f  %5.2f",
              Double(row.at1) / n, Double(row.at5) / n, Double(row.at10) / n, row.mrr / n))
    }
    let count = Double(max(1, eval.queries.count))
    print(String(format: "weaker-matches fold (Searcher.strongCount): %.1f of %.1f results shown per query; ",
                 Double(shown) / count, Double(listed) / count)
          + "\(folded) expected \(folded == 1 ? "answer" : "answers") folded")
}

// MARK: Main

do {
    let raw = CommandLine.arguments.dropFirst()
    guard let command = raw.first, command != "-h", command != "--help", command != "help" else {
        print(usage)
        exit(0)
    }
    let args = try Arguments(raw.dropFirst())
    switch command {
    case "estimate": try estimate(args)
    case "index": try index(args)
    case "search": try search(args)
    case "people": try people(args)
    case "status": try status(args)
    case "eval": try evaluate(args)
    case "index-service": exit(try indexService(args))
    case "worker": exit(workerService(args))
    case "mcp": exit(mcpServer(args))
    default:
        print(usage)
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
