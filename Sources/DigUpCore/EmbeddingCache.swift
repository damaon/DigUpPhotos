import Foundation

/// Embeddings remembered by the SHA-256 of the file's bytes, so a later pass can redo quality, faces and the other
/// details without running the model again.
///
/// The key is the file contents plus the vector settings (`IndexOptions.vectorFingerprint`) and the model. Two copies
/// of the same photo share one embedding. A new quality score does not. A new model does: those vectors can't be
/// compared with the old ones, so that stamp misses and the model runs.
enum EmbeddingCache {
    static let tableSQL = """
        CREATE TABLE IF NOT EXISTS embedding_cache(
            sha TEXT NOT NULL,
            stamp TEXT NOT NULL,
            kind TEXT NOT NULL,
            slot TEXT NOT NULL,
            vec BLOB NOT NULL,
            PRIMARY KEY (sha, stamp, kind, slot)
        );
        """

    /// The photo or screenshot itself. The budget is part of the slot: the same bytes embedded as a screenshot
    /// (more vision tokens) are not the photo's vector.
    static func imageSlot(budget: Int) -> String { "b\(budget)" }

    /// A page, chunk, frame or audio window. Whole-file segments with no location use an empty slot.
    static func slot(kind: String, loc: Double?, imageBudget: Int) -> String {
        if kind == SegmentKind.image.rawValue, loc == nil { return imageSlot(budget: imageBudget) }
        guard let loc else { return "" }
        return String(format: "%.4f", loc)
    }

    static func slot(loc: Double?) -> String {
        guard let loc else { return "" }
        return String(format: "%.4f", loc)
    }

}

extension IndexStore {
    func storedSHA(of id: Int64) throws -> String? {
        var sha: String?
        try db.query("SELECT sha FROM files WHERE id = ?", [.int(id)]) { sha = $0.text(0) }
        if sha?.isEmpty == true { sha = nil }
        return sha
    }

    func setContentSHA(_ id: Int64, _ sha: String) throws {
        try db.run("UPDATE files SET sha = ? WHERE id = ?", [.text(sha), .int(id)])
    }

    func cachedEmbedding(sha: String, stamp: String, kind: String, slot: String) throws -> [Float]? {
        var blob: Data?
        try db.query("SELECT vec FROM embedding_cache WHERE sha = ? AND stamp = ? AND kind = ? AND slot = ?",
                     [.text(sha), .text(stamp), .text(kind), .text(slot)]) { blob = $0.blob(0) }
        guard let blob else { return nil }
        let vector = Vectors.floats(blob)
        return vector.isEmpty ? nil : vector
    }

    func storeEmbedding(sha: String, stamp: String, kind: String, slot: String, vector: [Float]) throws {
        guard !sha.isEmpty, !vector.isEmpty else { return }
        try upsertEmbedding(sha: sha, stamp: stamp, kind: kind, slot: slot, vec: Vectors.half(vector))
    }

    /// Drops cached vectors that belong to other model settings. The stamp just adopted is kept, so switching
    /// budgets and switching back does not embed twice.
    func discardEmbeddingCache(except stamp: String) throws {
        try db.run("DELETE FROM embedding_cache WHERE stamp != ?", [.text(stamp)])
    }

    /// Files that already have vectors and aren't in the cache under `stamp` yet.
    func filesNeedingEmbeddingCache(stamp: String) throws -> [FileRecord] {
        var out: [FileRecord] = []
        try db.query("""
            SELECT \(Self.fileColumns) FROM files AS f
            WHERE (
                EXISTS (SELECT 1 FROM segments s WHERE s.file = f.id AND s.vec IS NOT NULL AND s.kind != 'name')
            )
            AND NOT EXISTS (SELECT 1 FROM embedding_cache c WHERE c.sha = f.sha AND c.stamp = ?)
            """, [.text(stamp)]) { out.append(Self.record($0)) }
        return out
    }

    /// Copies the vectors this file already has into the cache. Sets `sha` only after that succeeds.
    @discardableResult
    func preserveFileEmbeddings(_ file: FileRecord, sha: String, stamp: String, imageBudget: Int) throws -> Int {
        guard !sha.isEmpty else { return 0 }
        struct Row { var kind: String; var slot: String; var vec: Data }
        var rows: [Row] = []
        try db.query("""
            SELECT kind, loc, vec FROM segments WHERE file = ? AND vec IS NOT NULL AND kind != 'name'
            """, [.int(file.id)]) { row in
            guard let kind = row.text(0), let blob = row.blob(2), !blob.isEmpty else { return }
            let loc = row.isNull(1) ? nil : row.double(1)
            rows.append(Row(kind: kind, slot: EmbeddingCache.slot(kind: kind, loc: loc, imageBudget: imageBudget), vec: blob))
        }
        try db.transaction {
            for row in rows {
                try upsertEmbedding(sha: sha, stamp: stamp, kind: row.kind, slot: row.slot, vec: row.vec)
            }
            try setContentSHA(file.id, sha)
        }
        return rows.count
    }

    private func upsertEmbedding(sha: String, stamp: String, kind: String, slot: String, vec: Data) throws {
        try db.run("""
            INSERT INTO embedding_cache(sha, stamp, kind, slot, vec) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(sha, stamp, kind, slot) DO UPDATE SET vec = excluded.vec
            """, [.text(sha), .text(stamp), .text(kind), .text(slot), .blob(vec)])
    }
}
