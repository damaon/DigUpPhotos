import CoreGraphics
import Foundation
import Testing
@testable import DigUpApple
@testable import DigUpCore

@Suite struct PhotoStackTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func burstOfTheSamePictureCollapsesToTheSharpest() {
        let picture = axis(0)
        let shots = [
            shot(1, seconds: 0, quality: 60, samples: picture),
            shot(2, seconds: 8, quality: 84, samples: picture),
            shot(3, seconds: 20, quality: 70, samples: picture),
        ]
        let stacks = PhotoStacks.group(shots)
        #expect(stacks.count == 1)
        #expect(stacks[0].members == [1, 2, 3])
        #expect(stacks[0].best == 2)
    }

    @Test func theSamePictureOnAnotherDayStaysSeparate() {
        let picture = axis(0)
        let shots = [
            shot(1, seconds: 0, samples: picture),
            shot(2, seconds: 2 * 60 * 60, samples: picture),
        ]
        #expect(PhotoStacks.group(shots).isEmpty)
    }

    @Test func aBurstAllowsALooserMatchThanALaterShot() {
        let (near, far) = pair(cosine: 0.88)
        let burst = [
            shot(1, seconds: 0, samples: near),
            shot(2, seconds: 40, samples: far),
        ]
        #expect(PhotoStacks.group(burst).count == 1)
        let later = [
            shot(1, seconds: 0, samples: near),
            shot(2, seconds: 10 * 60, samples: far),
        ]
        #expect(PhotoStacks.group(later).isEmpty)
    }

    @Test func aCloseMatchWithinTheSameStopCollapses() {
        let (left, right) = pair(cosine: 0.96)
        let shots = [
            shot(1, seconds: 0, samples: left),
            shot(2, seconds: 12 * 60, samples: right),
        ]
        let stacks = PhotoStacks.group(shots)
        #expect(stacks.count == 1)
        #expect(stacks[0].members == [1, 2])
    }

    @Test func aChainCannotSwallowTheWholeAfternoon() {
        let picture = axis(0)
        // Identical frames every 10 minutes for an hour. Each stack has to stay inside one stop.
        var shots: [ShotSignature] = []
        for index in 0..<7 {
            shots.append(shot(Int64(index + 1), seconds: Double(index) * 10 * 60, samples: picture))
        }
        let stacks = PhotoStacks.group(shots)
        #expect(!stacks.isEmpty)
        for stack in stacks {
            let times = stack.members.map { Double($0 - 1) * 10 * 60 }
            let span = (times.max() ?? 0) - (times.min() ?? 0)
            #expect(span <= PhotoStacks.sameStop)
        }
        // The first frame and the one an hour later are not the same moment.
        let withFirst = stacks.first { $0.members.contains(1) }
        #expect(withFirst?.members.contains(3) == true)
        #expect(withFirst?.members.contains(7) == false)
    }

    @Test func differentPicturesInABurstStayApart() {
        let shots = [
            shot(1, seconds: 0, samples: axis(0)),
            shot(2, seconds: 5, samples: axis(1)),
        ]
        #expect(PhotoStacks.group(shots).isEmpty)
    }

    @Test func smileAndFramingPickTheFrameWhenPeopleAreInIt() {
        let picture = axis(0)
        let sharp = shot(1, seconds: 0, quality: 80, samples: picture, hasPeople: true)
        var warm = shot(2, seconds: 4, quality: 74, framing: 90, smile: 0.9, samples: picture, hasPeople: true)
        warm.framing = 90
        let stacks = PhotoStacks.group([sharp, warm])
        #expect(stacks.first?.best == 2)
        // Without people, the look score wins and the smile is ignored.
        let plain = [
            shot(1, seconds: 0, quality: 80, smile: 0, samples: picture),
            shot(2, seconds: 4, quality: 74, framing: 100, smile: 1, samples: picture),
        ]
        #expect(PhotoStacks.group(plain).first?.best == 1)
    }

    @Test func anUpturnedMouthScoresHigherThanAFlatOne() {
        let flat = [
            CGPoint(x: 0.2, y: 0.4), CGPoint(x: 0.4, y: 0.4),
            CGPoint(x: 0.6, y: 0.4), CGPoint(x: 0.8, y: 0.4),
        ]
        let smile = [
            CGPoint(x: 0.2, y: 0.55), CGPoint(x: 0.4, y: 0.40),
            CGPoint(x: 0.6, y: 0.40), CGPoint(x: 0.8, y: 0.55),
        ]
        #expect(PhotoStacks.smile(mouth: flat) == 0)
        #expect(PhotoStacks.smile(mouth: smile) > 0.8)
    }

    @Test func collapsedStackShowsThePickAndOpensOnDemand() {
        let photos = [photo(1, 0), photo(2, 10), photo(3, 20), photo(4, 600)]
        let stack = PhotoStack(members: [1, 2, 3], best: 2)
        let closed = PhotoStacks.rows(photos, stacks: [stack], expanded: [])
        #expect(closed.map(\.photo.id) == [2, 4])
        #expect(closed[0].isPick)
        #expect(closed[0].stackCount == 3)
        let open = PhotoStacks.rows(photos, stacks: [stack], expanded: [2])
        #expect(open.map(\.photo.id) == [1, 2, 3, 4])
        #expect(open.first { $0.photo.id == 2 }?.isPick == true)
        #expect(open.first { $0.photo.id == 1 }?.isPick == false)
    }

    @Test func exposureChangeStaysTheSamePictureAndADifferentLayoutDoesNot() throws {
        let dark = split(left: 30, right: 170, vertical: false)
        let bright = split(left: 80, right: 230, vertical: false)
        let turned = split(left: 30, right: 170, vertical: true)
        let flat = fill(140)
        let darkPrint = try #require(VisualPrint.samples(dark))
        let brightPrint = try #require(VisualPrint.samples(bright))
        let turnedPrint = try #require(VisualPrint.samples(turned))
        #expect(VisualPrint.cosine(darkPrint, brightPrint) >= 0.97)
        #expect(VisualPrint.cosine(darkPrint, turnedPrint) < PhotoStacks.burstSimilarity)
        #expect(VisualPrint.samples(flat) == nil)
    }

    @Test func aSmallShiftInABurstStillMatches() throws {
        let first = split(left: 20, right: 210, vertical: false, cut: 0.46)
        let shifted = split(left: 20, right: 210, vertical: false, cut: 0.54)
        let a = try #require(VisualPrint.samples(first))
        let b = try #require(VisualPrint.samples(shifted))
        #expect(VisualPrint.cosine(a, b) >= PhotoStacks.burstSimilarity)
    }

    // MARK: Helpers

    private func shot(_ id: Int64, seconds: TimeInterval, quality: Int = 50, framing: Int? = nil,
                      smile: Double? = nil, samples: [Float], hasPeople: Bool = false) -> ShotSignature {
        ShotSignature(id: id, taken: now.addingTimeInterval(seconds), quality: quality, framing: framing,
                      smile: smile, samples: samples, hasPeople: hasPeople)
    }

    private func photo(_ id: Int64, _ seconds: TimeInterval) -> AlbumPhoto {
        AlbumPhoto(id: id, path: "\(id).jpg", taken: now.addingTimeInterval(seconds),
                   latitude: 1, longitude: 1, quality: 50)
    }

    private func axis(_ index: Int) -> [Float] {
        var values = [Float](repeating: 0, count: 4)
        values[index] = 1
        return values
    }

    /// Two unit vectors with the given cosine.
    private func pair(cosine: Float) -> ([Float], [Float]) {
        let other = max(0, 1 - cosine * cosine).squareRoot()
        return ([1, 0], [cosine, other])
    }

    private func fill(_ value: UInt8) -> CGImage {
        image { _, _ in value }
    }

    private func split(left: UInt8, right: UInt8, vertical: Bool, cut: Double = 0.5) -> CGImage {
        image { x, y in
            let across = vertical ? Double(y) / 64 : Double(x) / 64
            return across < cut ? left : right
        }
    }

    private func image(_ pixel: (Int, Int) -> UInt8) -> CGImage {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                pixels[y * side + x] = pixel(x, y)
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
