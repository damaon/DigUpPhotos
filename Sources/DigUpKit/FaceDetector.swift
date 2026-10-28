import CoreGraphics
import CoreML
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// A face found in a photo: normalized Vision box and a cropped JPEG for the embedding model.
public struct DetectedFace: Sendable {
    /// Vision bounding box (normalized, origin bottom-left).
    public let box: CGRect
    /// Path to a square-ish JPEG crop written for EmbeddingGemma.
    public let path: String
}

public enum FaceDetector {
    /// Bump when face crops change. Photo embeddings stay; only the face rows are redone.
    /// 2: crops from a bigger copy of the photo, less margin, 140 tokens (2026-10-28).
    static let version = 2
    /// Most faces worth naming: the biggest ones on a crowd photo are kept.
    static let maxFaces = 12
    /// Soft tokens for a face crop. 140 rather than 70 tells people apart better (fewer mixed-up people, 2026-10-28)
    /// for twice the time per face.
    public static let embedBudget = 140

    /// Face rectangles, largest first. Runs on the CPU: the Neural Engine compiler can stay busy for hours,
    /// and a request that waits on it never returns, so indexing never starts.
    static func observations(in image: CGImage) -> [VNFaceObservation] {
        let request = VNDetectFaceRectanglesRequest()
        if let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { return true }; return false }) {
            request.setComputeDevice(cpu, for: .main)
        }
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? [])
            .sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
    }

    /// 0…1 smile of the largest face, from the shape of the mouth. Nil when no face has a readable mouth.
    /// Used only to pick a frame inside a stack, so it is not stored and does not change the index.
    static func smile(in image: CGImage) -> Double? {
        let request = VNDetectFaceLandmarksRequest()
        if let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { return true }; return false }) {
            request.setComputeDevice(cpu, for: .main)
        }
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let faces = (request.results ?? [])
            .sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
        for face in faces {
            guard let lips = face.landmarks?.outerLips, lips.pointCount >= 4 else { continue }
            return PhotoStacks.smile(mouth: lips.normalizedPoints)
        }
        return nil
    }

    /// Smile of the largest face in the photo file. Nil when the file or the mouth can't be read.
    static func smile(file path: String) -> Double? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 768,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return smile(in: image)
    }

    /// Margin around Vision's box, relative to its size. Less background, hair and hats in the crop means fewer people
    /// grouped by where they were rather than who they are (2026-10-28, `cropSide`).
    static let cropPad: CGFloat = 0.10
    /// Pixels across a face crop. Crops come from a copy of the photo big enough to have them, not from the index's
    /// 1024-pixel one: a face that's 2% of a group photo is ~100 pixels there.
    static let cropSide = 384

    /// Detects faces in `image` and writes padded crops into `folder`. Tiny detections are dropped. With `source` (the
    /// photo `image` was made from), crops come from a bigger copy of it when the faces are small in `image`.
    static func detect(in image: CGImage, source: CGImageSource? = nil, to folder: URL) throws -> [DetectedFace] {
        // Skip dust / false positives (under ~1.2% of the frame).
        let boxes = observations(in: image).prefix(maxFaces).map(\.boundingBox).filter { $0.width * $0.height >= 0.012 }
        guard !boxes.isEmpty else { return [] }
        let large = source.flatMap { larger(image, from: $0, for: boxes) } ?? image
        return try boxes.map { box in
            DetectedFace(box: box, path: try crop(large, box: box, pad: cropPad, maxPixel: cropSide, to: folder).path)
        }
    }

    /// A copy of the photo in which the smallest of `boxes` is `cropSide` pixels across (at most 4096 pixels long),
    /// or nil when `image` already is one.
    private static func larger(_ image: CGImage, from source: CGImageSource, for boxes: [CGRect]) -> CGImage? {
        let longest = CGFloat(max(image.width, image.height))
        let smallest = boxes.map { max($0.width * CGFloat(image.width), $0.height * CGFloat(image.height)) }.min() ?? 0
        guard smallest > 0 else { return nil }
        let wanted = min(4096, longest * CGFloat(cropSide) / (smallest * (1 + 2 * cropPad)))
        guard wanted > longest * 1.1 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(wanted),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Loads the photo (or its index thumbnail) and detects faces into `folder`.
    static func detect(url: URL, maxPixel: Int = 1536, to folder: URL) throws -> [DetectedFace] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return [] }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return [] }
        return try detect(in: image, to: folder)
    }

    /// The photo at `url`, decoded only as big as it takes for the face at `box` to be `side` pixels across (at most
    /// 4096 long): for a person's thumbnail, without decoding a 48 MP photo whole.
    public static func image(of url: URL, showing box: CGRect, side: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        // Vision's box is in the upright photo: a rotated one (EXIF orientation 5–8) swaps width and height.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var width = Double(properties[kCGImagePropertyPixelWidth] as? Int ?? 0)
        var height = Double(properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
        if (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1) { swap(&width, &height) }
        let face = max(box.width * width, box.height * height)
        guard face > 0 else { return nil }
        let maxPixel = min(4096, Int((max(width, height) * Double(side) / face).rounded()))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Crops `box` (Vision coords) with `pad` relative margin, scaled to at most `maxPixel`.
    private static func crop(_ image: CGImage, box: CGRect, pad: CGFloat, maxPixel: Int, to folder: URL) throws
        -> URL {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        // Vision: origin bottom-left → CoreGraphics top-left.
        var rect = CGRect(x: box.minX * width,
                          y: (1 - box.maxY) * height,
                          width: box.width * width,
                          height: box.height * height)
        let padX = rect.width * pad, padY = rect.height * pad
        rect = rect.insetBy(dx: -padX, dy: -padY)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width >= 16, rect.height >= 16,
              let cropped = image.cropping(to: rect.integral) else {
            throw ExtractError.unreadable("can't crop face")
        }
        // Downscale large face crops so the model stays cheap.
        let outImage: CGImage
        if max(cropped.width, cropped.height) > maxPixel {
            let scale = Double(maxPixel) / Double(max(cropped.width, cropped.height))
            let w = max(1, Int(Double(cropped.width) * scale))
            let h = max(1, Int(Double(cropped.height) * scale))
            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw ExtractError.unreadable("can't scale face")
            }
            context.interpolationQuality = .high
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = context.makeImage() else { throw ExtractError.unreadable("can't scale face") }
            outImage = scaled
        } else {
            outImage = cropped
        }
        let out = folder.appendingPathComponent(UUID().uuidString + ".jpg")
        try ImageExtractor.write(outImage, to: out, png: false)
        return out
    }
}
