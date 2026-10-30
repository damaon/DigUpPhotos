import CoreGraphics
import DigUpCore
import Foundation
import ImageIO

/// One photo reduced to a small grayscale picture, so two shots can be compared by how they look.
enum VisualPrint {
    static let side = 24

    /// Mean-centered, length-normalized pixels. Nil for a flat frame (nothing to compare).
    static func samples(_ image: CGImage) -> [Float]? {
        let count = side * side
        var pixels = [UInt8](repeating: 0, count: count)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return nil }
        var values = pixels.map { Float($0) / 255 }
        let mean = values.reduce(0, +) / Float(count)
        var sum: Float = 0
        for index in values.indices {
            values[index] -= mean
            sum += values[index] * values[index]
        }
        let norm = sum.squareRoot()
        // A blank or near-blank frame has no picture to match.
        guard norm > 0.02 else { return nil }
        for index in values.indices { values[index] /= norm }
        return values
    }

    /// Cosine of two prints. 1 is the same picture; 0 is unrelated.
    static func cosine(_ left: [Float], _ right: [Float]) -> Float {
        guard left.count == right.count, !left.isEmpty else { return 0 }
        var dot: Float = 0
        for index in left.indices { dot += left[index] * right[index] }
        return dot
    }

    /// A small thumbnail's print, or nil when the file can't be read.
    static func file(_ path: String) -> [Float]? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return samples(image)
    }
}

/// What a photo contributes when deciding whether it is the same shot as another, and which frame wins.
public struct ShotSignature: Sendable, Equatable {
    public var id: Int64
    public var taken: Date
    public var quality: Int
    /// Face framing, 0…100. Nil when there is no face.
    public var framing: Int?
    /// 0…1 how much the largest face is smiling. Nil when it was not measured.
    public var smile: Double?
    public var samples: [Float]
    public var hasPeople: Bool

    public init(id: Int64, taken: Date, quality: Int, framing: Int? = nil, smile: Double? = nil,
                samples: [Float], hasPeople: Bool) {
        self.id = id
        self.taken = taken
        self.quality = quality
        self.framing = framing
        self.smile = smile
        self.samples = samples
        self.hasPeople = hasPeople
    }
}

/// Near-duplicate shots collapsed to one frame. `members` is date order. `best` is the frame to keep.
public struct PhotoStack: Sendable, Equatable, Identifiable {
    public var members: [Int64]
    public var best: Int64
    public var id: Int64 { best }

    public init(members: [Int64], best: Int64) {
        self.members = members
        self.best = best
    }
}

/// Prints learned while stacking, including an empty print when a file could not be read.
public struct StackPass: Sendable {
    public var stacks: [PhotoStack]
    public var prints: [Int64: [Float]]

    public init(stacks: [PhotoStack], prints: [Int64: [Float]]) {
        self.stacks = stacks
        self.prints = prints
    }
}

/// One cell in the album grid. A collapsed stack shows only its best photo.
public struct AlbumGridPhoto: Sendable, Equatable, Identifiable {
    public var photo: AlbumPhoto
    /// Best photo of the stack, when this cell is part of one.
    public var stackBest: Int64?
    public var stackCount: Int
    /// The frame chosen for this stack.
    public var isPick: Bool
    public var id: Int64 { photo.id }

    public init(photo: AlbumPhoto, stackBest: Int64?, stackCount: Int, isPick: Bool) {
        self.photo = photo
        self.stackBest = stackBest
        self.stackCount = stackCount
        self.isPick = isPick
    }
}

/// Collapses shots that are the same picture taken in the same short stretch, and picks one frame to keep.
public enum PhotoStacks {
    /// A burst: a few minutes of the same pose. The pictures can differ a little.
    public static let burst: TimeInterval = 3 * 60
    /// The longest a stack can stretch. Later than this, even a matching picture is a new moment.
    public static let sameStop: TimeInterval = 20 * 60
    /// How alike a burst must look (cosine of the grayscale print).
    public static let burstSimilarity: Float = 0.86
    /// How alike shots must look once they are past the burst and still within the same stop.
    public static let closeSimilarity: Float = 0.93

    /// Stacks of two or more. Photos that don't match anything are left out.
    public static func group(_ shots: [ShotSignature]) -> [PhotoStack] {
        let ordered = shots.sorted { $0.taken == $1.taken ? $0.id < $1.id : $0.taken < $1.taken }
        var parent: [Int64: Int64] = [:]
        var started: [Int64: Date] = [:]
        var ended: [Int64: Date] = [:]
        for shot in ordered {
            parent[shot.id] = shot.id
            started[shot.id] = shot.taken
            ended[shot.id] = shot.taken
        }
        func find(_ id: Int64) -> Int64 {
            var root = id
            while let next = parent[root], next != root { root = next }
            return root
        }
        func unite(_ left: ShotSignature, _ right: ShotSignature) {
            let a = find(left.id)
            let b = find(right.id)
            guard a != b, let startA = started[a], let endA = ended[a], let startB = started[b], let endB = ended[b]
            else { return }
            let start = min(startA, startB)
            let end = max(endA, endB)
            // Neighbors can chain, but the whole stack still has to fit in one stop.
            guard end.timeIntervalSince(start) <= sameStop else { return }
            parent[b] = a
            started[a] = start
            ended[a] = end
        }
        let byID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        for index in ordered.indices {
            for later in (index + 1)..<ordered.count {
                let gap = ordered[later].taken.timeIntervalSince(ordered[index].taken)
                if gap > sameStop { break }
                guard samePicture(ordered[index], ordered[later], gap: gap) else { continue }
                unite(ordered[index], ordered[later])
            }
        }
        var groups: [Int64: [ShotSignature]] = [:]
        for shot in ordered {
            groups[find(shot.id), default: []].append(shot)
        }
        return groups.values.compactMap { members in
            guard members.count > 1, let best = members.max(by: { !prefer($0, to: $1) }) else { return nil }
            let ids = members.map(\.id)
            return PhotoStack(members: ids, best: best.id)
        }
        .sorted { lhs, rhs in
            let left = byID[lhs.members[0]]?.taken ?? .distantPast
            let right = byID[rhs.members[0]]?.taken ?? .distantPast
            return left == right ? lhs.best < rhs.best : left < right
        }
    }

    /// Reads each photo's pixels, stacks the ones from the same moment, then picks a frame.
    /// People stacks also look at the smile of the largest face. `prints` skips files already measured;
    /// an empty print means the file could not be read.
    public static func assemble(_ photos: [AlbumPhoto], prints known: [Int64: [Float]] = [:]) -> StackPass {
        var learned: [Int64: [Float]] = [:]
        var shots: [ShotSignature] = []
        let length = VisualPrint.side * VisualPrint.side
        for photo in photos {
            let samples: [Float]
            if let cached = known[photo.id] {
                samples = cached
            } else {
                let made = VisualPrint.file(photo.path) ?? []
                learned[photo.id] = made
                samples = made
            }
            guard samples.count == length else { continue }
            shots.append(ShotSignature(id: photo.id, taken: photo.taken, quality: photo.quality,
                                       framing: photo.framing, samples: samples, hasPeople: !photo.people.isEmpty))
        }
        let rough = group(shots)
        let together = Set(rough.flatMap(\.members))
        var smileFor: [Int64: Double] = [:]
        for photo in photos where together.contains(photo.id) && !photo.people.isEmpty {
            if let score = FaceDetector.smile(file: photo.path) { smileFor[photo.id] = score }
        }
        guard !smileFor.isEmpty else { return StackPass(stacks: rough, prints: learned) }
        let refined = shots.map { shot -> ShotSignature in
            var shot = shot
            shot.smile = smileFor[shot.id]
            return shot
        }
        return StackPass(stacks: group(refined), prints: learned)
    }

    /// 0…1 from the outer lip, in Vision's face box (origin bottom-left). Corners above the middle of the mouth
    /// count as a smile. A flat mouth is 0.
    public static func smile(mouth points: [CGPoint]) -> Double {
        guard points.count >= 4,
              let left = points.min(by: { $0.x < $1.x }),
              let right = points.max(by: { $0.x < $1.x }) else { return 0 }
        let width = Double(right.x - left.x)
        guard width > 0.001 else { return 0 }
        let midX = (Double(left.x) + Double(right.x)) / 2
        let central = points.filter { abs(Double($0.x) - midX) <= width * 0.25 }
        let sample = central.isEmpty ? points : central
        let midY = sample.reduce(0.0) { $0 + Double($1.y) } / Double(sample.count)
        let cornerY = (Double(left.y) + Double(right.y)) / 2
        let lift = (cornerY - midY) / width
        return min(1, max(0, lift / 0.18))
    }

    /// Grid order. A collapsed stack keeps the best frame in its own place and hides the rest.
    public static func rows(_ photos: [AlbumPhoto], stacks: [PhotoStack], expanded: Set<Int64>) -> [AlbumGridPhoto] {
        var stackOf: [Int64: PhotoStack] = [:]
        for stack in stacks where stack.members.count > 1 {
            for id in stack.members { stackOf[id] = stack }
        }
        return photos.compactMap { photo in
            guard let stack = stackOf[photo.id] else {
                return AlbumGridPhoto(photo: photo, stackBest: nil, stackCount: 1, isPick: false)
            }
            let open = expanded.contains(stack.best)
            if !open, photo.id != stack.best { return nil }
            return AlbumGridPhoto(photo: photo, stackBest: stack.best, stackCount: stack.members.count,
                                  isPick: photo.id == stack.best)
        }
    }

    /// Look score, plus composition and smile when the photo has people.
    static func rank(_ shot: ShotSignature) -> Double {
        let quality = Double(shot.quality)
        guard shot.hasPeople else { return quality }
        let framing = Double(shot.framing ?? 0) / 100
        let smile = shot.smile ?? 0
        // Quality still leads. Among a burst, framing and a smile can move a close call.
        return quality + 12 * framing + 14 * smile
    }

    private static func samePicture(_ left: ShotSignature, _ right: ShotSignature, gap: TimeInterval) -> Bool {
        let alike = VisualPrint.cosine(left.samples, right.samples)
        if gap <= burst { return alike >= burstSimilarity }
        if gap <= sameStop { return alike >= closeSimilarity }
        return false
    }

    /// True when `left` should win over `right`.
    private static func prefer(_ left: ShotSignature, to right: ShotSignature) -> Bool {
        let leftRank = rank(left)
        let rightRank = rank(right)
        if leftRank != rightRank { return leftRank > rightRank }
        if left.quality != right.quality { return left.quality > right.quality }
        return left.id < right.id
    }
}
