import CoreGraphics
import DigUpCore
import Foundation

extension PhotoQuality {
    /// Assess a photo thumbnail (the same one DigUp embeds). Faces are detected when `detectFaces` is on.
    /// `faceBoxes` skips that detection (the indexer already has them from `FaceDetector`).
    public static func assess(_ image: CGImage, detectFaces: Bool = true, faceBoxes knownFaces: [CGRect]? = nil) -> PhotoQuality {
        let side = 256
        guard let gray = grayscale(image, maxSide: side) else {
            return PhotoQuality(score: 0, sharpness: 0, exposure: 0, contrast: 0, faces: 0, framing: 1)
        }
        let faceBoxes = knownFaces ?? (detectFaces ? FaceDetector.observations(in: image).map(\.boundingBox) : [])
        return assess(gray, faceBoxes: faceBoxes)
    }

    private static func grayscale(_ image: CGImage, maxSide: Int) -> Gray? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        return Gray(width: width, height: height, pixels: pixels)
    }
}
