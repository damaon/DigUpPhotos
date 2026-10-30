// Indexes real PDFs, documents and photos: needs a MediaReading (Apple's, for now).
#if canImport(DigUpApple)
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DigUpCore

/// New face crops or a new quality score: only the photos that touches are read again, and search keeps working.
@Suite final class RereadTests {
    /// In Caches, like `LongFilesTests`: the crawl reports this path as it's given.
    let folder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("files"), withIntermediateDirectories: true)
        return url
    }()

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    var files: URL { folder.appendingPathComponent("files") }

    func photo(_ name: String, gray: CGFloat) throws -> URL {
        let url = files.appendingPathComponent(name)
        let context = CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    func row(_ store: IndexStore, _ url: URL) throws -> (id: Int64, state: String, images: Int) {
        var out: (Int64, String, Int) = (0, "", 0)
        try store.db.query("""
            SELECT f.id, f.state, (SELECT COUNT(*) FROM segments s WHERE s.file = f.id AND s.kind = 'image')
            FROM files f WHERE f.path = ?
            """, [.text(url.path)]) { out = ($0.int(0), $0.text(1) ?? "", Int($0.int(2))) }
        return out
    }

    /// Indexes two photos, gives one a face, and pretends the index was built with older settings.
    func indexed(was oldStamp: (IndexStamp) -> String) throws -> (IndexStore, Indexer, face: URL, plain: URL) {
        let face = try photo("face.jpg", gray: 0.3)
        let plain = try photo("plain.jpg", gray: 0.7)
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        var options = IndexOptions()
        options.kinds = [.image, .video]
        let embedder = FakeEmbedder()
        let indexer = try Indexer(store: store, options: options, reader: testReader, makeEmbedder: { embedder })
        indexer.embedderSource = embedder.info.vectorSource
        indexer.resetOnModelChange = { _, _, _ in }
        _ = try indexer.sync([files])
        try indexer.run()
        try store.replaceFaces(of: try row(store, face).id,
                               with: [(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), FakeEmbedder.vector(for: "f"))])
        let now = try #require(try store.meta("fingerprint"))
        try store.setMeta("fingerprint", oldStamp(IndexStamp.parse(now)))
        return (store, indexer, face, plain)
    }

    func stamp(_ stamp: IndexStamp, quality: Int?, faces: Int?) -> String {
        var tokens = [stamp.kinds, stamp.vectors].compactMap { $0 }
        if let quality { tokens.append("q\(quality)") }
        if let faces { tokens.append("f\(faces)") }
        return "\(stamp.model) | " + tokens.joined(separator: " ")
    }

    @Test func newFaceCropsReadOnlyPhotosWithFaces() throws {
        let (store, indexer, face, plain) = try indexed { self.stamp($0, quality: $0.quality, faces: $0.faces! - 1) }
        try indexer.checkModel()
        #expect(try row(store, face).state == "pending")
        #expect(try row(store, plain).state == "done")
        // Still searchable while it waits.
        #expect(try row(store, face).images == 1)
        try indexer.run()
        #expect(try row(store, face).state == "done")
        #expect(try row(store, face).images == 1)   // replaced, not added twice
        #expect(try row(store, plain).images == 1)
    }

    @Test func newQualityReadsEveryPhoto() throws {
        let (store, indexer, face, plain) = try indexed { self.stamp($0, quality: $0.quality! - 1, faces: $0.faces) }
        try indexer.checkModel()
        #expect(try row(store, face).state == "pending")
        #expect(try row(store, plain).state == "pending")
        #expect(try row(store, plain).images == 1)
        try indexer.run()
        #expect(try row(store, plain).state == "done")
        #expect(try row(store, plain).images == 1)
    }

    /// An index from before quality and face stamps: everything again, as it was.
    @Test func olderStampsReadEverything() throws {
        let (store, indexer, _, plain) = try indexed { self.stamp($0, quality: nil, faces: nil) }
        try indexer.checkModel()
        #expect(try row(store, plain).state == "pending")
        #expect(try row(store, plain).images == 0)
    }
}
#endif
