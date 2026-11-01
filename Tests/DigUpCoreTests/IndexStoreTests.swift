#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import Testing
@testable import DigUpCore

@Suite final class IndexStoreTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    func file(_ path: String, inode: UInt64) -> Candidate {
        Candidate(path: path, kind: .image, size: 10, mtime: 1, inode: inode, device: 1)
    }

    @Test func pruneKeepsOnlyChosenFolders() throws {
        let store = try IndexStore(directory: folder)
        try store.insert(file("/a/x.png", inode: 1))
        try store.insert(file("/a/sub/y.png", inode: 2))
        try store.insert(file("/ab/z.png", inode: 3))   // a sibling whose name starts like "/a", not inside it
        try store.insert(file("/b/w.png", inode: 4))
        #expect(try store.prune(keepingUnder: ["/a"]) == 2)
        #expect(try store.files(under: ["/a"]).count == 2)
        #expect(try store.files(under: ["/ab", "/b"]).isEmpty)
        var keywordRows = 0
        try store.db.query("SELECT COUNT(*) FROM fts") { keywordRows = Int($0.int(0)) }
        #expect(keywordRows == 2)   // the pruned files' names left keyword search too
        #expect(try store.prune(keepingUnder: []) == 2)
    }

    #if canImport(DigUpApple)
    @Test func embeddingCacheSurvivesAQualityReread() throws {
        let store = try IndexStore(directory: folder)
        let url = folder.appendingPathComponent("photo.jpg")
        try Data("same-bytes".utf8).write(to: url)
        let id = try store.insert(file(url.path, inode: 9))
        let original: [Float] = [0.1, 0.2, 0.3, 0.4]
        try store.addSegment(file: id, kind: .image, modality: .image, vector: original)
        let options = IndexOptions()
        let source = "test-model"
        try store.setMeta("fingerprint", "\(source) | \(options.vectorFingerprint) q1 f1")
        let indexer = try Indexer(store: store, options: options, reader: testReader,
                                  makeEmbedder: { () throws -> any Embedder in
            throw IndexerError.fingerprintMismatch(index: "", now: "")
        })
        indexer.embedderSource = source
        var reused: Bool?
        indexer.resetOnModelChange = { _, _, reuse in reused = reuse }
        let saved = try indexer.checkModel()
        #expect(saved == 1)
        #expect(reused == true)
        #expect(try store.pendingCount() == 1)
        var imageVectors = 0
        try store.db.query("SELECT COUNT(vec) FROM segments WHERE kind = 'image'") { imageVectors = Int($0.int(0)) }
        #expect(imageVectors == 1)   // still searchable until it is read again
        let stamp = "\(source) | \(options.vectorFingerprint)"
        let again = try store.cachedEmbedding(sha: ModelFiles.sha256(of: url), stamp: stamp, kind: "image",
                                              slot: EmbeddingCache.imageSlot(budget: options.photoBudget))
        #expect(again?.count == original.count)
        if let again {
            for (left, right) in zip(again, original) { #expect(abs(left - right) < 0.001) }
        }
        // The model is not asked. A second pass finds the same bytes.
        let lookup = try store.cachedEmbedding(sha: try store.storedSHA(of: id) ?? "", stamp: stamp, kind: "image",
                                               slot: EmbeddingCache.imageSlot(budget: options.photoBudget))
        #expect(lookup?.count == original.count)
    }
    #endif

    #if canImport(DigUpApple)
    @Test func aNewEmbeddingBudgetDropsTheCache() throws {
        let store = try IndexStore(directory: folder)
        let url = folder.appendingPathComponent("photo.jpg")
        try Data("same-bytes".utf8).write(to: url)
        let id = try store.insert(file(url.path, inode: 9))
        try store.addSegment(file: id, kind: .image, modality: .image, vector: [0.5, 0.5])
        var options = IndexOptions()
        let source = "test-model"
        let oldStamp = "\(source) | \(options.vectorFingerprint)"
        try store.storeEmbedding(sha: "abc", stamp: oldStamp, kind: "image", slot: "b140", vector: [0.5, 0.5])
        try store.setMeta("fingerprint", "\(oldStamp) q2 f1")
        options.photoBudget = 280
        let indexer = try Indexer(store: store, options: options, reader: testReader,
                                  makeEmbedder: { () throws -> any Embedder in
            throw IndexerError.fingerprintMismatch(index: "", now: "")
        })
        indexer.embedderSource = source
        var reused: Bool?
        indexer.resetOnModelChange = { _, _, reuse in reused = reuse }
        #expect(try indexer.checkModel() == 0)
        #expect(reused == false)
        var cached = 0
        try store.db.query("SELECT COUNT(*) FROM embedding_cache") { cached = Int($0.int(0)) }
        #expect(cached == 0)
    }
    #endif

    @Test func scopeLimitsWhatIsWaiting() throws {
        let store = try IndexStore(directory: folder)
        try store.insert(file("/a/x.png", inode: 1))
        try store.insert(file("/drive/y.png", inode: 2))   // on a drive that's unplugged
        store.scope = ["/a"]
        #expect(try store.pendingCount() == 1)
        #expect(try store.pending(limit: nil).map(\.path) == ["/a/x.png"])
        #expect(try store.counts().byKindAndState["image"]?["pending"] == 1)
        store.scope = []
        #expect(try store.pendingCount() == 0)
        store.scope = nil
        #expect(try store.pendingCount() == 2)
    }

    @Test func modelFileHashesStreamInPieces() throws {
        let small = folder.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: small)
        #expect(try ModelFiles.sha256(of: small) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Bigger than one 8 MB piece.
        let bytes = Data((0..<(9 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let big = folder.appendingPathComponent("big")
        try bytes.write(to: big)
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(try ModelFiles.sha256(of: big) == expected)
    }

    @Test func missingModelFilesInDownloadOrder() throws {
        #expect(ModelFiles.missing(in: folder) == [ModelFiles.text, ModelFiles.media])
        FileManager.default.createFile(atPath: folder.appendingPathComponent(ModelFiles.text.name).path, contents: nil)
        #expect(ModelFiles.missing(in: folder) == [ModelFiles.media])
        #expect(ModelFiles.totalBytes == 864_676_480)
    }

    // Symbolic links need an administrator (or developer mode) on Windows, and setenv isn't there.
    #if !os(Windows)
    @Test func modelFilesComeFromTheHuggingFaceCacheWhenThere() throws {
        // As `hf download` leaves them: snapshots/<revision>/<name> → a blob. Sparse, so no disk is used.
        let hub = folder.appendingPathComponent("hub")
        let snapshot = hub.appendingPathComponent("models--ggml-org--embeddinggemma-2-GGUF/snapshots/\(ModelFiles.revision)")
        let blobs = hub.appendingPathComponent("models--ggml-org--embeddinggemma-2-GGUF/blobs")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let blob = blobs.appendingPathComponent("2188ac1d")
        FileManager.default.createFile(atPath: blob.path, contents: nil)
        try FileHandle(forWritingTo: blob).truncate(atOffset: UInt64(ModelFiles.text.bytes))
        try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent(ModelFiles.text.name),
                                                   withDestinationURL: blob)
        setenv("HF_HUB_CACHE", hub.path, 1)
        defer { unsetenv("HF_HUB_CACHE") }
        // A home of its own: this Mac's real ~/Library may hold the models.
        #expect(ModelFiles.cachedCopy(of: ModelFiles.text, home: folder)?.lastPathComponent == "2188ac1d")
        #expect(ModelFiles.cachedCopy(of: ModelFiles.media, home: folder) == nil)   // not there
        try FileHandle(forWritingTo: blob).truncate(atOffset: 10)
        #expect(ModelFiles.cachedCopy(of: ModelFiles.text, home: folder) == nil)    // not whole
    }
    #endif

    #if canImport(DigUpApple)
    @Test func syncKeepsTheRowsOfAFolderThatWentAway() throws {
        // The real path (/private/var/…), as the crawler reports it; resolvingSymlinksInPath() would drop "/private".
        let base = URL(fileURLWithPath: String(cString: realpath(folder.path, nil)))
        let drive = base.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        try Data("notes from the trip".utf8).write(to: drive.appendingPathComponent("notes.txt"))
        let store = try IndexStore(directory: base.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), reader: testReader,
                                  makeEmbedder: { throw WorkerError.notFound("no model needed to sync") })
        #expect(try indexer.sync([drive]).added == 1)
        try FileManager.default.moveItem(at: drive, to: base.appendingPathComponent("ejected"))
        #expect(try indexer.sync([drive]).removed == 0)   // an ejected drive is not "everything deleted"
        #expect(try store.files(under: [drive.path]).count == 1)
    }
    #endif

    #if !os(Windows)
    /// A folder given by a path through a symlink (/tmp for /private/tmp on macOS): the walk reports real paths, and
    /// the second sync finds what the first indexed under them rather than adding it again.
    @Test func syncFindsFilesUnderTheRealPath() throws {
        let real = URL(fileURLWithPath: FolderSelection.realPath(folder.path)).appendingPathComponent("library")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try Data("a note".utf8).write(to: real.appendingPathComponent("photos/note.txt"))
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let root = link.appendingPathComponent("photos")
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), reader: testReader,
                                  makeEmbedder: { throw WorkerError.notFound("no model needed to sync") })
        #expect(try indexer.sync([root]).added == 1)
        let again = try indexer.sync([root])
        #expect(again.added == 0 && again.unchanged == 1)
    }
    #endif
}

