import Foundation

/// A person DigUp clustered from face embeddings. `name` is nil until the user names them.
public struct Person: Sendable, Equatable, Identifiable {
    public let id: Int64
    public var name: String?
    /// How many face observations are linked to this person.
    public var faceCount: Int
    /// How many distinct photos contain this person.
    public var photoCount: Int
    /// The face shown as the thumbnail: the one most like the rest of them.
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

    /// Most photos first (then most faces), for picking whom to merge: the ones worth merging are the big ones.
    public static func byPhotos(_ people: [Person]) -> [Person] {
        people.sorted {
            ($0.photoCount, $0.faceCount, -$0.id) > ($1.photoCount, $1.faceCount, -$1.id)
        }
    }
}

/// People as they were before a merge (`IndexStore.peopleSnapshot`), to undo it with `restorePeople`.
public struct PeopleSnapshot: Sendable, Equatable {
    struct Row: Sendable, Equatable {
        var id: Int64
        var name: String?
        var exemplar: Int64?
        var locked: Bool
    }

    struct Face: Sendable, Equatable {
        var id: Int64
        var person: Int64?
        var pinned: Bool
    }

    var people: [Row] = []
    var faces: [Face] = []
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

/// One detected face on a photo, with its identity vector (`FaceIdentity`) and optional person link.
public struct FaceRecord: Sendable {
    public let id: Int64
    public let file: Int64
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double
    public var person: Int64?
}

/// What indexing needs to put a new face with a person without reading every face again: the average face and each
/// person's sum of centered faces (`FaceClustering`). Valid while the `people_gen` it was built at is current.
final class FaceAssigner {
    let generation: String
    let mean: [Float]
    var sums: [Int64: [Float]]

    init(generation: String, mean: [Float], sums: [Int64: [Float]]) {
        self.generation = generation
        self.mean = mean
        self.sums = sums
    }

    /// The person whose centroid is closest to `vector` (and close enough), leaving out `excluded`.
    func match(_ vector: [Float], excluding excluded: Set<Int64>) -> Int64? {
        let face = FaceClustering.centered(vector, mean: mean)
        var best: Int64?
        var bestScore = FaceClustering.seedThreshold
        for (person, sum) in sums where !excluded.contains(person) {
            let centroid = FaceClustering.normalized(sum)
            var score: Float = 0
            for i in 0..<face.count { score += face[i] * centroid[i] }
            if score >= bestScore {
                best = person
                bestScore = score
            }
        }
        return best
    }

    func add(_ vector: [Float], to person: Int64) {
        let face = FaceClustering.centered(vector, mean: mean)
        var sum = sums[person] ?? [Float](repeating: 0, count: face.count)
        for i in 0..<face.count { sum[i] += face[i] }
        sums[person] = sum
    }
}

extension IndexStore {
    /// Below this many faces the average face says little, so new faces wait for `clusterPeople` rather than being
    /// matched one by one.
    static let facesForMatching = 50

    // MARK: Schema (people + faces)

    static let peopleTablesSQL = """
        CREATE TABLE IF NOT EXISTS people(
            id INTEGER PRIMARY KEY,
            name TEXT,
            exemplar INTEGER,
            locked INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS faces(
            id INTEGER PRIMARY KEY,
            file INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            x REAL NOT NULL,
            y REAL NOT NULL,
            w REAL NOT NULL,
            h REAL NOT NULL,
            person INTEGER REFERENCES people(id) ON DELETE SET NULL,
            vec BLOB NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0   -- the user saw this face as this person (named or merged them)
        );
        -- Suggestions the user turned down: not the same person (`dismissSuggestion`).
        CREATE TABLE IF NOT EXISTS people_apart(
            a INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
            b INTEGER NOT NULL REFERENCES people(id) ON DELETE CASCADE,
            PRIMARY KEY (a, b)
        );
        CREATE INDEX IF NOT EXISTS faces_file ON faces(file);
        CREATE INDEX IF NOT EXISTS faces_person ON faces(person);
        """

    // MARK: Faces

    /// Drops faces for a file (it can't be read any more). People left with no faces are removed unless the user named
    /// or merged them.
    public func deleteFaces(of file: Int64) throws {
        var people: Set<Int64> = []
        try db.query("SELECT DISTINCT person FROM faces WHERE file = ? AND person IS NOT NULL", [.int(file)]) {
            people.insert($0.int(0))
        }
        try db.run("DELETE FROM faces WHERE file = ?", [.int(file)])
        let removed = db.changes
        guard removed > 0 else { return }
        try countFaceChanges(removed)
        try tidy(people)
        try bumpPeopleGeneration()
    }

    /// The faces found on `file` this time, in place of the ones found before. A face where one was before stays with
    /// that face's person (reading the photo again keeps the names and merges); a new one goes to the closest person,
    /// or waits for `clusterPeople`.
    public func replaceFaces(of file: Int64, with faces: [(box: CGRect, vector: [Float])]) throws {
        var old: [(box: CGRect, person: Int64?, pinned: Bool)] = []
        try db.query("SELECT x, y, w, h, person, pinned FROM faces WHERE file = ?", [.int(file)]) {
            old.append((CGRect(x: $0.double(0), y: $0.double(1), width: $0.double(2), height: $0.double(3)),
                        $0.isNull(4) ? nil : $0.int(4), $0.int(5) != 0))
        }
        if !old.isEmpty { try db.run("DELETE FROM faces WHERE file = ?", [.int(file)]) }
        let assigner = faces.isEmpty ? nil : try faceAssigner()
        var onPhoto: Set<Int64> = []
        var claimed = Set<Int>()
        for face in faces {
            var person: Int64?
            var pinned = false
            if let match = old.indices.filter({ !claimed.contains($0) && old[$0].person != nil })
                .max(by: { Self.overlap(old[$0].box, face.box) < Self.overlap(old[$1].box, face.box) }),
               Self.overlap(old[match].box, face.box) >= 0.5 {
                claimed.insert(match)
                person = old[match].person
                pinned = old[match].pinned
            } else {
                person = assigner?.match(face.vector, excluding: onPhoto)
            }
            if let known = person, onPhoto.contains(known) { (person, pinned) = (nil, false) }
            // The app can merge people at any moment: a person that's gone leaves the face for `clusterPeople`.
            try db.run("""
                INSERT INTO faces(file, x, y, w, h, person, vec, pinned)
                VALUES(?, ?, ?, ?, ?, (SELECT id FROM people WHERE id = ?), ?, ?)
                """, [.int(file), .double(face.box.origin.x), .double(face.box.origin.y), .double(face.box.width),
                      .double(face.box.height), person.map { .int($0) } ?? .null, .blob(Vectors.half(face.vector)),
                      .int(pinned ? 1 : 0)])
            if let person {
                onPhoto.insert(person)
                assigner?.add(face.vector, to: person)
                try db.run("UPDATE people SET exemplar = COALESCE(exemplar, ?) WHERE id = ?",
                           [.int(db.lastInsertID), .int(person)])
            }
        }
        try tidy(Set(old.compactMap(\.person)).subtracting(onPhoto))
        if !faces.isEmpty || !old.isEmpty { try countFaceChanges(max(faces.count, old.count)) }
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

    /// Named people first, then the rest by how many photos they're on.
    public func people() throws -> [Person] {
        var out: [Person] = []
        try db.query("""
            SELECT p.id, p.name, p.exemplar,
                   (SELECT COUNT(*) FROM faces f WHERE f.person = p.id),
                   (SELECT COUNT(DISTINCT file) FROM faces f WHERE f.person = p.id) AS photos
            FROM people p
            ORDER BY (p.name IS NULL), lower(COALESCE(p.name, '')), photos DESC, p.id
            """) { row in
            out.append(Person(id: row.int(0), name: row.text(1), faceCount: Int(row.int(3)),
                              photoCount: Int(row.int(4)), exemplarFace: row.isNull(2) ? nil : row.int(2)))
        }
        return out
    }

    /// Names a person. The face on their thumbnail stays theirs, and they stay apart from other named people, when
    /// people are grouped again.
    public func renamePerson(_ id: Int64, to name: String?) throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try db.transaction {
            try db.run("UPDATE people SET name = ?, locked = 1 WHERE id = ?",
                       [trimmed?.isEmpty == false ? .text(trimmed!) : .null, .int(id)])
            try pinShownFace(of: id)
            try bumpPeopleGeneration()
        }
    }

    /// The face on the person's thumbnail (`exemplarFace`) is one the user has seen as them: grouping keeps it theirs.
    /// Only such faces are held: every face of the person would hold whatever grouping once put with them, for good.
    private func pinShownFace(of id: Int64) throws {
        try db.run("""
            UPDATE faces SET pinned = 1 WHERE id = (
                SELECT id FROM faces WHERE person = ?
                ORDER BY id = (SELECT exemplar FROM people WHERE id = ?) DESC, id LIMIT 1)
            """, [.int(id), .int(id)])
    }

    /// Path of the photo that holds the exemplar face, for a thumbnail.
    public func exemplarPhotoPath(ofPerson id: Int64) throws -> String? {
        try exemplarFace(ofPerson: id)?.path
    }

    /// The exemplar face: its photo and where on it (Vision's box), for a thumbnail of just the face.
    public func exemplarFace(ofPerson id: Int64) throws -> ExemplarFace? {
        var face: ExemplarFace?
        try db.query("""
            SELECT files.path, faces.x, faces.y, faces.w, faces.h FROM faces
            JOIN files ON files.id = faces.file
            WHERE faces.person = ?
            ORDER BY faces.id = (SELECT exemplar FROM people WHERE id = ?) DESC, faces.id
            LIMIT 1
            """, [.int(id), .int(id)]) { row in
            face = row.text(0).map {
                ExemplarFace(path: $0, box: CGRect(x: row.double(1), y: row.double(2), width: row.double(3),
                                                   height: row.double(4)))
            }
        }
        return face
    }

    /// People who might be one person, to offer merging: each person's closest other by the average centered cosine
    /// between their faces (`FaceClustering`), when at least `minimum`. Each pair once, closest first. Leaves out two
    /// people on one photo, two the user gave names, and pairs turned down.
    ///
    /// Grouping joins people at 0.22, so a pair offered here is one grouping didn't join.
    public func similarPeople(minimum: Float = 0.08, limit: Int = 24) throws
        -> [(first: Int64, second: Int64, score: Float)] {
        var vectors: [[Float]] = []
        var owners: [Int64] = []
        var named = Set<Int64>()
        try db.query("SELECT f.person, f.vec, p.name FROM faces f JOIN people p ON p.id = f.person") { row in
            guard let blob = row.blob(1), let vector = Self.floats(half: blob) else { return }
            vectors.append(vector)
            owners.append(row.int(0))
            if row.text(2)?.isEmpty == false { named.insert(row.int(0)) }
        }
        guard !vectors.isEmpty else { return [] }
        let average = FaceClustering.mean(vectors)
        var sums: [Int64: [Float]] = [:]
        var counts: [Int64: Float] = [:]
        for (vector, owner) in zip(vectors, owners) {
            let face = FaceClustering.centered(vector, mean: average)
            var sum = sums[owner] ?? [Float](repeating: 0, count: face.count)
            for i in 0..<face.count { sum[i] += face[i] }
            sums[owner] = sum
            counts[owner, default: 0] += 1
        }
        var apart = Set<[Int64]>()
        try db.query("""
            SELECT DISTINCT a.person, b.person FROM faces a JOIN faces b ON a.file = b.file AND a.person < b.person
            """) { apart.insert([$0.int(0), $0.int(1)]) }
        try db.query("SELECT a, b FROM people_apart") { apart.insert([$0.int(0), $0.int(1)]) }
        // Two names are two people. A merged person without one can still be the same as another.
        for a in named { for b in named where a < b { apart.insert([a, b]) } }
        // The dot product of two people's average faces is the average cosine between their faces.
        let rows = sums.map { person, sum in (id: person, vector: sum.map { $0 / counts[person]! }) }
        return Self.similarPairs(rows, minimum: minimum, limit: limit, apart: apart)
    }

    /// Each row's closest other row by dot product, when at least `minimum` and not `apart` ([smaller, larger] ids).
    /// Each pair once, closest first.
    static func similarPairs(_ rows: [(id: Int64, vector: [Float])], minimum: Float = 0.5, limit: Int = 24,
                             apart: Set<[Int64]> = []) -> [(first: Int64, second: Int64, score: Float)] {
        var nearest: [Int64: (other: Int64, score: Float)] = [:]
        for index in rows.indices {
            for other in (index + 1)..<rows.count {
                let (left, right) = (rows[index].id, rows[other].id)
                guard !apart.contains([min(left, right), max(left, right)]) else { continue }
                var score: Float = 0
                for i in rows[index].vector.indices { score += rows[index].vector[i] * rows[other].vector[i] }
                guard score >= minimum else { continue }
                if nearest[left] == nil || score > nearest[left]!.score { nearest[left] = (right, score) }
                if nearest[right] == nil || score > nearest[right]!.score { nearest[right] = (left, score) }
            }
        }
        var seen = Set<[Int64]>()
        var pairs: [(first: Int64, second: Int64, score: Float)] = []
        for (id, link) in nearest {
            let (first, second) = (min(id, link.other), max(id, link.other))
            guard seen.insert([first, second]).inserted else { continue }
            pairs.append((first, second, link.score))
        }
        pairs.sort { $0.score == $1.score ? $0.first < $1.first : $0.score > $1.score }
        return Array(pairs.prefix(limit))
    }

    /// Merges `other` into `keeper`: all faces move, then `other` is deleted. Keeps `keeper`'s name, or takes `other`'s
    /// when `keeper` has none. The two faces the user saw stay one person when people are grouped again, each drawing
    /// the faces like it.
    /// Returns how people were before, for `restorePeople` (Undo).
    @discardableResult
    public func mergePeople(keeper: Int64, other: Int64) throws -> PeopleSnapshot {
        let before = try peopleSnapshot()
        guard keeper != other else { return before }
        try db.transaction {
            try pinShownFace(of: keeper)
            try pinShownFace(of: other)
            try db.run("UPDATE faces SET person = ? WHERE person = ?", [.int(keeper), .int(other)])
            try db.run("""
                UPDATE people SET
                    name = COALESCE(name, (SELECT name FROM people WHERE id = ?)),
                    exemplar = COALESCE(exemplar, (SELECT exemplar FROM people WHERE id = ?)),
                    locked = 1
                WHERE id = ?
                """, [.int(other), .int(other), .int(keeper)])
            try db.run("DELETE FROM people WHERE id = ?", [.int(other)])
            try bumpPeopleGeneration()
        }
        // Faces like either look join them now, not at the next grouping (under a second for ~1,500 faces).
        try regroupPeople()
        return before
    }

    /// Who every face was and every person's name, thumbnail and lock: what a merge, or undoing every merge, changes.
    public func peopleSnapshot() throws -> PeopleSnapshot {
        var snapshot = PeopleSnapshot()
        try db.query("SELECT id, name, exemplar, locked FROM people ORDER BY id") {
            snapshot.people.append(.init(id: $0.int(0), name: $0.text(1), exemplar: $0.isNull(2) ? nil : $0.int(2),
                                         locked: $0.int(3) != 0))
        }
        try db.query("SELECT id, person, pinned FROM faces ORDER BY id") {
            snapshot.faces.append(.init(id: $0.int(0), person: $0.isNull(1) ? nil : $0.int(1), pinned: $0.int(2) != 0))
        }
        return snapshot
    }

    /// Puts people back as `snapshot` had them (Undo). Faces found since keep their person; people made since that
    /// have no faces left go.
    public func restorePeople(_ snapshot: PeopleSnapshot) throws {
        try db.transaction {
            for person in snapshot.people {
                try db.run("""
                    INSERT INTO people(id, name, exemplar, locked) VALUES(?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name, exemplar = excluded.exemplar,
                                                  locked = excluded.locked
                    """, [.int(person.id), person.name.map { .text($0) } ?? .null,
                          person.exemplar.map { .int($0) } ?? .null, .int(person.locked ? 1 : 0)])
            }
            for face in snapshot.faces {
                try db.run("UPDATE faces SET person = ?, pinned = ? WHERE id = ?",
                           [face.person.map { .int($0) } ?? .null, .int(face.pinned ? 1 : 0), .int(face.id)])
            }
            let kept = Set(snapshot.people.map(\.id))
            var empty: [Int64] = []
            try db.query("SELECT id FROM people p WHERE NOT EXISTS (SELECT 1 FROM faces f WHERE f.person = p.id)") {
                empty.append($0.int(0))
            }
            for id in empty where !kept.contains(id) { try db.run("DELETE FROM people WHERE id = ?", [.int(id)]) }
            try bumpPeopleGeneration()
        }
    }

    /// The user says these two aren't one person: they're not suggested again.
    public func dismissSuggestion(_ first: Int64, _ second: Int64) throws {
        guard first != second else { return }
        try db.run("INSERT OR IGNORE INTO people_apart(a, b) VALUES(?, ?)",
                   [.int(min(first, second)), .int(max(first, second))])
    }

    public func dismissedSuggestionCount() throws -> Int {
        var count = 0
        try db.query("SELECT COUNT(*) FROM people_apart") { count = Int($0.int(0)) }
        return count
    }

    /// Every turned-down suggestion is offered again.
    public func restoreSuggestions() throws {
        try db.run("DELETE FROM people_apart")
    }

    /// Takes back every merge: people are grouped again as if the user had only named them (a named person keeps the
    /// face on their thumbnail). Names stay.
    /// Returns how people were before, for `restorePeople`.
    @discardableResult
    public func undoMerges() throws -> PeopleSnapshot {
        let before = try peopleSnapshot()
        try db.transaction {
            try db.execute("""
                UPDATE people SET locked = 0 WHERE name IS NULL;
                UPDATE faces SET pinned = 0;
                """)
            var named: [Int64] = []
            try db.query("SELECT id FROM people WHERE locked = 1") { named.append($0.int(0)) }
            for id in named { try pinShownFace(of: id) }
        }
        try regroupPeople()
        return before
    }

    // MARK: Grouping

    /// Groups every face into people again (`regroupPeople`) when a quarter of them changed since the last time (faces
    /// added, or read again), or with `force`, when any did. Returns whether it grouped.
    @discardableResult
    public func clusterPeople(force: Bool = false) throws -> Bool {
        var total = 0
        var waiting = 0
        try db.query("SELECT COUNT(*), COUNT(*) - COUNT(person) FROM faces") {
            total = Int($0.int(0))
            waiting = Int($0.int(1))
        }
        let changed = Int(try meta("faces_changed") ?? "") ?? 0
        let due = force ? (changed > 0 || waiting > 0) : changed >= max(20, total / 4)
        guard due else { return false }
        try regroupPeople()
        return true
    }

    /// Groups every face into people again (`FaceClustering`). Person ids stay where most of their faces stay, so names
    /// and search filters carry over; people the user named or merged keep the faces they saw (`pinShownFace`), and
    /// whatever is like those. Two of those people become one when their faces are close, unless both have names or
    /// the user turned the pair down: merges made by hand, one look at a time, come together (one man was four merged
    /// people, 2026-10-30). The one with a name stays.
    public func regroupPeople() throws {
        try db.transaction {
            var named = Set<Int64>()
            try db.query("SELECT id FROM people WHERE name IS NOT NULL AND name != ''") { named.insert($0.int(0)) }
            var turnedDown = Set<[Int64]>()
            try db.query("SELECT a, b FROM people_apart") { turnedDown.insert([$0.int(0), $0.int(1)]) }
            var ids: [Int64] = []
            var current: [Int64?] = []
            var faces: [FaceClustering.Face] = []
            try db.query("""
                SELECT f.id, f.file, f.person, f.vec, p.locked AND f.pinned FROM faces f
                LEFT JOIN people p ON p.id = f.person
                ORDER BY f.id
                """) { row in
                guard let blob = row.blob(3), let vector = Self.floats(half: blob) else { return }
                let person: Int64? = row.isNull(2) ? nil : row.int(2)
                ids.append(row.int(0))
                current.append(person)
                faces.append(FaceClustering.Face(file: row.int(1), vector: vector,
                                                 pinned: row.int(4) != 0 ? person : nil))
            }
            let groups = FaceClustering.cluster(faces) { a, b in
                (named.contains(a) && named.contains(b)) || turnedDown.contains([min(a, b), max(a, b)])
            }
            let count = (groups.max() ?? -1) + 1

            // A pinned group is its person's (the named one, else the one with most of its pinned faces). Every other
            // group keeps the person most of its faces had, unless another group holds more of that person.
            var personOf = [Int64?](repeating: nil, count: count)
            var pinnedIn: [Int: [Int64: Int]] = [:]
            for (index, face) in faces.enumerated() {
                if let person = face.pinned { pinnedIn[groups[index], default: [:]][person, default: 0] += 1 }
            }
            for (group, people) in pinnedIn {
                personOf[group] = people.max {
                    (named.contains($0.key) ? 1 : 0, $0.value, -$0.key) < (named.contains($1.key) ? 1 : 0, $1.value, -$1.key)
                }?.key
            }
            var overlap: [Int: [Int64: Int]] = [:]
            for (index, person) in current.enumerated() {
                if let person, personOf[groups[index]] == nil { overlap[groups[index], default: [:]][person, default: 0] += 1 }
            }
            var used = Set(personOf.compactMap { $0 })
            let pairs = overlap.flatMap { group, people in people.map { (group: group, person: $0.key, faces: $0.value) } }
                .sorted { ($0.faces, $1.group) > ($1.faces, $0.group) }
            for pair in pairs where personOf[pair.group] == nil && !used.contains(pair.person) {
                personOf[pair.group] = pair.person
                used.insert(pair.person)
            }
            for group in 0..<count where personOf[group] == nil {
                try db.run("INSERT INTO people(name) VALUES(NULL)")
                personOf[group] = db.lastInsertID
            }

            for (index, id) in ids.enumerated() where current[index] != personOf[groups[index]] {
                try db.run("UPDATE faces SET person = ? WHERE id = ?", [.int(personOf[groups[index]]!), .int(id)])
            }
            // The thumbnail: the face nearest its group's average.
            let average = FaceClustering.mean(faces.map(\.vector))
            let centered = faces.map { FaceClustering.centered($0.vector, mean: average) }
            var sums = [[Float]](repeating: [Float](repeating: 0, count: FaceIdentity.dimension), count: count)
            for (index, vector) in centered.enumerated() {
                for i in 0..<vector.count { sums[groups[index]][i] += vector[i] }
            }
            var exemplar = [(face: Int64, score: Float)](repeating: (-1, -.infinity), count: count)
            for (index, vector) in centered.enumerated() {
                let group = groups[index]
                var score: Float = 0
                for i in 0..<vector.count { score += vector[i] * sums[group][i] }
                if score > exemplar[group].score { exemplar[group] = (ids[index], score) }
            }
            for group in 0..<count {
                try db.run("UPDATE people SET exemplar = ? WHERE id = ?",
                           [.int(exemplar[group].face), .int(personOf[group]!)])
            }
            // Left with no faces: grouped into someone else. A name stays, faces or not.
            try db.run("""
                DELETE FROM people WHERE (name IS NULL OR name = '')
                AND NOT EXISTS (SELECT 1 FROM faces WHERE faces.person = people.id)
                """)
            try setMeta("faces_changed", nil)
            try bumpPeopleGeneration()
        }
    }

    // MARK: Matching

    /// The cached `FaceAssigner`, built again when people changed (here or in another process), or nil while there
    /// are too few faces to match against.
    private func faceAssigner() throws -> FaceAssigner? {
        let generation = try meta("people_gen") ?? "0"
        if let cached = faceAssignerCache, cached.generation == generation { return cached }
        var vectors: [[Float]] = []
        var people: [Int64?] = []
        try db.query("SELECT person, vec FROM faces") { row in
            guard let blob = row.blob(1), let vector = Self.floats(half: blob) else { return }
            vectors.append(vector)
            people.append(row.isNull(0) ? nil : row.int(0))
        }
        guard vectors.count >= Self.facesForMatching else {
            faceAssignerCache = nil
            return nil
        }
        let assigner = FaceAssigner(generation: generation, mean: FaceClustering.mean(vectors), sums: [:])
        for (vector, person) in zip(vectors, people) {
            if let person { assigner.add(vector, to: person) }
        }
        faceAssignerCache = assigner
        return assigner
    }

    /// `count` faces were added, replaced or removed since people were last grouped.
    private func countFaceChanges(_ count: Int) throws {
        try db.run("""
            INSERT INTO meta(key, value) VALUES('faces_changed', ?)
            ON CONFLICT(key) DO UPDATE SET value = CAST(value AS INTEGER) + excluded.value
            """, [.text("\(count)")])
    }

    /// People changed: a `FaceAssigner` built before is out of date.
    private func bumpPeopleGeneration() throws {
        try db.run("""
            INSERT INTO meta(key, value) VALUES('people_gen', '1')
            ON CONFLICT(key) DO UPDATE SET value = CAST(value AS INTEGER) + 1
            """)
    }

    /// Removes the people among `people` that have no faces left, unless the user named or merged them; points the
    /// others' thumbnails at a face they still have.
    private func tidy(_ people: Set<Int64>) throws {
        for id in people {
            try db.run("""
                DELETE FROM people WHERE id = ? AND name IS NULL AND locked = 0
                AND NOT EXISTS (SELECT 1 FROM faces WHERE person = ?)
                """, [.int(id), .int(id)])
            try db.run("""
                UPDATE people SET exemplar = (SELECT MIN(id) FROM faces WHERE person = ?)
                WHERE id = ? AND NOT EXISTS (SELECT 1 FROM faces WHERE faces.id = people.exemplar)
                """, [.int(id), .int(id)])
        }
    }

    /// Intersection over union of two boxes.
    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let shared = inter.width * inter.height
        return shared / (a.width * a.height + b.width * b.height - shared)
    }

    /// A stored float16 face vector as float32; nil for one from an older face model (EmbeddingGemma's, before
    /// `FaceDetector.version` 3), which waits for its photo to be read again.
    static func floats(half: Data) -> [Float]? {
        guard half.count == FaceIdentity.dimension * 2 else { return nil }
        return half.withUnsafeBytes { raw in raw.bindMemory(to: Float16.self).map(Float.init) }
    }
}
