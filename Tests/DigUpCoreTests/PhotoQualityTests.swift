import CoreGraphics
import Foundation
import Testing
@testable import DigUpApple
@testable import DigUpCore

@Suite struct PhotoQualityTests {
    @Test func flatGrayScoresLow() {
        let image = makeGray(side: 128, value: 128)
        let quality = PhotoQuality.assess(image, detectFaces: false)
        #expect(quality.contrast < 0.15)
        #expect(quality.sharpness < 0.15)
        #expect(quality.score < 45)
        #expect(quality.faces == 0)
        #expect(quality.infoFields["q_frame"] == nil)
        #expect(quality.infoFields["q_faces"] == "0")
    }

    @Test func crispCheckerboardScoresHigherThanBlur() {
        let crisp = makeCheckerboard(side: 128, cell: 4)
        // A coarser checkerboard still has hard edges, so Laplacian variance saturates. Blur it.
        let soft = boxBlur(makeCheckerboard(side: 128, cell: 8), radius: 5)
        let a = PhotoQuality.assess(crisp, detectFaces: false)
        let b = PhotoQuality.assess(soft, detectFaces: false)
        #expect(a.sharpness > b.sharpness)
        #expect(a.score > b.score)
    }

    @Test func wellExposedBeatsClipped() {
        let mid = makeGray(side: 64, value: 128)
        let black = makeGray(side: 64, value: 0)
        #expect(PhotoQuality.assess(mid, detectFaces: false).exposure
                > PhotoQuality.assess(black, detectFaces: false).exposure)
    }

    @Test func infoFieldsAndNiceQuery() {
        let quality = PhotoQuality(score: 82, sharpness: 0.8, exposure: 0.7, contrast: 0.6, faces: 1, framing: 0.9)
        #expect(quality.infoFields["quality"] == "82")
        #expect(quality.infoFields["quality_v"] == "\(PhotoQuality.version)")
        #expect(quality.infoFields["q_sharp"] == "80")
        #expect(quality.infoFields["q_light"] == "70")
        #expect(quality.infoFields["q_contrast"] == "60")
        #expect(quality.infoFields["q_frame"] == "90")
        #expect(quality.infoFields["q_faces"] == "1")
        #expect(Searcher.wantsNicePhotos("best photos of the beach"))
        #expect(Searcher.wantsNicePhotos("najładniejsze zdjęcia z żoną"))
        #expect(!Searcher.wantsNicePhotos("dog on the beach"))
        #expect(Searcher.terms("best photos of dinner") == ["dinner"])
        #expect(Searcher.parse("best photos - rice").expression
                == .and([.phrase("best photos"), .not(.phrase("rice"))]))
        #expect(Searcher.embedPhrases("best photos - rice") == ["best photos", "rice"])
        #expect(Searcher.terms("best photos - rice").isEmpty)
        #expect(Searcher.wantsNicePhotos("best photos - rice"))
        #expect(Searcher.kindHints("person - screenshot").isEmpty)
        #expect(Searcher.parse("person - screenshot").expression
                == .and([.phrase("person"), .not(.phrase("screenshot"))]))
        #expect(Searcher.parse("person -screenshot").expression
                == .and([.phrase("person"), .not(.phrase("screenshot"))]))
        #expect(Searcher.parse("person and screenshot").expression
                == .and([.phrase("person"), .phrase("screenshot")]))
        #expect(Searcher.parse("person or screenshot").expression
                == .or([.phrase("person"), .phrase("screenshot")]))
        #expect(Searcher.parse("(person or cat) - screenshot").expression
                == .and([.or([.phrase("person"), .phrase("cat")]), .not(.phrase("screenshot"))]))
        #expect(Searcher.parse("person or cat - screenshot").expression
                == .or([.phrase("person"), .and([.phrase("cat"), .not(.phrase("screenshot"))])]))
        #expect(!Searcher.parse("dinner").hasOperators)
        #expect(Searcher.parse("dinner").positiveText == "dinner")
        #expect(Searcher.embedPhrases("dinner") == ["dinner"])
        #expect(!Searcher.parse("well-known beach").hasOperators)
        #expect(Searcher.embedPhrases("well-known beach") == ["well-known beach"])
        #expect(Searcher.ftsQuery("best photos - rice") == nil)
        #expect(Searcher.terms("photos of anna - rice") == ["anna"])
        let person: [Int64: (z: Double, cosine: Double, row: Int)] = [
            1: (3, 0.5, 0), 2: (1, 0.1, 1), 3: (2.4, 0.4, 2),
        ]
        let screenshot: [Int64: (z: Double, cosine: Double, row: Int)] = [
            1: (1, 0.1, 3), 2: (3, 0.6, 4), 3: (2.2, 0.4, 5),
        ]
        let minus = Searcher.parse("person - screenshot").expression
        #expect(Searcher.evaluate(minus, file: 1, clauses: [person, screenshot], gates: [2, 2]) != nil)
        #expect(Searcher.evaluate(minus, file: 2, clauses: [person, screenshot], gates: [2, 2]) == nil)
        #expect(Searcher.evaluate(minus, file: 3, clauses: [person, screenshot], gates: [2, 2]) == nil)
        let either = Searcher.parse("person or screenshot").expression
        #expect(Searcher.evaluate(either, file: 1, clauses: [person, screenshot], gates: [2, 2]) != nil)
        #expect(Searcher.evaluate(either, file: 2, clauses: [person, screenshot], gates: [2, 2]) != nil)
        let both = Searcher.parse("person and screenshot").expression
        #expect(Searcher.evaluate(both, file: 1, clauses: [person, screenshot], gates: [2, 2]) == nil)
        let bothHit = Searcher.evaluate(both, file: 3, clauses: [person, screenshot], gates: [2, 2])
        #expect(bothHit?.z == 2.2)
    }

    @Test func fingerprintMentionsQualityVersion() {
        #expect(IndexOptions().fingerprint.contains("q\(PhotoQuality.version)"))
        let options = IndexOptions()
        #expect(!options.vectorFingerprint.contains("q\(PhotoQuality.version)"))
        let current = IndexStamp.parse("model | \(options.fingerprint)")
        #expect(current.vectors == options.vectorFingerprint)
        #expect(current.quality == PhotoQuality.version)
        var photos = options
        photos.kinds = FileKind.photosAndVideo
        let withKinds = IndexStamp.parse("model | \(photos.fingerprint)")
        #expect(withKinds.sameEmbeddings(as: current))
        let older = IndexStamp.parse("model | \(options.vectorFingerprint) q1 f1")
        #expect(older.sameEmbeddings(as: current))
        #expect(older.quality == 1)
    }

    // MARK: Synthetic images

    private func makeGray(side: Int, value: UInt8) -> CGImage {
        var pixels = [UInt8](repeating: value, count: side * side)
        return pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                    bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            return context.makeImage()!
        }
    }

    private func makeCheckerboard(side: Int, cell: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let on = ((x / cell) + (y / cell)) % 2 == 0
                pixels[y * side + x] = on ? 240 : 20
            }
        }
        return pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                    bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            return context.makeImage()!
        }
    }

    /// Averages each pixel with a square neighborhood so edges stop being one-pixel steps.
    private func boxBlur(_ image: CGImage, radius: Int) -> CGImage {
        let side = image.width
        guard side == image.height, side > 0, let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return image }
        var source = [UInt8](repeating: 0, count: side * side)
        for index in 0..<source.count { source[index] = bytes[index] }
        var pixels = [UInt8](repeating: 0, count: side * side)
        let window = radius * 2 + 1
        for y in 0..<side {
            for x in 0..<side {
                var sum = 0
                for dy in -radius...radius {
                    let yy = min(max(y + dy, 0), side - 1)
                    for dx in -radius...radius {
                        let xx = min(max(x + dx, 0), side - 1)
                        sum += Int(source[yy * side + xx])
                    }
                }
                pixels[y * side + x] = UInt8(sum / (window * window))
            }
        }
        return pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                    bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            return context.makeImage()!
        }
    }
}
