import CoreGraphics
import Foundation
import Testing
@testable import DigUpKit

@Suite struct PeopleTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpPeople-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // MARK: Grouping (no database)

    /// Faces as EmbeddingGemma gives them: everyone shares most of the vector (raw cosine ~0.8 between anyone), so
    /// only what's left after the average face tells people apart.
    @Test func groupsPeopleThatOnlyDifferAfterTheAverageFace() {
        var faces = Faces()
        let people = (0..<4).flatMap { person in (0..<12).map { _ in faces.add(person: person) } }
        let groups = FaceClustering.cluster(faces.list)
        #expect(Set(groups).count == 4)
        for person in 0..<4 {
            let mine = people.indices.filter { people[$0] == person }.map { groups[$0] }
            #expect(Set(mine).count == 1, "person \(person) is split: \(mine)")
        }
        // Raw cosine between two different people stays high: a fixed threshold on it couldn't do this.
        #expect(Faces.dot(faces.list[0].vector, faces.list[12].vector) > 0.7)
    }

    @Test func groupingDoesNotDependOnOrder() {
        var faces = Faces()
        for person in 0..<3 { for _ in 0..<10 { _ = faces.add(person: person) } }
        let order = Array(faces.list.indices).shuffled(using: &faces.random)
        let straight = FaceClustering.cluster(faces.list)
        let shuffled = FaceClustering.cluster(order.map { faces.list[$0] })
        for i in order.indices {
            for j in order.indices where i < j {
                #expect((straight[order[i]] == straight[order[j]]) == (shuffled[i] == shuffled[j]))
            }
        }
    }

    @Test func twoFacesOnOnePhotoAreTwoPeople() {
        var faces = Faces()
        for _ in 0..<10 { _ = faces.add(person: 0) }
        for person in 1..<4 { for _ in 0..<10 { _ = faces.add(person: person) } }
        _ = faces.add(person: 0, file: 500)
        _ = faces.add(person: 0, file: 500)   // a mirror, a poster: the same face twice on one photo
        let groups = FaceClustering.cluster(faces.list)
        #expect(groups[40] != groups[41])
        #expect(groups[40] == groups[0] || groups[41] == groups[0])
    }

    @Test func pinnedPeopleStayTogetherAndApart() {
        var faces = Faces()
        // The user said these two look-alike groups are different people, and that person 2's odd face is theirs.
        for _ in 0..<6 { _ = faces.add(person: 0, pinned: 100) }
        for _ in 0..<6 { _ = faces.add(person: 0, pinned: 200) }
        for _ in 0..<6 { _ = faces.add(person: 1, pinned: 300) }
        _ = faces.add(person: 2, pinned: 300)
        let groups = FaceClustering.cluster(faces.list)
        #expect(groups[0] != groups[6])
        #expect(groups[12] == groups[18])
    }

    // MARK: Store

    @Test func filesContainingRequiresEveryPerson() throws {
        let store = try IndexStore(directory: folder)
        var faces = Faces()
        let a = try insertPhoto(store, name: "a.jpg")
        let b = try insertPhoto(store, name: "b.jpg")
        let both = try insertPhoto(store, name: "both.jpg")
        try store.replaceFaces(of: a, with: [(box(0), faces.vector(person: 0))])
        try store.replaceFaces(of: b, with: [(box(0), faces.vector(person: 1))])
        try store.replaceFaces(of: both, with: [(box(0), faces.vector(person: 0)), (box(1), faces.vector(person: 1))])
        try addCrowd(store, &faces)
        try store.clusterPeople(force: true)
        let personA = try person(store, file: a), personB = try person(store, file: b)
        #expect(personA != personB)

        let onlyA = try #require(try store.filesContaining(allPeople: [personA]))
        #expect(onlyA.isSuperset(of: [a, both]) && !onlyA.contains(b))
        let and = try #require(try store.filesContaining(allPeople: [personA, personB]))
        #expect(and == Set([both]))
        #expect(try store.filesContaining(allPeople: []) == nil)
    }

    /// Grouping again keeps a person's id (and name) where their faces are, and named people never join each other.
    @Test func groupingAgainKeepsNamesAndIds() throws {
        let store = try IndexStore(directory: folder)
        var faces = Faces()
        let crowd = try addCrowd(store, &faces)
        try store.clusterPeople(force: true)
        let anna = try person(store, file: crowd[0])
        try store.renamePerson(anna, to: "Anna")
        // More of Anna arrive; grouping runs again from scratch.
        for i in 0..<20 {
            let file = try insertPhoto(store, name: "anna-more-\(i).jpg")
            try store.replaceFaces(of: file, with: [(box(0), faces.vector(person: 0))])
        }
        try store.regroupPeople()
        #expect(try person(store, file: crowd[0]) == anna)
        #expect(try store.people().first { $0.id == anna }?.name == "Anna")
        let later = try insertPhoto(store, name: "anna-later.jpg")
        try store.replaceFaces(of: later, with: [(box(0), faces.vector(person: 0))])
        #expect(try person(store, file: later) == anna)   // matched as it's indexed, before any regrouping
    }

    /// A named person holds the face the user saw, not every face grouping once gave them: someone else's faces put
    /// with them earlier go back to being someone else.
    @Test func namedPeopleLetGoOfFacesGivenThemByMistake() throws {
        let store = try IndexStore(directory: folder)
        var faces = Faces()
        let crowd = try addCrowd(store, &faces)
        try store.clusterPeople(force: true)
        let anna = try person(store, file: crowd[0]), bob = try person(store, file: crowd[12])
        try store.renamePerson(anna, to: "Anna")
        try store.db.run("UPDATE faces SET person = ? WHERE person = ?", [.int(anna), .int(bob)])
        try store.regroupPeople()
        #expect(try person(store, file: crowd[0]) == anna)
        #expect(try person(store, file: crowd[12]) != anna)
        #expect(try Set(crowd[12..<24].map { try person(store, file: $0) }).count == 1)
    }

    /// An index from before `faces.pinned`, where a named person had come to hold someone else too.
    @Test func olderIndexesLetGoToo() throws {
        var faces = Faces()
        let crowd: [Int64]
        let anna: Int64
        do {
            let store = try IndexStore(directory: folder)
            crowd = try addCrowd(store, &faces)
            try store.clusterPeople(force: true)
            anna = try person(store, file: crowd[0])
            let bob = try person(store, file: crowd[12])
            try store.db.execute("""
                UPDATE people SET name = 'Anna', locked = 1 WHERE id = \(anna);
                UPDATE faces SET person = \(anna) WHERE person = \(bob);
                ALTER TABLE faces DROP COLUMN pinned;
                PRAGMA user_version = 8;
                """)
        }
        let store = try IndexStore(directory: folder)
        #expect(try store.clusterPeople(force: true))
        #expect(try person(store, file: crowd[0]) == anna)
        #expect(try person(store, file: crowd[12]) != anna)
    }

    /// Reading a photo again (it changed, or everything is re-embedded) keeps each face's person.
    @Test func readingAPhotoAgainKeepsItsPeople() throws {
        let store = try IndexStore(directory: folder)
        var faces = Faces()
        let crowd = try addCrowd(store, &faces)
        try store.clusterPeople(force: true)
        let file = crowd[0]
        let before = try person(store, file: file)
        try store.renamePerson(before, to: "Anna")
        try store.resetAll()
        try store.replaceFaces(of: file, with: [(box(0).insetBy(dx: 0.005, dy: 0.005), faces.vector(person: 0))])
        #expect(try person(store, file: file) == before)
    }

    /// Faces read again (new crops) leave the count as it was, and still get people grouped again.
    @Test func facesReadAgainAreGroupedAgain() throws {
        let store = try IndexStore(directory: folder)
        var faces = Faces()
        let crowd = try addCrowd(store, &faces)
        #expect(try store.clusterPeople(force: true))
        #expect(try !store.clusterPeople(force: true))   // nothing changed since
        for file in crowd.prefix(5) { try store.replaceFaces(of: file, with: [(box(0), faces.vector(person: 0))]) }
        #expect(try !store.clusterPeople())               // not a quarter of them yet
        #expect(try store.clusterPeople(force: true))     // but some: once indexing is idle
        for file in crowd.prefix(19) { try store.replaceFaces(of: file, with: [(box(0), faces.vector(person: 0))]) }
        #expect(try !store.clusterPeople())
        try store.replaceFaces(of: crowd[19], with: [(box(0), faces.vector(person: 1))])
        #expect(try store.clusterPeople())                // 20 (at least 20, and a quarter): while indexing goes on
    }

    /// The thumbnail's face going away (its photo read again or removed) used to leave the person unmatchable.
    @Test func thumbnailMovesWhenItsFaceGoes() throws {
        let store = try IndexStore(directory: folder)
        var faces = Faces()
        let crowd = try addCrowd(store, &faces)
        try store.clusterPeople(force: true)
        let someone = try person(store, file: crowd[0])
        let exemplar = try #require(try store.people().first { $0.id == someone }?.exemplarFace)
        var file: Int64 = 0
        try store.db.query("SELECT file FROM faces WHERE id = ?", [.int(exemplar)]) { file = $0.int(0) }
        try store.deleteFaces(of: file)
        let now = try #require(try store.people().first { $0.id == someone }?.exemplarFace)
        var exists = false
        try store.db.query("SELECT 1 FROM faces WHERE id = ? AND person = ?", [.int(now), .int(someone)]) { _ in exists = true }
        #expect(exists)
        #expect(try store.exemplarPhotoPath(ofPerson: someone) != nil)
    }

    /// The user's merge stands when faces are grouped again, though the faces look like two people.
    @Test func mergesSurviveGroupingAgain() throws {
        let store = try IndexStore(directory: folder)
        var faces = Faces()
        let crowd = try addCrowd(store, &faces)
        try store.clusterPeople(force: true)
        let a = try person(store, file: crowd[0]), b = try person(store, file: crowd[12])
        #expect(a != b)
        try store.mergePeople(keeper: a, other: b)
        try store.regroupPeople()
        #expect(try person(store, file: crowd[0]) == person(store, file: crowd[12]))
        #expect(try person(store, file: crowd[0]) != person(store, file: crowd[24]))
    }

    @Test func similarPairsKeepsTheNearestFace() {
        var faces = Faces()
        let anna = faces.vector(person: 0), duplicate = faces.vector(person: 0), someoneElse = faces.vector(person: 1)
        let pairs = IndexStore.similarPairs([(id: 1, vector: anna), (id: 2, vector: duplicate), (id: 4, vector: someoneElse)],
                                            minimum: 0.9)
        #expect(pairs.count == 1)
        #expect(Set([pairs[0].first, pairs[0].second]) == Set([1, 2]))
        #expect(IndexStore.similarPairs([(id: 1, vector: anna), (id: 2, vector: duplicate)], minimum: 0.9,
                                        apart: [[1, 2]]).isEmpty)
    }

    /// One person split in two (a look the model sees as someone else) is suggested for merging; two people on one
    /// photo aren't.
    @Test func suggestsTheSamePersonSplitInTwo() throws {
        let store = try IndexStore(directory: folder)
        var faces = Faces()
        let crowd = try addCrowd(store, &faces)
        try store.clusterPeople(force: true)
        // Person 0's faces split in two by hand (as a sunglasses group would be).
        let anna = try person(store, file: crowd[0])
        try store.db.run("INSERT INTO people(name) VALUES(NULL)")
        let annaToo = store.db.lastInsertID
        for file in crowd[6..<12] { try store.db.run("UPDATE faces SET person = ? WHERE file = ?", [.int(annaToo), .int(file)]) }
        let pairs = try store.similarPeople()
        #expect(pairs.first.map { Set([$0.first, $0.second]) } == Set([anna, annaToo]))
        #expect(pairs.count == 1)   // the other three people are no one else's look
        // Seen together on a photo: not one person.
        let both = try insertPhoto(store, name: "both.jpg")
        try store.db.run("""
            INSERT INTO faces(file, x, y, w, h, person, vec)
            SELECT ?, x + 0.4, y, w, h, person, vec FROM faces WHERE file IN (?, ?)
            """, [.int(both), .int(crowd[0]), .int(crowd[6])])
        #expect(try store.similarPeople().allSatisfy { Set([$0.first, $0.second]) != Set([anna, annaToo]) })
    }

    /// A merged person keeps both looks: new faces like either one go to them, after grouping too.
    @Test func mergeKeepsBothLooks() throws {
        let store = try IndexStore(directory: folder)
        var faces = Faces()
        let crowd = try addCrowd(store, &faces)
        try store.clusterPeople(force: true)
        let keeper = try person(store, file: crowd[0]), other = try person(store, file: crowd[12])
        try store.mergePeople(keeper: keeper, other: other)
        #expect(try store.filesContaining(allPeople: [keeper]) == Set(crowd[0..<24]))
        var later: [Int64] = []
        for i in 0..<10 {
            let file = try insertPhoto(store, name: "later-\(i).jpg")
            try store.replaceFaces(of: file, with: [(box(0), faces.vector(person: i % 2 == 0 ? 0 : 1))])
            later.append(file)
        }
        try store.regroupPeople()
        for file in later { #expect(try person(store, file: file) == keeper) }
        #expect(try person(store, file: crowd[24]) != keeper)
    }

    /// A merge regroups at once: the rest of the merged look's person comes along, without waiting for indexing.
    @Test func mergeGroupsAgainAtOnce() throws {
        let store = try IndexStore(directory: folder)
        var faces = Faces()
        let crowd = try addCrowd(store, &faces)
        try store.clusterPeople(force: true)
        let anna = try person(store, file: crowd[0]), bob = try person(store, file: crowd[12])
        // Bob split in two, the way a look the model sees as someone else would be.
        try store.db.run("INSERT INTO people(name) VALUES(NULL)")
        let bobToo = store.db.lastInsertID
        for file in crowd[18..<24] { try store.db.run("UPDATE faces SET person = ? WHERE file = ?", [.int(bobToo), .int(file)]) }
        try store.mergePeople(keeper: anna, other: bob)
        for file in crowd[12..<24] { #expect(try person(store, file: file) == anna) }
        #expect(try person(store, file: crowd[24]) != anna)
    }

    /// Two people merged by hand can still be one person: they're suggested. Two names are two people.
    @Test func mergedPeopleAreStillSuggested() throws {
        let store = try IndexStore(directory: folder)
        var faces = Faces()
        let crowd = try addCrowd(store, &faces)
        try store.clusterPeople(force: true)
        // Anna in two halves, each one a person the user merged: grouping keeps them apart.
        let anna = try person(store, file: crowd[0])
        try store.db.run("INSERT INTO people(name, locked) VALUES(NULL, 1)")
        let annaToo = store.db.lastInsertID
        try store.db.execute("""
            UPDATE faces SET person = \(annaToo) WHERE file IN (\(crowd[6..<12].map(String.init).joined(separator: ",")));
            UPDATE people SET locked = 1 WHERE id = \(anna);
            UPDATE faces SET pinned = 1 WHERE file IN (\(crowd[0]), \(crowd[6]));
            """)
        try store.regroupPeople()
        #expect(try person(store, file: crowd[0]) == anna && person(store, file: crowd[6]) == annaToo)
        #expect(try store.similarPeople().contains { Set([$0.first, $0.second]) == [anna, annaToo] })
        try store.renamePerson(anna, to: "Anna")
        try store.renamePerson(annaToo, to: "Hanna")
        #expect(try !store.similarPeople().contains { Set([$0.first, $0.second]) == [anna, annaToo] })
    }

    /// A suggestion turned down stays away until the user asks to see them all again.
    @Test func dismissedSuggestionsStayAway() throws {
        let store = try IndexStore(directory: folder)
        var faces = Faces()
        let crowd = try addCrowd(store, &faces)
        try store.clusterPeople(force: true)
        let anna = try person(store, file: crowd[0])
        try store.db.run("INSERT INTO people(name) VALUES(NULL)")
        let annaToo = store.db.lastInsertID
        for file in crowd[6..<12] { try store.db.run("UPDATE faces SET person = ? WHERE file = ?", [.int(annaToo), .int(file)]) }
        let pair: Set<Int64> = [anna, annaToo]
        #expect(try store.similarPeople().contains { Set([$0.first, $0.second]) == pair })
        try store.dismissSuggestion(annaToo, anna)
        #expect(try !store.similarPeople().contains { Set([$0.first, $0.second]) == pair })
        #expect(try store.dismissedSuggestionCount() == 1)
        try store.restoreSuggestions()
        #expect(try store.similarPeople().contains { Set([$0.first, $0.second]) == pair })
        #expect(try store.dismissedSuggestionCount() == 0)
    }

    /// Undoing merges splits what the user joined, and keeps names.
    @Test func undoMergesSplitsThemAgain() throws {
        let store = try IndexStore(directory: folder)
        var faces = Faces()
        let crowd = try addCrowd(store, &faces)
        try store.clusterPeople(force: true)
        let a = try person(store, file: crowd[0]), b = try person(store, file: crowd[12])
        let c = try person(store, file: crowd[24])
        try store.renamePerson(c, to: "Cleo")
        try store.mergePeople(keeper: a, other: b)
        #expect(try person(store, file: crowd[12]) == a)
        try store.undoMerges()
        #expect(try person(store, file: crowd[0]) != person(store, file: crowd[12]))
        #expect(try person(store, file: crowd[24]) == c)
        #expect(try store.people().first { $0.id == c }?.name == "Cleo")
    }

    @Test func mergeKeepsEitherName() throws {
        let store = try IndexStore(directory: folder)
        var faces = Faces()
        let crowd = try addCrowd(store, &faces)
        try store.clusterPeople(force: true)
        let a = try person(store, file: crowd[0]), b = try person(store, file: crowd[12])
        try store.renamePerson(b, to: "Bob")
        try store.mergePeople(keeper: a, other: b)
        #expect(try store.people().first { $0.id == a }?.name == "Bob")
        #expect(try store.people().allSatisfy { $0.id != b })
    }

    @Test func renamePerson() throws {
        let store = try IndexStore(directory: folder)
        var faces = Faces()
        let file = try insertPhoto(store, name: "face.jpg")
        try store.replaceFaces(of: file, with: [(box(0), faces.vector(person: 3))])
        try store.clusterPeople(force: true)
        let person = try person(store, file: file)
        try store.renamePerson(person, to: "  Anna ")
        #expect(try store.people().first?.displayName == "Anna")
    }

    /// A person's thumbnail decodes the photo only as big as the face needs, the right way up.
    @Test func imageForAFaceIsOnlyAsBigAsItNeeds() throws {
        // 2000 × 1000, blue, with a red "face" low on the right: x 1200–1400, y 800–1000 from the top.
        let context = try #require(CGContext(data: nil, width: 2000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 1200, y: 0, width: 200, height: 200))   // CoreGraphics draws from the bottom
        let url = folder.appendingPathComponent("photo.png")
        try ImageExtractor.write(try #require(context.makeImage()), to: url, png: true)

        let box = CGRect(x: 0.6, y: 0, width: 0.1, height: 0.2)   // Vision: origin bottom-left
        let image = try #require(FaceDetector.image(of: url, showing: box, side: 64))
        #expect(image.width == 640 && image.height == 320)       // the face's longer side: 64 px
        let face = try pixel(image, x: Int(0.65 * Double(image.width)), y: Int(0.9 * Double(image.height)))
        #expect(face.red > 200 && face.blue < 50)
    }

    // MARK: Helpers

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (red: UInt8, blue: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (bytes[0], bytes[2])
    }

    /// 4 people × 12 photos, enough faces to match new ones against. `crowd[0]` is person 0, `crowd[12]` person 1.
    @discardableResult
    private func addCrowd(_ store: IndexStore, _ faces: inout Faces) throws -> [Int64] {
        try (0..<48).map { i in
            let id = try insertPhoto(store, name: "crowd-\(i).jpg")
            try store.replaceFaces(of: id, with: [(box(0), faces.vector(person: i / 12))])
            return id
        }
    }

    private func insertPhoto(_ store: IndexStore, name: String) throws -> Int64 {
        let path = folder.appendingPathComponent(name).path
        return try store.insert(Candidate(path: path, kind: .image, size: 100, mtime: 1,
                                          inode: UInt64.random(in: 1...999_999), device: 1))
    }

    private func person(_ store: IndexStore, file: Int64) throws -> Int64 {
        var person: Int64?
        try store.db.query("SELECT person FROM faces WHERE file = ? ORDER BY x LIMIT 1", [.int(file)]) {
            person = $0.isNull(0) ? nil : $0.int(0)
        }
        return try #require(person)
    }

    private func box(_ slot: Int) -> CGRect { CGRect(x: 0.1 + 0.4 * Double(slot), y: 0.2, width: 0.3, height: 0.3) }
}

/// Made-up face vectors shaped like EmbeddingGemma's: a big part every face shares, a part per person, and noise.
private struct Faces {
    var random = Seeded(seed: 7)
    var list: [FaceClustering.Face] = []
    private var people: [[Float]] = []
    private lazy var shared: [Float] = direction()

    mutating func add(person: Int, file: Int64? = nil, pinned: Int64? = nil) -> Int {
        list.append(FaceClustering.Face(file: file ?? Int64(list.count), vector: vector(person: person), pinned: pinned))
        return person
    }

    mutating func vector(person: Int) -> [Float] {
        while people.count <= person { people.append(direction()) }
        let noise = direction()
        let own = people[person], common = shared
        return FaceClustering.normalized((0..<Vectors.dimension).map { 0.9 * common[$0] + 0.38 * own[$0] + 0.22 * noise[$0] })
    }

    private mutating func direction() -> [Float] {
        FaceClustering.normalized((0..<Vectors.dimension).map { _ in Float.random(in: -1...1, using: &random) })
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
}

private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
