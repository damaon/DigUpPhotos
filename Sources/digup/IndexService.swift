import DigUpKit
import Foundation

/// `digup index-service`: the app's indexing helper, one process per stretch of work.
///
/// Extraction (Vision OCR, ImageIO, PDFKit, AVFoundation) runs here and not in the app. Vision alone keeps ~100 MB
/// of models cached in whatever process ran OCR (measured: the app went from 16 to 93 MB after indexing 11
/// screenshots, and stayed there), and all of it goes back to the system when this process exits.
///
/// Protocol: one command per line on stdin, one JSON event per line on stdout.
///   stdin:  sync | stop | backfill on | backfill off      (EOF = stop)
///   stdout: {"event": "missing" | "pruned" | "sync" | "file" | "rest" | "summary" | "waiting" | "idle" | "error" |
///            "exit", ...}
///
/// The loop: sync, index what the sync just queued (if it's a few files: new files go first, on any power source),
/// then the backfill if allowed; then the rest of long files (`Indexer.finishLongFiles`) under the same rules.
/// Between batches it yields to a new sync, to stop, and to "backfill off". When it's done it keeps a warm worker
/// for `linger` seconds (screenshots come in bursts), then exits.
///
/// Before the model has downloaded it only syncs (file names are searchable at once), says it's "waiting", and exits.
/// Folders that aren't there (an unplugged drive) or can't be read are skipped, and what was indexed from them stays.
/// That's checked before every sync, not once: a drive ejected while this runs must not crawl as "all deleted".
final class IndexService: @unchecked Sendable {
    /// One index: its store, its indexer, its folders.
    struct Part {
        let store: IndexStore
        let indexer: Indexer
        /// The chosen folders, there or not.
        let roots: [URL]
        /// When set, files under none of these folders leave the index (folders taken out of the app).
        let keepOnly: [URL]?
    }

    private let main: Part
    private let model: SharedEmbedder
    /// The last report of folders that aren't there or can't be read, by index (said again only when it changes).
    private var unavailable: (missing: [String], unreadable: [String])?
    private let modelReady: () -> Bool
    private let newFilesLimit: Int
    private let linger: Double

    private let lock = NSLock()
    private var syncRequested = true       // the first thing it does
    private var stopRequested = false
    private var backfillAllowed: Bool
    private let wake = DispatchSemaphore(value: 0)

    init(main: Part, model: SharedEmbedder, modelReady: @escaping () -> Bool, backfill: Bool,
         newFilesLimit: Int, linger: Double) {
        self.main = main
        self.model = model
        self.modelReady = modelReady
        self.backfillAllowed = backfill
        self.newFilesLimit = newFilesLimit
        self.linger = linger
    }

    func serve() -> Int32 {
        removeStaleScratchFolders()
        do {
            let kept = try main.indexer.checkModel()   // a new model: everything is queued again
            if kept > 0 { emit(["event": "kept", "vectors": kept]) }
            if let keepOnly = main.keepOnly {
                let pruned = try main.store.prune(keepingUnder: keepOnly.map(\.path))
                if pruned > 0 { emit(["event": "pruned", "files": pruned]) }
            }
        } catch {
            emit(["event": "error", "message": "\(error)", "fatal": true])
            finish()
            return 1
        }
        Thread.detachNewThread { [self] in readCommands() }
        var newFiles = Set<Int64>()
        while true {
            if lock.withLock({ () -> Bool in defer { syncRequested = false }; return syncRequested }) {
                sync(into: &newFiles)
            }
            if lock.withLock({ stopRequested }) { break }
            guard modelReady() else {
                // Nothing to embed with yet; the app starts another helper once the download is done.
                emitCounts("waiting", ["for": "model"])
                break
            }
            if !newFiles.isEmpty {
                guard run(only: newFiles) else { break }
                newFiles = left(of: newFiles)
                continue
            }
            if (try? main.store.pendingCount()) ?? 0 > 0, lock.withLock({ backfillAllowed }) {
                guard run(only: nil) else { break }
                if lock.withLock({ syncRequested }) { continue }
            }
            // Once nothing is waiting: the rest of long PDFs and documents, the same way.
            if lock.withLock({ backfillAllowed }), (try? main.store.pendingCount()) ?? 1 == 0,
               (try? main.store.unfinishedCount().files) ?? 0 > 0 {
                guard finishLongFiles() else { break }
                if lock.withLock({ syncRequested }) { continue }
            }
            emitCounts("idle")
            // Nothing warm to keep around: leave now. Else wait a little for more work.
            guard model.isRunning, waitForWork() else { break }
        }
        finish()
        emit(["event": "exit"])
        return 0
    }

    private func finish() {
        main.indexer.finish()
        model.close()
    }

    /// New files a run stopped before (a sync or stop came first): kept for the next round. Done: anything still
    /// pending joins the backfill.
    private func left(of files: Set<Int64>) -> Set<Int64> {
        let yielded = lock.withLock { syncRequested || stopRequested }
        return yielded ? Set((try? main.store.pending(limit: nil, only: files).map(\.id)) ?? []) : []
    }

    /// Scratch folders ($TMPDIR/DigUp-<pid>) of indexing processes that are gone (killed mid-batch).
    private func removeStaleScratchFolders() {
        let temp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? [] {
            guard name.hasPrefix("DigUp-"), let pid = Int32(name.dropFirst("DigUp-".count)),
                  pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: temp.appendingPathComponent(name))
        }
    }

    /// The chosen folders that are there and readable right now; also what `pending` and the counts look at.
    private func availableRoots() -> [URL] {
        let missing = main.roots.filter { !Arguments.isFolder($0) }
        let unreadable = main.roots.filter { !missing.contains($0) && !Arguments.isReadable($0) }
        let report = (missing.map(\.path), unreadable.map(\.path))
        if unavailable.map({ $0 != report }) ?? !(missing.isEmpty && unreadable.isEmpty) {
            emit(["event": "missing", "folders": report.0, "unreadable": report.1])
        }
        unavailable = report
        let available = main.roots.filter { !missing.contains($0) && !unreadable.contains($0) }
        main.store.scope = available.map(\.path)
        return available
    }

    private func sync(into newFiles: inout Set<Int64>) {
        let started = Date()
        do {
            let summary = try main.indexer.sync(availableRoots())
            if summary.queued.count <= newFilesLimit { newFiles.formUnion(summary.queued) }
            emitCounts("sync", [
                "new": newFiles.count,   // about to be indexed, whatever the power source
                "added": summary.added, "changed": summary.changed, "moved": summary.moved,
                "removed": summary.removed, "unchanged": summary.unchanged,
                "ms": Int(Date().timeIntervalSince(started) * 1000),
                "started": started.timeIntervalSince1970,   // the app checks its sync request came before this
            ])
        } catch {
            emit(["event": "error", "message": "sync failed: \(error)"])
        }
    }

    /// Embeds pending files (`only` some). False when indexing has to stop (the worker died, or the index was
    /// built with other settings).
    private func run(only ids: Set<Int64>?) -> Bool {
        let started = Date()
        let isNew = ids != nil
        do {
            let states = try main.indexer.run(only: ids, shouldStop: { [self] in
                lock.withLock { syncRequested || stopRequested || (!isNew && !backfillAllowed) }
            }, onEvent: { event in
                emit(["event": "file", "new": isNew, "done": event.done, "total": event.total, "path": event.path,
                      "kind": event.kind.rawValue, "state": event.state, "seconds": event.seconds,
                      "note": event.note ?? ""])
            })
            if !states.isEmpty {
                emit(["event": "summary", "new": isNew, "states": states,
                      "ms": Int(Date().timeIntervalSince(started) * 1000)])
            }
            return true
        } catch {
            emit(["event": "error", "message": "\(error)", "fatal": true])
            return false
        }
    }

    /// The rest of long files (`Indexer.finishLongFiles`), yielding as the backfill does. False when indexing has to
    /// stop.
    private func finishLongFiles() -> Bool {
        let started = Date()
        do {
            let states = try main.indexer.finishLongFiles(shouldStop: { [self] in
                lock.withLock { syncRequested || stopRequested || !backfillAllowed }
            }, onStep: { step in
                emit(["event": "rest", "done": step.done, "total": step.total, "files": step.files, "path": step.path,
                      "kind": step.kind.rawValue, "state": step.state, "seconds": step.seconds, "note": step.note ?? ""])
            })
            if !states.isEmpty {
                emit(["event": "summary", "rest": true, "states": states,
                      "ms": Int(Date().timeIntervalSince(started) * 1000)])
            }
            return true
        } catch {
            emit(["event": "error", "message": "\(error)", "fatal": true])
            return false
        }
    }

    /// Waits up to `linger` seconds for something to do. False: time's up, or told to stop.
    private func waitForWork() -> Bool {
        let deadline = DispatchTime.now() + linger
        while wake.wait(timeout: deadline) == .success {
            let (sync, stop, backfill) = lock.withLock { (syncRequested, stopRequested, backfillAllowed) }
            if stop { return false }
            if sync { return true }
            if backfill, (try? main.store.pendingCount()) ?? 0 > 0
                || (try? main.store.unfinishedCount().files) ?? 0 > 0 {
                return true
            }
        }
        return false
    }

    private func readCommands() {
        while let line = readLine() {
            lock.withLock {
                switch line.trimmingCharacters(in: .whitespaces) {
                case "sync": syncRequested = true
                case "stop": stopRequested = true
                case "backfill on": backfillAllowed = true
                case "backfill off": backfillAllowed = false
                default: break
                }
            }
            wake.signal()
        }
        lock.withLock { stopRequested = true }   // the app went away
        wake.signal()
    }

    /// An event with the index's counts.
    private func emitCounts(_ event: String, _ extra: [String: Any] = [:]) {
        var fields = extra
        fields["event"] = event
        if let counts = try? main.store.counts() {
            var files = 0, searchable = 0, pending = 0
            for states in counts.byKindAndState.values {
                for (state, count) in states {
                    files += count
                    if state == "done" || state == "partial" { searchable += count }
                    if state == "pending" { pending += count }
                }
            }
            fields["files"] = files
            fields["searchable"] = searchable
            fields["pending"] = pending
            fields["vectors"] = counts.vectors
            fields["unfinished"] = counts.unfinished   // long files with pages or chunks left to read
        }
        emit(fields)
    }
}

/// One model, started when the first file needs it and closed when the helper is done. The indexer gets it as an
/// `Embedder` whose `close` leaves it be.
final class SharedEmbedder: @unchecked Sendable {
    private let make: () throws -> any Embedder
    private var model: (any Embedder)?

    init(_ make: @escaping () throws -> any Embedder) {
        self.make = make
    }

    var isRunning: Bool { model != nil }

    func embedder() throws -> any Embedder {
        if model == nil { model = try make() }
        return Kept(model!)
    }

    func close() {
        model?.close()
        model = nil
    }

    private final class Kept: Embedder {
        let model: any Embedder
        init(_ model: any Embedder) { self.model = model }
        var info: WorkerInfo { model.info }
        func embedTexts(_ texts: [String]) throws -> [[Float]] { try model.embedTexts(texts) }
        func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] {
            try model.embedImages(paths, budget: budget)
        }
        func embedAudio(_ paths: [String]) throws -> [Embedding] { try model.embedAudio(paths) }
        func close() {}
    }
}

/// One JSON object per line on stdout, written straight to the file descriptor (print() would buffer in a pipe).
/// The app may be gone by now (it quit while this helper lingered): a closed pipe is an error to ignore here, not the
/// exception that `write(_:)` raises, which used to crash the helper on its way out.
func emit(_ fields: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
    try? FileHandle.standardOutput.write(contentsOf: data + [0x0A])
}
