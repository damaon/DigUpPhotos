import Foundation

/// Groups face vectors into people.
///
/// The vectors are `FaceIdentity`'s. Taking the average face away first (`centered`) leaves what tells people apart:
/// two people on one photo go from 0.11 to -0.08 (median), one person's faces from 0.66 to 0.42, and grouping mixes
/// people less (1.7% of held-out pairs from one photo vs 2.1% raw, 1,455 faces, 2026-10-30). It was what made
/// EmbeddingGemma's face vectors usable at all (any two faces ~0.78 raw), the model before.
///
/// Then average linkage: two groups join when their faces are, on average, close enough. Every face counts, not one
/// exemplar, and the order photos were indexed in doesn't matter. Two faces on one photo are never the same person.
/// To keep memory at groups² rather than faces², a strict first pass puts near-identical faces (bursts, the same
/// event) together; linking those groups gives the same people as linking single faces (measured on the set above).
enum FaceClustering {
    struct Face {
        let file: Int64
        /// As the model gave it (L2-normalized).
        let vector: [Float]
        /// The person the user named or merged this face into: their faces end up together (two merged looks stay two
        /// groups until then, each drawing faces like it), and apart from the people `cluster`'s `apart` says.
        let pinned: Int64?
    }

    /// Centered cosine to a group's centroid that puts a face in it in the first pass (and when indexing adds one).
    static let seedThreshold: Float = 0.6
    /// Average centered cosine between two groups' faces at or above which they're one person.
    static let linkThreshold: Float = 0.22

    static func mean(_ vectors: [[Float]]) -> [Float] {
        var sum = [Float](repeating: 0, count: FaceIdentity.dimension)
        for vector in vectors where vector.count == FaceIdentity.dimension { Linear.add(vector, to: &sum) }
        guard !vectors.isEmpty else { return sum }
        return sum.map { $0 / Float(vectors.count) }
    }

    /// `vector` minus the average face, L2-normalized.
    static func centered(_ vector: [Float], mean: [Float]) -> [Float] {
        normalized(Linear.subtract(mean, from: vector))
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = Linear.sumOfSquares(vector).squareRoot()
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// A group index for every face (0..<groups, in order of first appearance). Two pinned people end up in one group
    /// when their faces are close enough, unless `apart` (two people with names, or a pair the user turned down); by
    /// default no two pinned people do.
    static func cluster(_ faces: [Face], threshold: Float = linkThreshold,
                        apart: @escaping (Int64, Int64) -> Bool = { $0 != $1 }) -> [Int] {
        guard !faces.isEmpty else { return [] }
        let d = FaceIdentity.dimension
        let average = mean(faces.map(\.vector))
        let vectors = faces.map { centered($0.vector, mean: average) }

        // Pass 1: the user's people first, then every other face, each into the nearest group close enough to its
        // centroid (a pinned face only into its own person's), or a group of its own.
        var groups = Groups(dimension: d, apart: apart)
        var groupOf = [Int](repeating: -1, count: faces.count)
        let order = faces.indices.filter { faces[$0].pinned != nil } + faces.indices.filter { faces[$0].pinned == nil }
        for index in order {
            let face = faces[index]
            let scores = groups.centroidScores(vectors[index])
            var best = -1
            var bestScore = seedThreshold
            for (group, score) in scores.enumerated() where score >= bestScore && !groups.files[group].contains(face.file)
                && (face.pinned == nil || groups.pinned[group] == face.pinned) {
                best = group
                bestScore = score
            }
            if best < 0 { best = groups.add(pinned: face.pinned) }
            groups.insert(vectors[index], file: face.file, into: best)
            groupOf[index] = best
        }

        // Pass 2: average linkage between groups; then each pinned person's groups are one (people joined in pass 2
        // are one person).
        var survivor = groups.link(threshold: threshold)
        var personRoot: [Int64: Int] = [:]
        for group in survivor.indices {
            guard let pinned = groups.pinned[survivor[group]].map(groups.person) else { continue }
            if let root = personRoot[pinned] { survivor[group] = root } else { personRoot[pinned] = survivor[group] }
        }
        var renumber: [Int: Int] = [:]
        return groupOf.map { group in
            let root = survivor[group]
            if let number = renumber[root] { return number }
            renumber[root] = renumber.count
            return renumber[root]!
        }
    }
}

/// Groups of centered face vectors, kept as sums: the average cosine between two groups' faces is the dot product of
/// their sums over the product of their sizes, so merging two groups is adding two vectors.
private struct Groups {
    let dimension: Int
    var sums: [Float] = []          // groups × dimension
    var centroids: [Float] = []     // normalized sums, for pass 1
    var sizes: [Float] = []
    var files: [Set<Int64>] = []
    var pinned: [Int64?] = []
    var count: Int { sizes.count }
    /// Pinned people joined into one, and who's in each: two are apart when any of theirs are.
    let apart: (Int64, Int64) -> Bool
    private var joinedInto: [Int64: Int64] = [:]
    private var together: [Int64: Set<Int64>] = [:]

    init(dimension: Int, apart: @escaping (Int64, Int64) -> Bool) {
        self.dimension = dimension
        self.apart = apart
    }

    /// The person `id` is part of now.
    func person(_ id: Int64) -> Int64 {
        var id = id
        while let next = joinedInto[id] { id = next }
        return id
    }

    private func peopleApart(_ a: Int64?, _ b: Int64?) -> Bool {
        guard let a = a.map(person), let b = b.map(person), a != b else { return false }
        let left = together[a] ?? [a], right = together[b] ?? [b]
        return left.contains { x in right.contains { y in apart(x, y) } }
    }

    private mutating func join(_ a: Int64?, _ b: Int64?) {
        guard let a = a.map(person), let b = b.map(person), a != b else { return }
        joinedInto[b] = a
        together[a] = (together[a] ?? [a]).union(together[b] ?? [b])
    }

    mutating func add(pinned person: Int64?) -> Int {
        sums += [Float](repeating: 0, count: dimension)
        centroids += [Float](repeating: 0, count: dimension)
        sizes.append(0)
        files.append([])
        pinned.append(person)
        return count - 1
    }

    mutating func insert(_ vector: [Float], file: Int64, into group: Int) {
        let start = group * dimension
        for i in 0..<dimension { sums[start + i] += vector[i] }
        let centroid = FaceClustering.normalized(Array(sums[start..<start + dimension]))
        centroids.replaceSubrange(start..<start + dimension, with: centroid)
        sizes[group] += 1
        files[group].insert(file)
    }

    func centroidScores(_ vector: [Float]) -> [Float] {
        guard count > 0 else { return [] }
        var scores = [Float](repeating: 0, count: count)
        centroids.withUnsafeBufferPointer { centroids in
            Linear.multiply(centroids.baseAddress!, rows: count, columns: dimension, by: vector, into: &scores)
        }
        return scores
    }

    /// Joins the closest pair of groups until none is at `threshold`; returns each group's surviving group.
    mutating func link(threshold: Float) -> [Int] {
        let m = count
        var parent = Array(0..<m)
        guard m > 1 else { return parent }
        // Linkage matrix: average cosine, or -inf where the two can't be one person.
        var link = Linear.gram(sums, rows: m, columns: dimension)
        for a in 0..<m {
            for b in 0..<m {
                link[a * m + b] = a == b || conflict(a, b) ? -.infinity : link[a * m + b] / (sizes[a] * sizes[b])
            }
        }
        var alive = [Bool](repeating: true, count: m)
        var best = (0..<m).map { bestOf($0, link: link, alive: alive, m: m) }
        var row = [Float](repeating: 0, count: m)
        while true {
            var a = -1
            var top = threshold
            for g in 0..<m where alive[g] && best[g].score >= top {
                a = g
                top = best[g].score
            }
            guard a >= 0 else { break }
            let b = best[a].group
            // b into a.
            let (startA, startB) = (a * dimension, b * dimension)
            for i in 0..<dimension { sums[startA + i] += sums[startB + i] }
            sizes[a] += sizes[b]
            files[a].formUnion(files[b])
            join(pinned[a], pinned[b])
            pinned[a] = pinned[a] ?? pinned[b]
            alive[b] = false
            parent[b] = a
            sums.withUnsafeBufferPointer { all in
                Linear.multiply(all.baseAddress!, rows: m, columns: dimension, by: all.baseAddress! + startA, into: &row)
            }
            for c in 0..<m {
                let blocked = !alive[c] || c == a || link[a * m + c] == -.infinity || link[b * m + c] == -.infinity
                    || peopleApart(pinned[a], pinned[c])
                let value = blocked ? -Float.infinity : row[c] / (sizes[a] * sizes[c])
                link[a * m + c] = value
                link[c * m + a] = value
                link[b * m + c] = -.infinity
                link[c * m + b] = -.infinity
            }
            best[a] = bestOf(a, link: link, alive: alive, m: m)
            for c in 0..<m where alive[c] && c != a {
                if best[c].group == a || best[c].group == b {
                    best[c] = bestOf(c, link: link, alive: alive, m: m)
                } else if link[c * m + a] > best[c].score {
                    best[c] = (a, link[c * m + a])
                }
            }
        }
        return (0..<m).map { group in
            var root = group
            while parent[root] != root { root = parent[root] }
            return root
        }
    }

    private func conflict(_ a: Int, _ b: Int) -> Bool {
        peopleApart(pinned[a], pinned[b]) || !files[a].isDisjoint(with: files[b])
    }

    private func bestOf(_ g: Int, link: [Float], alive: [Bool], m: Int) -> (group: Int, score: Float) {
        var best = (group: -1, score: -Float.infinity)
        for c in 0..<m where c != g && alive[c] && link[g * m + c] > best.score { best = (c, link[g * m + c]) }
        return best
    }
}
