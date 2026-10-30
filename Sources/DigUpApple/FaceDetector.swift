import CoreGraphics
import CoreML
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import DigUpCore

extension FaceDetector {
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

    /// Pixels across a face when it's lined up for `FaceIdentity`, which takes 112: from a copy of the photo big enough
    /// to have them, not from the index's 1024-pixel one, where a face that's 2% of a group photo is ~100 pixels.
    static let faceSide: CGFloat = 224

    /// Detects faces in `image` and tells who each one is. Tiny detections are dropped, and so is every face when
    /// there's no face model (`FaceIdentity.isAvailable`). With `source` (the photo `image` was made from), faces are
    /// read from a bigger copy of it when they're small in `image`.
    static func detect(in image: CGImage, source: CGImageSource? = nil) -> [DetectedFace] {
        guard FaceIdentity.isAvailable else { return [] }
        // Skip dust / false positives (under ~1.2% of the frame).
        let boxes = observations(in: image).prefix(maxFaces).map(\.boundingBox).filter { $0.width * $0.height >= 0.012 }
        guard !boxes.isEmpty else { return [] }
        let large = source.flatMap { larger(image, from: $0, for: boxes) } ?? image
        return zip(boxes, FaceIdentity.vectors(in: large, boxes: boxes)).compactMap { box, vector in
            vector.map { DetectedFace(box: box, vector: $0) }
        }
    }

    /// A copy of the photo in which the smallest of `boxes` is `faceSide` pixels across (at most 4096 pixels long),
    /// or nil when `image` already is one.
    private static func larger(_ image: CGImage, from source: CGImageSource, for boxes: [CGRect]) -> CGImage? {
        let longest = CGFloat(max(image.width, image.height))
        let smallest = boxes.map { max($0.width * CGFloat(image.width), $0.height * CGFloat(image.height)) }.min() ?? 0
        guard smallest > 0 else { return nil }
        let wanted = min(4096, longest * faceSide / smallest)
        guard wanted > longest * 1.1 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(wanted),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Loads the photo (or its index thumbnail) and detects faces.
    static func detect(url: URL, maxPixel: Int = 1536) -> [DetectedFace] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return [] }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return [] }
        return detect(in: image)
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
}
