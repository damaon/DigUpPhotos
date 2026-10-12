import CoreGraphics
import Foundation
import Testing
@testable import DigUpKit

@Suite struct PhotoQualityTests {
    @Test func flatGrayScoresLow() {
        let image = makeGray(side: 128, value: 128)
        let quality = PhotoQuality.assess(image, detectFaces: false)
        #expect(quality.contrast < 0.15)
        #expect(quality.sharpness < 0.15)
        #expect(quality.score < 45)
        #expect(quality.faces == 0)
    }

    @Test func crispCheckerboardScoresHigherThanBlur() {
        let crisp = makeCheckerboard(side: 128, cell: 4)
        let soft = makeCheckerboard(side: 128, cell: 32)
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
        let quality = PhotoQuality(score: 82, sharpness: 0.8, exposure: 0.7, contrast: 0.6, faces: 1)
        #expect(quality.infoFields["quality"] == "82")
        #expect(quality.infoFields["quality_v"] == "\(PhotoQuality.version)")
        #expect(Searcher.wantsNicePhotos("best photos of the beach"))
        #expect(Searcher.wantsNicePhotos("najładniejsze zdjęcia z żoną"))
        #expect(!Searcher.wantsNicePhotos("dog on the beach"))
        #expect(Searcher.terms("best photos of dinner") == ["dinner"])
    }

    @Test func fingerprintMentionsQualityVersion() {
        #expect(IndexOptions().fingerprint.contains("q\(PhotoQuality.version)"))
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
}
