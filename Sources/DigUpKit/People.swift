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

/// A person's exemplar face, for a circular thumbnail.
public struct ExemplarFace: Sendable, Equatable {
    public var path: String
    /// Normalized Vision box, origin bottom-left.
    public var box: CGRect

    public init(path: String, box: CGRect) {
        self.path = path
        self.box = box
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

    /// The face embeddings a person is recognized by. One until two people are merged, then both.
    static let personAnchorsSQL = """
        CREATE TABLE IF NOT EXISTS person_anchors(
            person INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
            face INTEGER NOT NULL REFERENCES faces(id) ON DELETE CASCADE,
            PRIMARY KEY (person, face)
        );
        """

    // MARK: Faces

    /// Drops faces for a file (re-index). People left with no faces are removed unless named.
    /// Schema 1–5 indexes have no `faces` table yet; keyword migration requeues files before people are added.
    public func deleteFaces(of file: Int64) throws {
        var ready = false
        try db.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'faces'") { _ in ready = true }
        guard ready else { return }
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

    /// The exemplar face: the photo path and the normalized Vision box (origin bottom-left).
    public func exemplarFace(ofPerson id: Int64) throws -> ExemplarFace? {
        var face: ExemplarFace?
        try db.query("""
            SELECT files.path, faces.x, faces.y, faces.w, faces.h FROM people
            JOIN faces ON faces.id = people.exemplar
            JOIN files ON files.id = faces.file
            WHERE people.id = ?
            """, [.int(id)]) { row in
            guard let path = row.text(0) else { return }
            face = ExemplarFace(path: path, box: CGRect(x: row.double(1), y: row.double(2),
                                                        width: row.double(3), height: row.double(4)))
        }
        return face
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

    /// Merges `other` into `keeper`. Both exemplar embeddings stay, and a photo matches this person when its face
    /// is close to either one. `keeper`'s name is kept.
    public func mergePeople(keeper: Int64, other: Int64) throws {
        guard keeper != other else { return }
        try db.transaction {
            try rememberAnchor(of: keeper)
            try rememberAnchor(of: other)
            try db.run("""
                INSERT OR IGNORE INTO person_anchors(person, face)
                SELECT ?, face FROM person_anchors WHERE person = ?
                """, [.int(keeper), .int(other)])
            try db.run("DELETE FROM person_anchors WHERE person = ?", [.int(other)])
            try db.run("UPDATE faces SET person = ? WHERE person = ?", [.int(keeper), .int(other)])
            try db.run("""
                UPDATE people SET exemplar = COALESCE(exemplar, (SELECT exemplar FROM people WHERE id = ?)) WHERE id = ?
                """, [.int(other), .int(keeper)])
            try db.run("DELETE FROM people WHERE id = ?", [.int(other)])
        }
    }

    /// The person's exemplar becomes an identity embedding, if it is not one already.
    private func rememberAnchor(of person: Int64) throws {
        try db.run("""
            INSERT OR IGNORE INTO person_anchors(person, face)
            SELECT id, exemplar FROM people WHERE id = ? AND exemplar IS NOT NULL
            """, [.int(person)])
    }

    // MARK: Matching

    /// Nearest person by identity embeddings, or a new person when nothing is close enough.
    /// A merged person has both embeddings: a face matches when it is close to either one.
    private func matchOrCreatePerson(vector: [Float]) throws -> Int64 {
        var bestID: Int64?
        var bestScore: Float = -1
        var anchored = Set<Int64>()
        func consider(_ person: Int64, _ blob: Data?) {
            guard let blob else { return }
            let score = cosine(vector, half: blob)
            if score > bestScore {
                bestScore = score
                bestID = person
            }
        }
        try db.query("""
            SELECT a.person, f.vec FROM person_anchors a
            JOIN faces f ON f.id = a.face
            WHERE f.vec IS NOT NULL
            """) { row in
            anchored.insert(row.int(0))
            consider(row.int(0), row.blob(1))
        }
        try db.query("""
            SELECT p.id, f.vec FROM people p
            JOIN faces f ON f.id = p.exemplar
            WHERE f.vec IS NOT NULL
            """) { row in
            let person = row.int(0)
            guard !anchored.contains(person) else { return }
            consider(person, row.blob(1))
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
