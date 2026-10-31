import DigUpCore
import Foundation
import LlamaRuntime
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `digup serve`: DigUp in the browser, for where there's no menubar app (Linux, Windows; it runs on macOS too). A
/// page on 127.0.0.1 to search, browse people and their photos, and choose the folders; indexing runs in this process,
/// in the background, and syncs the folders every few minutes. The model is downloaded from the page when it's missing.
///
/// Only this computer's browser gets in: the server listens on the loopback interface, answers only requests for
/// its own host name (no DNS rebinding), and every /api call needs the session cookie the page set, which is
/// SameSite=Strict, so other sites' pages can't use it. Files are served only when they're in the index.
func serve(_ args: Arguments) throws -> Int32 {
    let app = try WebApp(index: args.indexFolder, options: args.options,
                         extraFolders: args.positional.map(Arguments.folderURL))
    let port = UInt16(args.values["--port"] ?? "") ?? 7811
    let server: HTTPServer
    do {
        server = try HTTPServer(port: port) { app.handle($0) }
    } catch {
        // Started again (from the app menu, say) while one is running: show that one.
        guard DigUpServer.isRunning(port: port) else { throw error }
        print("DigUp is already at http://127.0.0.1:\(port)/")
        if args.flags.contains("--open") { Opener.open("http://127.0.0.1:\(port)/") }
        return 0
    }
    app.port = server.port
    let address = "http://127.0.0.1:\(server.port)/"
    print("DigUp is at \(address)  (Ctrl-C stops it)")
    fflush(nil)   // every stream: Glibc's stdout is a mutable global
    app.startIndexing()
    if args.flags.contains("--open") { Opener.open(address) }
    server.run()
}

enum DigUpServer {
    /// Whether what answers on `port` is `digup serve`.
    static func isRunning(port: UInt16) -> Bool {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var page = ""
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { data, _, _ in
            page = String(decoding: data ?? Data(), as: UTF8.self)
            done.signal()
        }.resume()
        done.wait()
        return page.contains("<title>DigUp</title>")
    }
}

/// Folders and other choices made in the page, in `serve.json` in the index folder.
struct ServeSettings: Codable {
    var folders: [String] = []
    var photosAndVideoOnly = false

    static func load(from file: URL) -> ServeSettings {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(ServeSettings.self, from: $0) } ?? ServeSettings()
    }

    func save(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
    }
}

final class WebApp: @unchecked Sendable {
    let index: URL
    var port: UInt16 = 0
    private let baseOptions: IndexOptions
    private let token = (0..<4).map { _ in String(UInt64.random(in: .min ... .max), radix: 36) }.joined()
    private let thumbnails: URL
    private let settingsFile: URL
    private let thumbnailSlots = DispatchSemaphore(value: 3)
    private let fetch = ModelFetch()

    private let lock = NSLock()
    private var settings: ServeSettings
    private var searchStore: IndexStore?
    private var searcher: Searcher?
    private var searcherGeneration = -1
    private var generation = 0   // bumped when indexing changed what a search would find
    private var encoder: (any Embedder)?
    private let storeLock = NSLock()   // searchStore, searcher and encoder

    // Indexing, on a thread of its own.
    private var indexing = IndexingState()
    private var syncRequested = true
    private let wake = DispatchSemaphore(value: 0)
    static let rescanInterval: Double = 600

    struct IndexingState {
        var phase = "starting"
        var file: String?
        var done = 0
        var total = 0
        var lastSync: Date?
        var error: String?
        var missing: [String] = []
    }

    init(index: URL, options: IndexOptions, extraFolders: [URL]) throws {
        self.index = index
        baseOptions = options
        thumbnails = index.appendingPathComponent("Thumbnails")
        settingsFile = index.appendingPathComponent("serve.json")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        settings = ServeSettings.load(from: settingsFile)
        let added = extraFolders.map { FolderSelection.realPath($0.path) }.filter { !settings.folders.contains($0) }
        if !added.isEmpty {
            settings.folders += added
            try settings.save(to: settingsFile)
        }
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
    }

    // MARK: Routing

    func handle(_ request: HTTPServer.Request) -> HTTPServer.Response {
        let host = request.header("host") ?? ""
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
            return .text("DigUp answers only at http://127.0.0.1:\(port)/", status: 403)
        }
        if request.path == "/" || request.path == "/index.html" {
            var response = HTTPServer.Response.text(WebPage.html, status: 200, type: "text/html; charset=utf-8")
            response.headers["Set-Cookie"] = "digup=\(token); Path=/; HttpOnly; SameSite=Strict"
            response.headers["Cache-Control"] = "no-store"
            response.headers["Content-Security-Policy"] =
                "default-src 'self'; img-src 'self' blob:; media-src 'self'; style-src 'self' 'unsafe-inline'; "
                + "script-src 'self' 'unsafe-inline'; frame-ancestors 'none'"
            return response
        }
        guard request.path.hasPrefix("/api/") else { return .error(404, "nothing here") }
        guard cookie(request) == token else { return .error(403, "reload the page") }
        if request.method == "POST" {
            // Another site's page can't send JSON here without asking first (CORS), and isn't let in when it says
            // where it's from.
            let origin = request.header("origin")
            guard request.header("content-type")?.hasPrefix("application/json") == true,
                  origin == nil || origin == "http://\(host)" else { return .error(403, "not from this page") }
        } else if request.method != "GET" && request.method != "HEAD" {
            return .error(405, "GET or POST")
        }
        do {
            return try route(request)
        } catch let error as CLIError {
            return .error(400, error.description)
        } catch {
            return .error(500, "\(error)")
        }
    }

    private func cookie(_ request: HTTPServer.Request) -> String? {
        for part in (request.header("cookie") ?? "").split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0] == "digup" { return pair[1] }
        }
        return nil
    }

    private func route(_ request: HTTPServer.Request) throws -> HTTPServer.Response {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        switch (request.method == "HEAD" ? "GET" : request.method, request.path) {
        case ("GET", "/api/status"): return .json(status())
        case ("GET", "/api/search"): return .json(try search(request))
        case ("GET", "/api/photos"): return .json(try photos(request))
        case ("GET", "/api/people"): return .json(try people())
        case ("POST", "/api/people/rename"):
            guard let id = (body["id"] as? NSNumber)?.int64Value else { throw CLIError("which person?") }
            let name = (body["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            try withSearchStore { try $0.renamePerson(id, to: name?.isEmpty == false ? name : nil) }
            return .json(["ok": true])
        case ("POST", "/api/people/merge"):
            guard let keeper = (body["keeper"] as? NSNumber)?.int64Value,
                  let other = (body["other"] as? NSNumber)?.int64Value, keeper != other else {
                throw CLIError("merge needs two people")
            }
            try withSearchStore { try $0.mergePeople(keeper: keeper, other: other) }
            return .json(["ok": true])
        case ("GET", "/api/thumb"): return try thumbnail(request)
        case ("GET", "/api/file"): return try file(request)
        case ("GET", "/api/text"):
            guard let id = request.value("segment").flatMap(Int64.init) else { throw CLIError("which segment?") }
            let text = try withSearcher { try $0.text(ofSegment: id) }
            return .json(["text": text.map { $0 as Any } ?? NSNull()])
        case ("POST", "/api/open"):
            guard let path = body["path"] as? String, try indexed(path) != nil else { throw CLIError("not in the index") }
            body["reveal"] as? Bool == true ? Opener.reveal(path) : Opener.open(path)
            return .json(["ok": true])
        case ("GET", "/api/folders"): return .json(folders())
        case ("POST", "/api/folders"): return .json(try setFolders(body))
        case ("GET", "/api/browse"): return .json(try browse(request.value("path")))
        case ("POST", "/api/sync"):
            requestSync()
            return .json(["ok": true])
        case ("POST", "/api/model/download"):
            fetch.start { [self] in requestSync() }
            return .json(["ok": true])
        default:
            return .error(404, "no \(request.method) \(request.path)")
        }
    }

    // MARK: Status

    private func status() -> [String: Any] {
        let state = lock.withLock { indexing }
        var out: [String: Any] = [
            "phase": state.phase, "done": state.done, "total": state.total, "missing": state.missing,
            "file": state.file.map { ($0 as NSString).lastPathComponent } ?? NSNull(),
            "lastSync": state.lastSync.map { $0.timeIntervalSince1970 } ?? NSNull(),
            "error": state.error ?? NSNull(),
            "index": index.path,
        ]
        let progress = fetch.progress
        out["model"] = ["ready": LlamaModels.complete && ModelFetch.missing.isEmpty, "downloading": progress.running, "done": progress.done,
                        "total": progress.total, "error": progress.error ?? NSNull(), "folder": ModelFiles.installed.path]
        if let counts = try? withSearchStore({ try $0.counts() }) {
            var files: [String: Int] = [:]
            var pending = 0
            for (kind, states) in counts.byKindAndState {
                files[kind] = states.values.reduce(0, +)
                pending += states["pending"] ?? 0
            }
            out["files"] = files
            out["pending"] = pending
            out["vectors"] = counts.vectors
            out["unfinished"] = counts.unfinished
        }
        return out
    }

    // MARK: Search

    private func search(_ request: HTTPServer.Request) throws -> [String: Any] {
        var query = (request.value("q") ?? "").trimmingCharacters(in: .whitespaces)
        var dates = try span(request.value("when"))
        if dates == nil, let typed = DateSpan.parse(query) {
            dates = typed.span
            query = typed.rest
        }
        let kinds = try self.kinds(request.values("kind"))
        let people = try self.people(request.values("person"))
        let limit = min(max(Int(request.value("limit") ?? "") ?? 60, 1), 500)
        return try withSearcher { searcher in
            guard !query.isEmpty else {
                guard dates != nil || people != nil else { return ["results": [Any]()] }
                return ["query": "", "when": dates?.title ?? NSNull(),
                        "results": try searcher.photos(of: people ?? [], in: dates, kinds: kinds, limit: limit)
                            .map { row($0, strong: true) }]
            }
            let parsed = Searcher.parse(query)
            let vectors = try encode(Searcher.embedPhrases(query), searcher: searcher)
            let hits = try searcher.search(query, queryVector: vectors?.first, kinds: kinds, people: people, dates: dates,
                                           limit: limit, clauseVectors: parsed.hasOperators ? (vectors ?? []) : [])
            let strong = Searcher.strongCount(hits)
            return ["query": query, "when": dates?.title ?? NSNull(), "meaning": vectors != nil,
                    "results": hits.enumerated().map { row($1, strong: $0 < strong) }]
        }
    }

    private func photos(_ request: HTTPServer.Request) throws -> [String: Any] {
        let dates = try span(request.value("when"))
        let people = try self.people(request.values("person")) ?? []
        let limit = min(max(Int(request.value("limit") ?? "") ?? 500, 1), 5000)
        return try withSearcher { searcher in
            ["results": try searcher.photos(of: people, in: dates, kinds: try kinds(request.values("kind")), limit: limit)
                .map { row($0, strong: true) }]
        }
    }

    private func row(_ hit: SearchHit, strong: Bool) -> [String: Any] {
        var out: [String: Any] = ["path": hit.path, "name": (hit.path as NSString).lastPathComponent,
                                  "folder": tilde((hit.path as NSString).deletingLastPathComponent),
                                  "kind": hit.kind.rawValue, "segment": hit.segment.rawValue, "segmentID": hit.segmentID,
                                  "strong": strong, "modified": hit.modified, "size": hit.size]
        if let taken = hit.info["taken"] { out["taken"] = taken }
        if let lat = hit.info["lat"], let lon = hit.info["lon"] { out["place"] = "\(lat),\(lon)" }
        if hit.z != nil || hit.keywordRank != nil {
            out["matched"] = hit.matchedMeaning ? "meaning" : (hit.keywordRank != nil ? "words" : "name")
        }
        if let loc = hit.loc { out["loc"] = loc }
        if let end = hit.locEnd { out["locEnd"] = end }
        if let excerpt = hit.excerpt { out["excerpt"] = excerpt }
        return out
    }

    /// The query encoder (the text model alone), started on the first search and kept.
    private func encode(_ phrases: [String], searcher: Searcher) throws -> [[Float]]? {
        guard searcher.vectorCount > 0, !phrases.isEmpty, LlamaModels.complete || embedderSource() == nil else {
            return nil
        }
        if encoder == nil {
            encoder = try makeEmbedder(textOnly: true, log: index.appendingPathComponent("worker-serve.log"))
        }
        guard let encoder else { return nil }
        if let source = searcher.vectorSource, source != encoder.info.vectorSource {
            throw CLIError("the index's vectors come from \(source) but the query encoder is \(encoder.info.vectorSource)")
        }
        return try encoder.embedTexts(phrases.map(Prompts.query))
    }

    private func span(_ text: String?) throws -> DateSpan? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        guard let parsed = DateSpan.parse(text), parsed.rest.isEmpty else {
            throw CLIError("can't read the time “\(text)”: try “2023”, “july 2023”, “2019-2021” or “last year”")
        }
        return parsed.span
    }

    private func kinds(_ names: [String]) throws -> Set<FileKind>? {
        let names = names.flatMap { $0.split(separator: ",").map(String.init) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        return Set(try names.map { name in
            guard let kind = FileKind(rawValue: name) else { throw CLIError("no kind “\(name)”") }
            return kind
        })
    }

    private func people(_ ids: [String]) throws -> Set<Int64>? {
        let ids = ids.flatMap { $0.split(separator: ",") }.compactMap { Int64($0) }
        return ids.isEmpty ? nil : Set(ids)
    }

    // MARK: People

    private func people() throws -> [String: Any] {
        try withSearchStore { store in
            ["people": try store.people().map { person -> [String: Any] in
                var out: [String: Any] = ["id": person.id, "name": person.name ?? NSNull(),
                                          "displayName": person.displayName, "photos": person.photoCount,
                                          "faces": person.faceCount]
                if let face = try store.exemplarFace(ofPerson: person.id) {
                    out["face"] = ["path": face.path,   // Double: Linux's JSONSerialization takes no CGFloat
                                   "box": [face.box.minX, face.box.minY, face.box.width, face.box.height].map(Double.init)]
                }
                return out
            }]
        }
    }

    // MARK: Files

    private func indexed(_ path: String) throws -> FileRecord? {
        try withSearchStore { try $0.file(atPath: path) }
    }

    private func thumbnail(_ request: HTTPServer.Request) throws -> HTTPServer.Response {
        guard let path = request.value("path"), let record = try indexed(path) else {
            return .error(404, "not in the index")
        }
        let loc = request.value("loc").flatMap(Double.init)
        let size = min(max(Int(request.value("size") ?? "") ?? 360, 64), 2048)
        let key = "\(path)\u{0}\(record.mtime)\u{0}\(loc ?? -1)\u{0}\(size)"
        let file = thumbnails.appendingPathComponent(String(fnv1a(key), radix: 16) + ".jpg")
        if !FileManager.default.fileExists(atPath: file.path) {
            thumbnailSlots.wait()
            defer { thumbnailSlots.signal() }
            if !FileManager.default.fileExists(atPath: file.path) {
                let scratch = thumbnails.appendingPathComponent(UUID().uuidString + ".jpg")
                defer { try? FileManager.default.removeItem(at: scratch) }
                try mediaReader.thumbnail(of: URL(fileURLWithPath: path), kind: record.kind, at: loc, maxPixel: size,
                                          to: scratch)
                try? FileManager.default.moveItem(at: scratch, to: file)
            }
        }
        return HTTPServer.Response(status: 200, headers: ["Content-Type": "image/jpeg",
                                                          "Cache-Control": "private, max-age=86400"],
                                   body: .file(file, nil))
    }

    private func file(_ request: HTTPServer.Request) throws -> HTTPServer.Response {
        guard let path = request.value("path"), try indexed(path) != nil,
              FileManager.default.fileExists(atPath: path) else { return .error(404, "not in the index") }
        let url = URL(fileURLWithPath: path)
        var response = HTTPServer.Response(status: 200, headers: ["Content-Type": Self.mediaType(url.pathExtension),
                                                                  "Cache-Control": "private, max-age=60"],
                                           body: .file(url, nil))
        if let range = request.header("range"), range.hasPrefix("bytes=") {
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value ?? 0
            if bounds.count == 2, size > 0 {
                let start = UInt64(bounds[0]) ?? (UInt64(bounds[1]).map { size - min(size, $0) } ?? 0)
                let end = bounds[0].isEmpty ? size : (UInt64(bounds[1]).map { $0 + 1 } ?? size)
                guard start < size, start < end else {
                    return HTTPServer.Response(status: 416, headers: ["Content-Range": "bytes */\(size)"])
                }
                response.status = 206
                response.body = .file(url, start..<min(end, size))
            }
        }
        return response
    }

    static func mediaType(_ ext: String) -> String {
        [
            "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp",
            "avif": "image/avif", "heic": "image/heic", "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff",
            "pdf": "application/pdf", "mp4": "video/mp4", "m4v": "video/mp4", "mov": "video/quicktime",
            "webm": "video/webm", "mkv": "video/x-matroska", "mp3": "audio/mpeg", "m4a": "audio/mp4", "wav": "audio/wav",
            "ogg": "audio/ogg", "opus": "audio/ogg", "flac": "audio/flac", "aac": "audio/aac",
            "txt": "text/plain; charset=utf-8", "md": "text/plain; charset=utf-8",
        ][ext.lowercased()] ?? "application/octet-stream"
    }

    // MARK: Folders

    private func folders() -> [String: Any] {
        let settings = lock.withLock { self.settings }
        return ["folders": settings.folders.map { path -> [String: Any] in
            ["path": path, "display": tilde(path), "there": Arguments.isFolder(URL(fileURLWithPath: path))]
        }, "photosAndVideoOnly": settings.photosAndVideoOnly, "home": home]
    }

    private func setFolders(_ body: [String: Any]) throws -> [String: Any] {
        guard let paths = body["folders"] as? [String] else { throw CLIError("which folders?") }
        var folders: [String] = []
        for path in paths {
            // As a walk of the folder writes paths (on macOS /tmp is /private/tmp).
            let url = URL(fileURLWithPath: FolderSelection.realPath(Arguments.folderURL(path).path))
            guard Arguments.isFolder(url) else { throw CLIError("not a folder: \(path)") }
            if !folders.contains(url.path) { folders.append(url.path) }
        }
        let removed = lock.withLock { () -> [String] in
            let removed = settings.folders.filter { !folders.contains($0) }
            settings.folders = folders
            if let only = body["photosAndVideoOnly"] as? Bool { settings.photosAndVideoOnly = only }
            return removed
        }
        try lock.withLock { settings }.save(to: settingsFile)
        // What was found only in folders taken out of the list leaves the index.
        if !removed.isEmpty {
            try withSearchStore { store in
                let gone = try store.files(under: removed).filter { file in
                    !folders.contains { FolderSelection.isInside(file.path, $0) }
                }
                try store.db.transaction { for file in gone { try store.delete(file.id) } }
            }
            changed()
        }
        requestSync()
        return self.folders()
    }

    /// The folders in `path` (home when nil), for choosing what to index.
    private func browse(_ path: String?) throws -> [String: Any] {
        let url = Arguments.folderURL(path ?? home)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        let folders = names.filter { !$0.hasPrefix(".") && Arguments.isFolder(url.appendingPathComponent($0)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        return ["path": url.path, "display": tilde(url.path), "parent": parent == url.path ? NSNull() : parent,
                "folders": folders]
    }

    // MARK: Index access

    /// The index as searches see it: one connection, used by one request at a time.
    private func withSearchStore<T>(_ body: (IndexStore) throws -> T) throws -> T {
        try storeLock.withLock {
            if searchStore == nil { searchStore = try IndexStore(directory: index) }
            return try body(searchStore!)
        }
    }

    /// The searcher, its vectors read again when indexing found something since.
    private func withSearcher<T>(_ body: (Searcher) throws -> T) throws -> T {
        let current = lock.withLock { generation }
        return try withSearchStore { store in
            if searcher == nil {
                searcher = try Searcher(store: store)
            } else if searcherGeneration != current {
                try searcher!.reload()
            }
            searcherGeneration = current
            return try body(searcher!)
        }
    }

    // MARK: Indexing

    func requestSync() {
        lock.withLock { syncRequested = true }
        wake.signal()
    }

    func startIndexing() {
        Thread.detachNewThread { [self] in indexLoop() }
    }

    private func setPhase(_ phase: String, file: String? = nil, done: Int = 0, total: Int = 0) {
        lock.withLock {
            indexing.phase = phase
            indexing.file = file
            indexing.done = done
            indexing.total = total
        }
    }

    private func changed() {
        lock.withLock { generation += 1 }
    }

    private func indexLoop() {
        while true {
            lock.withLock { syncRequested = false }
            let settings = lock.withLock { self.settings }
            do {
                try indexOnce(settings)
                lock.withLock { indexing.error = nil }
            } catch {
                lock.withLock { indexing.error = "\(error)" }
            }
            setPhase(settings.folders.isEmpty ? "no folders" : LlamaModels.complete ? "idle" : "waiting for the model")
            if lock.withLock({ syncRequested }) { continue }
            _ = wake.wait(timeout: .now() + Self.rescanInterval)
        }
    }

    private func indexOnce(_ settings: ServeSettings) throws {
        guard !settings.folders.isEmpty else { return }
        var options = baseOptions
        if settings.photosAndVideoOnly { options.kinds = FileKind.photosAndVideo }
        let store = try IndexStore(directory: index)
        let indexer = try Indexer(store: store, options: options, reader: mediaReader, makeEmbedder: { [index] in
            try makeEmbedder(textOnly: false, log: index.appendingPathComponent("worker.log"), qos: .utility)
        })
        indexer.embedderSource = embedderSource()
        defer { indexer.finish() }
        let roots = settings.folders.map { URL(fileURLWithPath: $0) }
        // Folders not there now (an unplugged drive) stay in the index. (Ones taken out of the list left it then, in
        // `setFolders`; anything else in the index is someone else's, the macOS app's say, and stays.)
        let available = roots.filter { Arguments.isFolder($0) && Arguments.isReadable($0) }
        lock.withLock { indexing.missing = roots.filter { !available.contains($0) }.map(\.path) }
        store.scope = available.map(\.path)
        setPhase("syncing")
        let sync = try indexer.sync(available)
        lock.withLock { indexing.lastSync = Date() }
        if sync.added + sync.changed + sync.moved + sync.removed > 0 { changed() }
        guard LlamaModels.complete || embedderSource() == nil else { return }
        _ = try indexer.checkModel()
        let stop = { [self] in lock.withLock { syncRequested } }
        var lastChange = Date()
        func progress(_ done: Int, _ total: Int, _ path: String, phase: String) {
            setPhase(phase, file: path, done: done, total: total)
            // What's new shows up in searches a few files at a time, not only at the end.
            if Date().timeIntervalSince(lastChange) > 5 {
                changed()
                lastChange = Date()
            }
        }
        _ = try indexer.run(shouldStop: stop) { event in progress(event.done, event.total, event.path, phase: "indexing") }
        changed()
        if !stop(), try store.unfinishedCount().files > 0 {
            _ = try indexer.finishLongFiles(shouldStop: stop) { step in
                progress(step.done, step.total, step.path, phase: "reading long files")
            }
            changed()
        }
        if try store.clusterPeople(force: true) { changed() }
    }
}

/// FNV-1a: a hash that stays the same from run to run (thumbnail file names).
func fnv1a(_ text: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100_0000_01b3
    }
    return hash
}

/// Opens a file or address with what the system opens it with, or shows a file in its folder.
enum Opener {
    static func open(_ target: String) {
        #if os(macOS)
        run("/usr/bin/open", [target])
        #elseif os(Windows)
        run("C:\\Windows\\explorer.exe", [target])
        #else
        run("xdg-open", [target])
        #endif
    }

    static func reveal(_ path: String) {
        #if os(macOS)
        run("/usr/bin/open", ["-R", path])
        #elseif os(Windows)
        run("C:\\Windows\\explorer.exe", ["/select,", path])
        #else
        run("xdg-open", [(path as NSString).deletingLastPathComponent])
        #endif
    }

    private static func run(_ program: String, _ arguments: [String]) {
        let process = Process()
        if program.contains("/") || program.contains("\\") {
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [program] + arguments
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
