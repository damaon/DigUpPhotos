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

enum FaceDetector {
    /// Bump when face crops change. Photo embeddings stay; only the face rows are redone.
    static let version = 1
    /// Most faces worth naming; beyond this a crowd photo is skipped for people matching.
    static let maxFaces = 12
    /// Soft tokens for a face crop (same budget as a video frame).
    public static let embedBudget = 70

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

    /// Detects faces in `image` and writes padded crops into `folder`. Tiny detections are dropped.
    static func detect(in image: CGImage, to folder: URL) throws -> [DetectedFace] {
        let observations = observations(in: image).prefix(maxFaces)
        var faces: [DetectedFace] = []
        for observation in observations {
            let box = observation.boundingBox
            // Skip dust / false positives (under ~1.2% of the frame).
            guard box.width * box.height >= 0.012 else { continue }
            let crop = try crop(image, box: box, pad: 0.28, maxPixel: 384, to: folder)
            faces.append(DetectedFace(box: box, path: crop.path))
        }
        return faces
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
