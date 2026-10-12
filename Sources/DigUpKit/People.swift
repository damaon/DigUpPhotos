import CoreGraphics
import Foundation

/// A person DigUp clustered from face embeddings. `name` is nil until the user names them.
public struct Person: Sendable, Equatable, Identifiable {
    public let id: Int64
    public var name: String?
    /// How many face observations are linked to this person.
    public var faceCount: Int
    /// How many distinct photos contain this person.
    public var photoCount: Int
    /// A face id used as the thumbnail (first face assigned).
    public var exemplarFace: Int64?

    public init(id: Int64, name: String?, faceCount: Int, photoCount: Int, exemplarFace: Int64?) {
        self.id = id
        self.name = name
        self.faceCount = faceCount
        self.photoCount = photoCount
        self.exemplarFace = exemplarFace
    }

    /// What to show in the UI: the given name, or "Person 3".
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return "Person \(id)"
    }
}

/// One detected face on a photo, with its EmbeddingGemma vector and optional person link.
public struct FaceRecord: Sendable {
    public let id: Int64
    public let file: Int64
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double
    public var person: Int64?
}

extension IndexStore {
    /// Cosine similarity at or above this links a new face to an existing person (EmbeddingGemma face crops).
    public static let personMatchThreshold: Float = 0.72

    // MARK: Schema (people + faces)

    static let peopleTablesSQL = """
        CREATE TABLE IF NOT EXISTS people(
            id INTEGER PRIMARY KEY,
            name TEXT,
            exemplar INTEGER
        );
        CREATE TABLE IF NOT EXISTS faces(
            id INTEGER PRIMARY KEY,
            file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            x REAL NOT NULL,
            y REAL NOT NULL,
            w REAL NOT NULL,
            h REAL NOT NULL,
            person INTEGER REFERENCES people(id) ON DELETE SET NULL,
            vec BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS faces_file ON faces(file);
        CREATE INDEX IF NOT EXISTS faces_person ON faces(person);
        """

    // MARK: Faces

    /// Drops faces for a file (re-index). People left with no faces are removed unless named.
    public func deleteFaces(of file: Int64) throws {
        var people: [Int64] = []
        try db.query("SELECT DISTINCT person FROM faces WHERE file = ? AND person IS NOT NULL", [.int(file)]) {
            people.append($0.int(0))
        }
        try db.run("DELETE FROM faces WHERE file = ?", [.int(file)])
        for id in people { try prunePersonIfEmpty(id) }
    }

    /// Inserts a face and assigns it to the nearest person (or creates one). Returns the face id.
    @discardableResult
    public func addFace(file: Int64, box: CGRect, vector: [Float]) throws -> Int64 {
        let person = try matchOrCreatePerson(vector: vector)
        try db.run("""
            INSERT INTO faces(file, x, y, w, h, person, vec) VALUES(?, ?, ?, ?, ?, ?, ?)
            """, [.int(file), .double(box.origin.x), .double(box.origin.y), .double(box.width), .double(box.height),
                  .int(person), .blob(Vectors.half(vector))])
        let face = db.lastInsertID
        try db.run("""
            UPDATE people SET exemplar = COALESCE(exemplar, ?) WHERE id = ?
            """, [.int(face), .int(person)])
        return face
    }

    /// File ids that contain every listed person (AND). Empty `people` means no filter.
    public func filesContaining(allPeople people: Set<Int64>) throws -> Set<Int64>? {
        guard !people.isEmpty else { return nil }
        // Each selected person must appear on the photo: count distinct people per file == selection size.
        let list = people.map(String.init).joined(separator: ",")
        var files = Set<Int64>()
        try db.query("""
            SELECT file FROM faces
            WHERE person IN (\(list))
            GROUP BY file
            HAVING COUNT(DISTINCT person) = \(people.count)
            """) { files.insert($0.int(0)) }
        return files
    }

    // MARK: People

    public func people() throws -> [Person] {
        var out: [Person] = []
        try db.query("""
            SELECT p.id, p.name, p.exemplar,
                   (SELECT COUNT(*) FROM faces f WHERE f.person = p.id),
                   (SELECT COUNT(DISTINCT file) FROM faces f WHERE f.person = p.id)
            FROM people p
            ORDER BY (p.name IS NULL), lower(COALESCE(p.name, '')), p.id
            """) { row in
            out.append(Person(id: row.int(0), name: row.text(1), faceCount: Int(row.int(3)),
                              photoCount: Int(row.int(4)), exemplarFace: row.isNull(2) ? nil : row.int(2)))
        }
        return out
    }

    public func renamePerson(_ id: Int64, to name: String?) throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try db.run("UPDATE people SET name = ? WHERE id = ?",
                   [trimmed?.isEmpty == false ? .text(trimmed!) : .null, .int(id)])
    }

    /// Path of the photo that holds the exemplar face, for a thumbnail.
    public func exemplarPhotoPath(ofPerson id: Int64) throws -> String? {
        var path: String?
        try db.query("""
            SELECT files.path FROM people
            JOIN faces ON faces.id = people.exemplar
            JOIN files ON files.id = faces.file
            WHERE people.id = ?
            """, [.int(id)]) { path = $0.text(0) }
        return path
    }

    /// Merges `other` into `keeper`: all faces move, then `other` is deleted. Keeps `keeper`'s name.
    public func mergePeople(keeper: Int64, other: Int64) throws {
        guard keeper != other else { return }
        try db.transaction {
            try db.run("UPDATE faces SET person = ? WHERE person = ?", [.int(keeper), .int(other)])
            try db.run("UPDATE people SET exemplar = COALESCE(exemplar, (SELECT exemplar FROM people WHERE id = ?)) WHERE id = ?",
                       [.int(other), .int(keeper)])
            try db.run("DELETE FROM people WHERE id = ?", [.int(other)])
        }
    }

    // MARK: Matching

    /// Nearest person by exemplar face cosine, or a new person when nothing is close enough.
    private func matchOrCreatePerson(vector: [Float]) throws -> Int64 {
        var bestID: Int64?
        var bestScore: Float = -1
        try db.query("""
            SELECT p.id, f.vec FROM people p
            JOIN faces f ON f.id = p.exemplar
            WHERE f.vec IS NOT NULL
            """) { row in
            guard let blob = row.blob(1), blob.count == Vectors.dimension * 2 else { return }
            let score = cosine(vector, half: blob)
            if score > bestScore {
                bestScore = score
                bestID = row.int(0)
            }
        }
        if let bestID, bestScore >= Self.personMatchThreshold { return bestID }
        try db.run("INSERT INTO people(name) VALUES(NULL)")
        return db.lastInsertID
    }

    private func prunePersonIfEmpty(_ id: Int64) throws {
        var faces = 0
        var named: String?
        try db.query("SELECT COUNT(*), (SELECT name FROM people WHERE id = ?) FROM faces WHERE person = ?",
                     [.int(id), .int(id)]) {
            faces = Int($0.int(0))
            named = $0.text(1)
        }
        // Keep named people even with zero faces (user may re-index); drop anonymous empties.
        if faces == 0, named == nil {
            try db.run("DELETE FROM people WHERE id = ?", [.int(id)])
        }
    }

    /// Cosine of a float32 query against a float16 blob (already L2-normalized by the model).
    private func cosine(_ query: [Float], half: Data) -> Float {
        guard query.count == Vectors.dimension, half.count == Vectors.dimension * 2 else { return -1 }
        return half.withUnsafeBytes { raw -> Float in
            guard let base = raw.bindMemory(to: Float16.self).baseAddress else { return -1 }
            var sum: Float = 0
            for i in 0..<Vectors.dimension { sum += query[i] * Float(base[i]) }
            return sum
        }
    }
}
