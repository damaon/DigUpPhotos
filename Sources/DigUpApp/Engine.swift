import DigUpKit
import Foundation

/// What the menubar shows about the index.
nonisolated struct EngineStatus: Sendable, Equatable {
    enum Activity: Sendable, Equatable {
        case starting
        case idle
        case syncing
        case indexing(done: Int, total: Int)
        /// The rest of long PDFs and documents (`Indexer.finishLongFiles`): `done` of the `total` pages and chunks this
        /// pass set out to read, `files` long files still unfinished.
        case finishing(done: Int, total: Int, files: Int)
        case failed(String)
    }

    /// The query encoder: a text-only worker process started when the panel opens.
    enum Encoder: Sendable, Equatable {
        case stopped
        case starting
        case ready
        case unavailable
    }

    var activity = Activity.starting
    var encoder = Encoder.stopped
    var files = 0        // in the index, any state
    var searchable = 0   // done or partial
    var pending = 0      // waiting to be embedded
    var unfinished = 0   // long files with pages or chunks still to read (the backfill's rules hold them up too)
    var vectors = 0
    var paused = false
    var waitingFor: String?   // why the backfill waits ("on battery"), if it does
    /// The helper found no model yet (it's downloading): files are found and named, nothing gets embedded.
    var waitingForModel = false
    /// Chosen folders that aren't there right now (an unplugged drive): skipped, and their files kept.
    var missingRoots: [String] = []
    /// Chosen folders macOS doesn't let DigUp read (Privacy & Security → Files and Folders): skipped, files kept.
    var unreadableRoots: [String] = []
}

/// The engine host: search, the query encoder, and the indexing helper, all off the main thread.
///
/// Indexing runs in a helper process (`Contents/Helpers/digup index-service`) that exits when it's done:
/// extraction is heavy (Vision OCR alone keeps ~100 MB of models in the process that ran it), and the app has to stay
/// small while idle. The app watches the folders and tells the helper when to sync, pause, or run the backfill.
///
/// Every engine object is confined to one serial queue:
/// - `indexQueue` (utility QoS) talks to the indexing helper.
/// - `searchQueue` (user-initiated) owns the `Searcher` and its read connection. SQLite's WAL mode lets it read while
///   the helper writes, so a search never waits for indexing.
/// - `encoderQueue` (user-initiated) owns the query encoder, a worker process whose cold start (~0.35 s) must never
///   hold up keyword results.
/// The main thread never waits on any of them: work goes in with `async`, results come back through async
/// functions and `onStatus`.
///
/// The folders can change while it runs (`setFolders`): the watcher follows, and the helper restarts with them.
nonisolated final class Engine: @unchecked Sendable {
    /// A query's vector and the model that made it (vectors from different models can't be compared).
    struct QueryVector: Sendable {
        let values: [Float]
        let source: String
        /// One vector per phrase when the query uses `and`, `or`, or `-`. Empty for a plain query, which stays one embedding.
        var clauses: [[Float]] = []
    }

    let indexDirectory: URL
    let modelsDirectory: URL
    let encoderIdleSeconds: Double
    private let indexQueue = DispatchQueue(label: "DigUp.index", qos: .utility)
    private let searchQueue = DispatchQueue(label: "DigUp.search", qos: .userInitiated)
    private let encoderQueue = DispatchQueue(label: "DigUp.encoder", qos: .userInitiated)

    private let watchQueue = DispatchQueue(label: "DigUp.watch", qos: .utility)

    // indexQueue only
    private var helper: Process?
    private var helperInput: FileHandle?
    private var helperStarted = Date()
    private var helperOutput = Data()
    /// The folders changed while a helper ran: start a new one with them when it's gone.
    private var restartHelper = false
    /// The next helper drops files under folders that are no longer chosen. At launch too, in case the folders
    /// changed while a helper had no time to; but an app with no folders at all never empties the index by itself.
    private var pruneWanted: Bool
    /// When a sync was last asked for that no helper has started yet; a helper that exits before doing it is
    /// restarted.
    private var syncWantedAt: Date?
    private var lastSearcherRefresh = Date.distantPast

    // watchQueue only
    private var watcher: FolderWatcher?
    private var syncDebounce: DispatchWorkItem?

    // Any thread, under `lock`
    private var photosAndVideoOnly: Bool
    private var paused = false
    private var backfillBlocker: String?
    private var roots: [URL]
    private var excluded: [URL]
    private var excludedTypes: [String]

    // searchQueue only
    private var searcher: Searcher?
    private var searchStore: IndexStore?
    private var warnedAboutSource = false

    // encoderQueue only
    private var encoder: EmbeddingWorker?
    private var encoderFailed = false
    private var encoderIdleExit: DispatchWorkItem?
    private var vectorCache = QueryVectorCache(limit: 256)

    // Any thread, under `lock`: the newest text typed, so an embed for an older keystroke is skipped.
    private var newestTyped: String?
    /// OpenRouter key. Rewriting also needs `queryUnderstanding`.
    private var openRouterAPIKey = ""
    /// The Settings switch. Off searches the words as typed, even when a key is saved.
    private var queryUnderstanding: Bool
    private var rewriteCache: [String: QueryReading] = [:]

    // Any thread, under `lock`
    private let lock = NSLock()
    private var status = EngineStatus()
    private var statusPostPending = false
    private let onStatus: @MainActor @Sendable (EngineStatus) -> Void

    /// `backfillBlocker`: why the first full pass has to wait (see `PowerPolicy`), or nil.
    init(settings: AppSettings, backfillBlocker: String?,
         onStatus: @escaping @MainActor @Sendable (EngineStatus) -> Void) {
        indexDirectory = settings.indexDirectory
        modelsDirectory = settings.modelsDirectory
        encoderIdleSeconds = settings.encoderIdleSeconds
        roots = settings.roots
        excluded = settings.excludedFolders
        excludedTypes = settings.excludedTypes
        photosAndVideoOnly = settings.photosAndVideoOnly
        queryUnderstanding = settings.queryUnderstanding
        pruneWanted = !settings.roots.isEmpty
        self.backfillBlocker = backfillBlocker
        self.onStatus = onStatus
        status.waitingFor = backfillBlocker
    }

    // MARK: Status

    /// Changes the status and tells the main thread, at most ~10 times a second however often it changes.
    private func update(_ change: (inout EngineStatus) -> Void) {
        let post = lock.withLock {
            change(&status)
            defer { statusPostPending = true }
            return !statusPostPending
        }
        guard post else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
            let latest = lock.withLock {
                statusPostPending = false
                return status
            }
            MainActor.assumeIsolated { onStatus(latest) }
        }
    }

    // MARK: Start

    /// Opens the searcher first (creating the index if it's new), so a search asked for right after launch already
    /// finds it on its queue; then starts the indexing helper, which syncs with the folders.
    func start() {
        searchQueue.async { [self] in
            guard openSearcher() else {
                update { $0.activity = .failed("Can't open the index") }
                return
            }
            indexQueue.async { [self] in startHelper() }
        }
        watchQueue.async { [self] in
            startWatching()
        }
    }

    var folders: (roots: [URL], excluded: [URL]) {
        lock.withLock { (roots, excluded) }
    }

    /// New folders or exclusions: the watcher follows, and the helper restarts with them once its current batch is
    /// done. Files under folders that are no longer chosen, or newly excluded, leave the index.
    func setFolders(roots: [URL], excluded: [URL], excludedTypes: [String], photosAndVideoOnly: Bool? = nil) {
        lock.withLock {
            self.roots = roots
            self.excluded = excluded
            self.excludedTypes = excludedTypes
            if let photosAndVideoOnly { self.photosAndVideoOnly = photosAndVideoOnly }
        }
        let mediaOnly = lock.withLock { self.photosAndVideoOnly }
        log("folders: \(roots.map { tildePath($0.path) })" + (excluded.isEmpty ? "" : " minus \(excluded.map { tildePath($0.path) })")
            + (excludedTypes.isEmpty ? "" : " · skipping .\(excludedTypes.joined(separator: ", ."))")
            + (mediaOnly ? " · photos & video only" : ""))
        update {
            $0.missingRoots = []
            $0.unreadableRoots = []
            if roots.isEmpty { $0.activity = .idle }
        }
        watchQueue.async { [self] in startWatching() }
        indexQueue.async { [self] in
            pruneWanted = true
            if helper != nil {
                restartHelper = true
                send("stop")
            } else {
                startHelper()
            }
        }
    }

    /// Photos & video only (on) or every file DigUp can read (off). Changing it restarts the helper so the index
    /// fingerprint updates and non-matching kinds leave.
    func setPhotosAndVideoOnly(_ on: Bool) {
        let changed = lock.withLock { () -> Bool in
            defer { photosAndVideoOnly = on }
            return photosAndVideoOnly != on
        }
        guard changed else { return }
        log(on ? "indexing photos and video only" : "indexing all DigUp file kinds")
        indexQueue.async { [self] in
            pruneWanted = true
            if helper != nil {
                restartHelper = true
                send("stop")
            } else {
                startHelper()
            }
        }
    }

    /// The model has finished downloading: index what's waiting, and meaning search may start.
    func modelArrived() {
        update { $0.waitingForModel = false }
        encoderQueue.async { [self] in encoderFailed = false }
        indexQueue.async { [self] in requestSync() }
    }

    /// A drive was connected or ejected: a missing folder may be back (or gone).
    func volumesChanged() {
        watchQueue.async { [self] in
            startWatching()
        }
        indexQueue.async { [self] in
            requestSync()
        }
    }

    private func openSearcher() -> Bool {
        let started = Date()
        do {
            // Keyword search only until the panel opens: the vectors load then, and leave with the query encoder.
            let store = try IndexStore(directory: indexDirectory)
            let searcher = try Searcher(store: store, loadVectors: false)
            self.searcher = searcher
            searchStore = store
            if let counts = try? store.counts() { apply(counts) }
            log("engine: searcher ready in \(ms(since: started))")
            returnFreedMemory()
            return true
        } catch {
            log("can't open the index at \(indexDirectory.path): \(error)")
            return false
        }
    }

    private func apply(_ counts: IndexStore.Counts) {
        var files = 0, searchable = 0, pending = 0
        for states in counts.byKindAndState.values {
            for (state, count) in states {
                files += count
                if state == "done" || state == "partial" { searchable += count }
                if state == "pending" { pending += count }
            }
        }
        update {
            $0.files = files
            $0.searchable = searchable
            $0.pending = pending
            $0.vectors = counts.vectors
            $0.unfinished = counts.unfinished
        }
    }

    // MARK: Indexing (in the helper process)

    /// Watches the chosen folders that are there (a missing one is picked up when a drive connects).
    private func startWatching() {
        watcher = nil
        let present = lock.withLock { roots }.filter(AppSettings.isFolder)
        guard !present.isEmpty else { return }
        watcher = FolderWatcher(paths: present.map(\.path), latency: 0.25, queue: watchQueue) { [weak self] paths in
            self?.foldersChanged(paths)
        }
        log(watcher == nil ? "watch: can't watch the folders" : "watch: \(present.count) folders")
    }

    /// FSEvents, on watchQueue. Waits for things to settle (a copy in progress, a burst of screenshots), then asks
    /// the helper to sync; a running batch yields to that at its next boundary.
    private func foldersChanged(_ paths: [String]) {
        log("watch: \(paths.count) changed (\((paths.first as NSString?)?.lastPathComponent ?? ""))")
        syncDebounce?.cancel()
        let work = DispatchWorkItem { [self] in
            indexQueue.async { [self] in requestSync() }
        }
        syncDebounce = work
        watchQueue.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func requestSync() {
        syncWantedAt = Date()
        if helper != nil { send("sync") } else { startHelper() }
    }

    /// Starts `digup index-service` unless one is running (or indexing is paused). It syncs first, indexes up to
    /// 50 new files on any power source, then the backfill if the power policy allows; it exits a minute after
    /// its last file. Before the model has downloaded it only syncs (file names become searchable) and exits.
    private func startHelper() {
        let (roots, excluded, types, mediaOnly, paused, backfill): ([URL], [URL], [String], Bool, Bool, Bool) =
            lock.withLock {
                (self.roots, self.excluded, self.excludedTypes, self.photosAndVideoOnly, self.paused,
                 backfillBlocker == nil)
            }
        guard helper == nil, !paused else { return }
        guard !roots.isEmpty || pruneWanted else {
            update { $0.activity = .idle }
            return
        }
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/digup")
        var arguments = ["index-service", "--index", indexDirectory.path]
        if backfill { arguments.append("--backfill") }
        if pruneWanted { arguments.append("--prune") }
        if mediaOnly { arguments.append("--photos-video") }
        for folder in excluded { arguments += ["--exclude", folder.path] }
        for type in types { arguments += ["--exclude-ext", type] }
        process.arguments = arguments + roots.map(\.path)
        process.environment = ProcessInfo.processInfo.environment.merging(["DIGUP_MODELS": modelsDirectory.path]) { $1 }
        process.qualityOfService = .utility
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Self.appendingHandle(indexDirectory.appendingPathComponent("indexer.log"))
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            guard let self else { return }
            indexQueue.async { self.received(data) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            guard let self else { return }
            indexQueue.async { self.helperExited(status: status) }
        }
        do {
            try process.run()
        } catch {
            log("indexer: can't start \(process.executableURL?.path ?? "the helper"): \(error)")
            update { $0.activity = .failed("Can't start indexing") }
            return
        }
        helper = process
        helperInput = input.fileHandleForWriting
        helperStarted = Date()
        helperOutput = Data()
        pruneWanted = false
        update {   // the helper says first if any are still missing or unreadable
            $0.missingRoots = []
            $0.unreadableRoots = []
        }
        log("indexer: started (pid \(process.processIdentifier))")
    }

    private func send(_ command: String) {
        do {
            try helperInput?.write(contentsOf: Data((command + "\n").utf8))
        } catch {
            // It's on its way out; `helperExited` restarts it if a sync is still owed.
            log("indexer: couldn't send \"\(command)\": \(error)")
        }
    }

    private func received(_ data: Data) {
        helperOutput.append(data)
        while let newline = helperOutput.firstIndex(of: 0x0A) {
            let line = helperOutput[helperOutput.startIndex..<newline]
            helperOutput.removeSubrange(helperOutput.startIndex...newline)
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(event)
        }
    }

    private func handle(_ event: [String: Any]) {
        func int(_ key: String) -> Int { event[key] as? Int ?? 0 }
        switch event["event"] as? String {
        case "sync":
            if let started = event["started"] as? Double, let wanted = syncWantedAt,
               started >= wanted.timeIntervalSince1970 {
                syncWantedAt = nil
            }
            applyCounts(event)
            if int("new") > 0 { update { $0.activity = .indexing(done: 0, total: int("new")) } }
            log("sync: \(int("added")) new · \(int("changed")) changed · \(int("moved")) moved · "
                + "\(int("removed")) removed · \(int("unchanged")) unchanged in \(int("ms")) ms")
        case "file":
            let (done, total) = (int("done"), int("total"))
            update { $0.activity = .indexing(done: done, total: total) }
            if event["new"] as? Bool == true, let path = event["path"] as? String {
                log(String(format: "index: %@ %@ in %.2f s", (path as NSString).lastPathComponent,
                           event["state"] as? String ?? "?", event["seconds"] as? Double ?? 0))
            }
            refreshSearcher(force: false)
        case "rest":
            update { $0.activity = .finishing(done: int("done"), total: int("total"), files: int("files")) }
            refreshSearcher(force: false)
        case "summary":
            let states = (event["states"] as? [String: Int] ?? [:]).sorted { $0.key < $1.key }
                .map { "\($0.value) \($0.key)" }.joined(separator: " · ")
            let what = event["rest"] as? Bool == true ? "the rest of long files"
                : event["new"] as? Bool == true ? "new files" : "backfill"
            log("index: \(what): \(states) in \(int("ms")) ms")
        case "idle":
            applyCounts(event)
            update { $0.activity = .idle }
            refreshSearcher(force: true)
        case "waiting":
            applyCounts(event)
            update {
                $0.activity = .idle
                $0.waitingForModel = true
            }
            log("indexer: waiting for the model to download")
        case "missing":
            let folders = event["folders"] as? [String] ?? []
            let unreadable = event["unreadable"] as? [String] ?? []
            update {
                $0.missingRoots = folders
                $0.unreadableRoots = unreadable
            }
            if !folders.isEmpty { log("indexer: not connected: \(folders.map(tildePath))") }
            if !unreadable.isEmpty { log("indexer: no access: \(unreadable.map(tildePath))") }
        case "pruned":
            log("indexer: \(int("files")) files under folders no longer chosen left the index")
        case "kept":
            log("indexer: saved \(int("vectors")) embeddings by file content, so they can be reused")
        case "reindex":
            if event["reuse"] as? Bool == true {
                log("indexer: re-reading files, reusing embeddings (was: \(event["from"] as? String ?? "?"))")
            } else {
                log("indexer: the model or settings changed, indexing everything again (was: \(event["from"] as? String ?? "?"))")
            }
        case "error":
            log("indexer: \(event["message"] as? String ?? "error")")
            if event["fatal"] as? Bool == true { update { $0.activity = .failed("Indexing stopped") } }
        default:
            break
        }
    }

    private func applyCounts(_ event: [String: Any]) {
        if let files = event["files"] as? Int {
            update {
                $0.files = files
                $0.searchable = event["searchable"] as? Int ?? 0
                $0.pending = event["pending"] as? Int ?? 0
                $0.vectors = event["vectors"] as? Int ?? 0
                $0.unfinished = event["unfinished"] as? Int ?? 0
            }
        }
    }

    private func helperExited(status: Int32) {
        helper = nil
        helperInput = nil
        log("indexer: exited (\(status)) after \(ms(since: helperStarted))")
        update {
            if case .indexing = $0.activity { $0.activity = .idle }
            if case .finishing = $0.activity { $0.activity = .idle }
            if case .starting = $0.activity { $0.activity = .idle }
        }
        refreshSearcher(force: true)
        returnFreedMemory()
        if restartHelper {
            // The folders changed: a new helper with the new ones.
            restartHelper = false
            startHelper()
        } else if syncWantedAt != nil, status == 0 {
            // A sync asked for while it was on its way out still has to happen.
            startHelper()
        }
    }

    /// New vectors reach the panel: reload the searcher's copy, at most every 2 s during a long pass. If the panel
    /// hasn't been used lately the vectors aren't loaded at all, and they load fresh when it opens.
    private func refreshSearcher(force: Bool) {
        guard force || Date().timeIntervalSince(lastSearcherRefresh) > 2 else { return }
        lastSearcherRefresh = Date()
        searchQueue.async { [self] in
            guard let searcher, searcher.vectorsLoaded else { return }
            let started = Date()
            try? searcher.reload()
            log("engine: searcher reloaded, \(searcher.vectorCount) vectors in \(ms(since: started))")
        }
    }

    /// Pause takes effect after the current batch (the helper finishes it and exits); Resume starts a new one.
    func setPaused(_ paused: Bool) {
        lock.withLock { self.paused = paused }
        update { $0.paused = paused }
        log(paused ? "indexing paused" : "indexing resumed")
        indexQueue.async { [self] in
            if paused { send("stop") } else { startHelper() }
        }
    }

    /// From `PowerPolicy`: why the backfill has to wait now, or nil when it may run.
    func setBackfillBlocker(_ reason: String?) {
        lock.withLock { backfillBlocker = reason }
        update { $0.waitingFor = reason }
        indexQueue.async { [self] in
            if helper != nil {
                send(reason == nil ? "backfill on" : "backfill off")
            } else if reason == nil {
                startHelper()
            }
        }
    }

    private static func appendingHandle(_ url: URL) -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return FileHandle.nullDevice }
        handle.seekToEndOfFile()
        return handle
    }

    // MARK: Search

    /// Hybrid search. Without a vector it's keyword-only (file names, OCR and document text), which is what the panel
    /// shows while the query encoder starts. Files that are gone (deleted since the last sync, or on a drive that's
    /// unplugged) are left out.
    /// `people`: only photos that contain every listed person together (AND).
    func search(_ text: String, vector: QueryVector?, prefixLast: Bool, kinds: Set<FileKind>? = nil,
                people: Set<Int64>? = nil, limit: Int = 40) async -> [SearchHit] {
        await withCheckedContinuation { continuation in
            searchQueue.async { [self] in
                var values = vector?.values
                var clauses = vector?.clauses ?? []
                if let vector, let indexed = searcher?.vectorSource, indexed != vector.source {
                    if !warnedAboutSource {
                        log("meaning search is off: the index was built with \(indexed), the encoder is \(vector.source)")
                        warnedAboutSource = true
                    }
                    values = nil
                    clauses = []
                }
                let parsed = Searcher.parse(text)
                if parsed.hasOperators { log("search: \(parsed.expression.summary)") }
                let hits = try? searcher?.search(text, queryVector: values, kinds: kinds, people: people, limit: limit,
                                                 prefixLast: prefixLast, clauseVectors: clauses)
                // Only files that are searched (`FolderSelection`'s rule, as the crawler walks them) and of types not
                // skipped: a removed folder's rows (or a newly skipped type's) can outlive it until a helper syncs
                // (indexing was paused, or the app quit first).
                let (chosen, excluded, types): ([URL], [URL], Set<String>) = lock.withLock {
                    (self.roots, self.excluded, Set(self.excludedTypes))
                }
                let folders = chosen.map(\.path), skipped = excluded.map(\.path)
                continuation.resume(returning: (hits ?? []).filter { hit in
                    FolderSelection.isSearched(hit.path, folders: folders, skipped: skipped)
                        && !types.contains((hit.path as NSString).pathExtension.lowercased())
                        && FileManager.default.fileExists(atPath: hit.path)
                })
            }
        }
    }

    /// The text of the part of a file a hit points at (a document's passage or a page), for the preview.
    func text(ofSegment id: Int64) async -> String? {
        await withCheckedContinuation { continuation in
            searchQueue.async { [self] in
                continuation.resume(returning: (try? searcher?.text(ofSegment: id)) ?? nil)
            }
        }
    }

    // MARK: People

    /// People clustered from face embeddings (named and still anonymous).
    func people() async -> [Person] {
        await withCheckedContinuation { continuation in
            searchQueue.async { [self] in
                continuation.resume(returning: (try? searchStore?.people()) ?? [])
            }
        }
    }

    func renamePerson(_ id: Int64, to name: String?) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            searchQueue.async { [self] in
                try? searchStore?.renamePerson(id, to: name)
                continuation.resume()
            }
        }
    }

    func mergePeople(keeper: Int64, other: Int64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            searchQueue.async { [self] in
                try? searchStore?.mergePeople(keeper: keeper, other: other)
                continuation.resume()
            }
        }
    }

    /// Photo path for a person's exemplar face thumbnail.
    func exemplarPhoto(ofPerson id: Int64) async -> String? {
        await withCheckedContinuation { continuation in
            searchQueue.async { [self] in
                continuation.resume(returning: try? searchStore?.exemplarPhotoPath(ofPerson: id))
            }
        }
    }

    /// Exemplar face box, for a circular crop in Albums.
    func exemplarFace(ofPerson id: Int64) async -> ExemplarFace? {
        await withCheckedContinuation { continuation in
            searchQueue.async { [self] in
                continuation.resume(returning: try? searchStore?.exemplarFace(ofPerson: id))
            }
        }
    }

    /// Trips for photos that include any of `people`.
    func albums(ofPeople people: Set<Int64>) async -> AlbumBuild {
        await withCheckedContinuation { continuation in
            searchQueue.async { [self] in
                let photos = (try? searchStore?.albumPhotos(ofPeople: people)) ?? []
                continuation.resume(returning: AlbumClusterer.build(photos))
            }
        }
    }

    // MARK: Index overview (main window)

    /// What's indexed under one folder.
    struct RootSummary: Sendable, Identifiable {
        let path: String
        var missing = false
        var unreadable = false
        var files = 0, indexed = 0, pending = 0, failed = 0, skipped = 0
        var unfinished = 0   // long files searchable but still being read (counted in `indexed` too)
        var kinds: [FileKind: Int] = [:]
        var id: String { path }
    }

    /// What's indexed under each folder.
    func rootSummaries() async -> [RootSummary] {
        await withCheckedContinuation { continuation in
            searchQueue.async { [self] in
                let unreadable = Set(lock.withLock { status.unreadableRoots })
                let store = searchStore
                let summaries = lock.withLock { roots }.map { root -> RootSummary in
                    var summary = RootSummary(path: root.path, missing: !AppSettings.isFolder(root),
                                              unreadable: unreadable.contains(root.path))
                    for file in (try? store?.files(under: [root.path])) ?? [] {
                        summary.files += 1
                        summary.kinds[file.kind, default: 0] += 1
                        switch file.state {
                        case "done": summary.indexed += 1
                        case "partial":
                            summary.indexed += 1
                            summary.unfinished += 1
                        case "pending": summary.pending += 1
                        case "failed": summary.failed += 1
                        default: summary.skipped += 1
                        }
                    }
                    return summary
                }
                continuation.resume(returning: summaries)
            }
        }
    }

    /// Bytes on disk: the database and its write-ahead log.
    var indexSize: Int64 {
        IndexStore.size(of: indexDirectory.appendingPathComponent(IndexStore.mainFile))
    }

    // MARK: Query encoder

    /// Gets meaning search ready as the panel opens: starts the query encoder (~0.35 s cold) and loads the vectors,
    /// in parallel, so both are usually done by the time you've typed a few words.
    func prewarm() {
        encoderQueue.async { [self] in
            encoderFailed = false   // opening the panel is a fresh chance
            if runningEncoder() != nil { scheduleIdleExit() }
        }
        searchQueue.async { [self] in
            guard let searcher, !searcher.vectorsLoaded else { return }
            let started = Date()
            do {
                try searcher.reload()
                log("engine: \(searcher.vectorCount) vectors loaded in \(ms(since: started))")
            } catch {
                log("can't load vectors: \(error)")
            }
        }
    }

    /// True when query understanding is on and a saved key is complete enough to send.
    var rewritesQueries: Bool { lock.withLock { queryUnderstanding && OpenRouterKey.usable(openRouterAPIKey) } }

    func setQueryUnderstanding(_ on: Bool) {
        lock.withLock { queryUnderstanding = on }
    }

    func setOpenRouterKey(_ key: String) {
        let trimmed = OpenRouterKey.normalize(key)
        lock.withLock {
            guard trimmed != openRouterAPIKey else { return }
            openRouterAPIKey = trimmed
            rewriteCache.removeAll()
        }
    }

    /// The question Luna rewrote. `search` is what to embed. `interpreted` is the line under the field.
    func formalQuery(_ text: String) async -> QueryReading {
        let key = lock.withLock { openRouterAPIKey }
        guard OpenRouterKey.usable(key) else { return .asTyped(text) }
        if let cached = lock.withLock({ rewriteCache[text] }) { return cached }
        let reply: QueryRewrite.Reply?
        do {
            reply = try await QueryRewrite.line(text, apiKey: key)
        } catch let error as URLError where error.code == .cancelled {
            return .asTyped(text)
        } catch is CancellationError {
            return .asTyped(text)
        } catch {
            log("openrouter: \(error)")
            let reading = QueryReading(search: text, interpreted: nil, note: QueryReading.note(for: error))
            lock.withLock { rewriteCache[text] = reading }
            return reading
        }
        guard !Task.isCancelled else { return .asTyped(text) }
        guard let reply else {
            log("openrouter: no reading for “\(text)”")
            return .asTyped(text)
        }
        let same = reply.line == text
        let reading = QueryReading(
            search: reply.trusted ? reply.line : text,
            interpreted: same ? nil : reply.line,
            note: reply.trusted ? nil : "Not used — it added words that weren't in the question. Click it to search anyway.")
        lock.withLock { rewriteCache[text] = reading }
        if reply.trusted, !same { log("query: “\(text)” → \(reply.line)") }
        if !reply.trusted { log("openrouter: ignored “\(reply.line)”") }
        return reading
    }

    /// The field's current text. An embed for an older keystroke is skipped, including when Luna rewrote that keystroke
    /// into a different line (`embedQuery`).
    func noteTyped(_ text: String) {
        lock.withLock { newestTyped = text }
    }

    /// Embeds what's typed so far, right away, and caches it. The panel calls this on every keystroke: the GPU stays
    /// awake (after even 150 ms idle a query takes ~19 ms instead of ~6), and when typing pauses the vector is
    /// usually ready. Skipped when newer text arrives before its turn.
    func embedAhead(_ text: String) {
        noteTyped(text)
        encoderQueue.async { [self] in
            guard lock.withLock({ newestTyped }) == text else { return }
            _ = vector(for: text)
        }
    }

    /// The query's vector, or nil when the encoder can't run (keyword results still work). Also nil, at once, when
    /// `typed` is no longer what's in the field: its results would be thrown away. `text` may be Luna's line, which
    /// is not what was typed.
    func embedQuery(_ text: String, typed: String) async -> QueryVector? {
        return await withCheckedContinuation { continuation in
            encoderQueue.async { [self] in
                let newest = lock.withLock { newestTyped }
                if vectorCache[text] == nil, let newest, newest != typed {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: vector(for: text))
            }
        }
    }

    private func vector(for text: String) -> QueryVector? {
        if let cached = vectorCache[text] { return cached }
        guard let worker = runningEncoder() else { return nil }
        defer { scheduleIdleExit() }
        do {
            let phrases = Searcher.embedPhrases(text)
            guard !phrases.isEmpty else { return nil }
            let embedded = try worker.embedTexts(phrases.map(Prompts.query))
            let parsed = Searcher.parse(text)
            let vector = QueryVector(values: embedded.first ?? [], source: worker.info.vectorSource,
                                     clauses: parsed.hasOperators ? embedded : [])
            vectorCache[text] = vector
            return vector
        } catch {
            log("encoder: \(error)")
            stopEncoder()   // the next query starts a new one
            return nil
        }
    }

    private func runningEncoder() -> EmbeddingWorker? {
        if let encoder { return encoder }
        guard !encoderFailed else { return nil }
        let python = try? WorkerConfig.fromEnvironment()
        // Still downloading: no meaning search yet, which isn't a failure.
        guard python != nil || FileManager.default.fileExists(
            atPath: modelsDirectory.appendingPathComponent(ModelFiles.text.name).path) else { return nil }
        update { $0.encoder = .starting }
        let started = Date()
        do {
            // The bundled helper runs the model (`digup worker`); DIGUP_WORKER_DIR swaps in another worker.
            var config = python ?? .helper(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/digup"))
            config.environment["DIGUP_MODELS"] = modelsDirectory.path
            config.log = indexDirectory.appendingPathComponent("worker-query.log")
            config.qos = .userInitiated
            let worker = try EmbeddingWorker(config, textOnly: true)
            encoder = worker
            log("encoder: ready in \(ms(since: started)) (model load and warm-up \(worker.info.loadSeconds ?? 0) s)")
            update { $0.encoder = .ready }
            return worker
        } catch {
            encoderFailed = true
            log("encoder: can't start: \(error)")
            update { $0.encoder = .unavailable }
            return nil
        }
    }

    /// The encoder exits after `encoderIdleSeconds` without a query (its ~0.25 GB goes back to the system), and the
    /// vectors go with it; keyword search keeps working, and the next panel open brings both back.
    private func scheduleIdleExit() {
        encoderIdleExit?.cancel()
        let exit = DispatchWorkItem { [self] in
            guard encoder != nil else { return }
            log("encoder: idle for \(Int(encoderIdleSeconds)) s, stopping")
            stopEncoder()
            searchQueue.async { [self] in
                searcher?.releaseVectors()
                returnFreedMemory()
            }
        }
        encoderIdleExit = exit
        encoderQueue.asyncAfter(deadline: .now() + encoderIdleSeconds, execute: exit)
    }

    private func stopEncoder() {
        encoder?.close()
        encoder = nil
        vectorCache.removeAll()
        encoderIdleExit?.cancel()
        encoderIdleExit = nil
        update { $0.encoder = .stopped }
    }
}

/// Recent query vectors by text: retyping or going back to an earlier query costs nothing.
nonisolated struct QueryVectorCache {
    let limit: Int
    private var vectors: [String: Engine.QueryVector] = [:]
    private var order: [String] = []

    init(limit: Int) {
        self.limit = limit
    }

    subscript(text: String) -> Engine.QueryVector? {
        get { vectors[text] }
        set {
            guard let newValue else { return }
            if vectors.updateValue(newValue, forKey: text) == nil { order.append(text) }
            if order.count > limit { vectors[order.removeFirst()] = nil }
        }
    }

    mutating func removeAll() {
        vectors = [:]
        order = []
    }
}

/// Hands pages that malloc has freed back to the OS. A crawl or an indexing batch leaves megabytes of freed but still
/// dirty pages, which count against the app's footprint until something else asks for memory.
nonisolated func returnFreedMemory() {
    malloc_zone_pressure_relief(nil, 0)
}
