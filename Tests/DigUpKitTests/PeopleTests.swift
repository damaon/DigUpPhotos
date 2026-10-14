import Foundation
import Testing
@testable import DigUpKit

@Suite struct PeopleTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpPeople-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    @Test func filesContainingRequiresEveryPerson() throws {
        let store = try IndexStore(directory: folder)
        let a = try insertPhoto(store, name: "a.jpg")
        let b = try insertPhoto(store, name: "b.jpg")
        let both = try insertPhoto(store, name: "both.jpg")
        // Orthogonal-ish vectors so matching creates separate people.
        let personA = try addFace(store, file: a, vector: unit(1))
        let personB = try addFace(store, file: b, vector: unit(2))
        _ = try store.addFace(file: both, box: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), vector: unit(1))
        _ = try store.addFace(file: both, box: CGRect(x: 0.5, y: 0.1, width: 0.2, height: 0.2), vector: unit(2))

        let onlyA = try #require(try store.filesContaining(allPeople: [personA]))
        #expect(onlyA == Set([a, both]))
        let onlyB = try #require(try store.filesContaining(allPeople: [personB]))
        #expect(onlyB == Set([b, both]))
        let and = try #require(try store.filesContaining(allPeople: [personA, personB]))
        #expect(and == Set([both]))
        #expect(try store.filesContaining(allPeople: []) == nil)
    }

    @Test func similarPairsKeepsTheNearestFace() {
        let anna = unit(0)
        var duplicate = unit(0)
        duplicate[1] = 0.15
        let length = sqrt(duplicate.reduce(0) { $0 + $1 * $1 })
        duplicate = duplicate.map { $0 / length }
        let someoneElse = unit(5)
        let pairs = IndexStore.similarPairs([(id: 1, vector: anna), (id: 2, vector: duplicate), (id: 4, vector: someoneElse)])
        #expect(pairs.count == 1)
        #expect(Set([pairs[0].first, pairs[0].second]) == Set([1, 2]))
        #expect(pairs[0].score > 0.9)
    }

    @Test func mergeKeepsBothEmbeddingsForFiltering() throws {
        let directory = folder.appendingPathComponent("merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try IndexStore(directory: directory)
        let fileA = try insertPhoto(store, name: "merge-a.jpg")
        let fileB = try insertPhoto(store, name: "merge-b.jpg")
        let keeper = try addFace(store, file: fileA, vector: unit(0))
        let other = try addFace(store, file: fileB, vector: unit(5))
        #expect(keeper != other)
        try store.mergePeople(keeper: keeper, other: other)

        let together = try #require(try store.filesContaining(allPeople: [keeper]))
        #expect(together == Set([fileA, fileB]))
        #expect(try store.people().map(\.id) == [keeper])

        let later = try insertPhoto(store, name: "merge-later.jpg")
        _ = try store.addFace(file: later, box: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), vector: unit(5))
        let after = try #require(try store.filesContaining(allPeople: [keeper]))
        #expect(after == Set([fileA, fileB, later]))
    }

    @Test func renamePerson() throws {
        let store = try IndexStore(directory: folder.appendingPathComponent("rename"))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let store2 = try IndexStore(directory: store.directory)
        let file = try insertPhoto(store2, name: "face.jpg")
        let person = try addFace(store2, file: file, vector: unit(3))
        try store2.renamePerson(person, to: "Anna")
        let people = try store2.people()
        #expect(people.first?.name == "Anna")
        #expect(people.first?.displayName == "Anna")
    }

    // MARK: Helpers

    private func insertPhoto(_ store: IndexStore, name: String) throws -> Int64 {
        let path = folder.appendingPathComponent(name).path
        return try store.insert(Candidate(path: path, kind: .image, size: 100, mtime: 1, inode: UInt64.random(in: 1...9_999),
                                          device: 1))
    }

    private func addFace(_ store: IndexStore, file: Int64, vector: [Float]) throws -> Int64 {
        try store.addFace(file: file, box: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3), vector: vector)
        var person: Int64?
        try store.db.query("SELECT person FROM faces WHERE file = ? ORDER BY id DESC LIMIT 1", [.int(file)]) {
            person = $0.int(0)
        }
        return try #require(person)
    }

    /// Unit vector with a 1 in slot `index` (and zeros elsewhere), L2-normalized.
    private func unit(_ index: Int) -> [Float] {
        var v = [Float](repeating: 0, count: Vectors.dimension)
        v[index % Vectors.dimension] = 1
        return v
    }
}
