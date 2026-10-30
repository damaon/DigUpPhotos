import CoreGraphics
import Testing
@testable import DigUpApple
@testable import DigUpCore

@Suite struct PhotoQualityImageTests {
    /// A picture scores the same as its gray pixels do: the Apple side only reads them.
    @Test func aPictureScoresAsItsGrayPixels() throws {
        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side { pixels[y * side + x] = ((x / 4) + (y / 4)) % 2 == 0 ? 240 : 20 }
        }
        let image = try pixels.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: side, height: side,
                                                 bitsPerComponent: 8, bytesPerRow: side,
                                                 space: CGColorSpaceCreateDeviceGray(),
                                                 bitmapInfo: CGImageAlphaInfo.none.rawValue))
            return try #require(context.makeImage())
        }
        let gray = PhotoQuality.Gray(width: side, height: side, pixels: pixels)
        #expect(PhotoQuality.assess(image, detectFaces: false) == PhotoQuality.assess(gray, faceBoxes: []))
    }
}
