import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision
import DigUpCore

extension FaceIdentity {
    /// The compiled model: in the app's Resources (next to the helper's folder), or where scripts/build-sface.sh
    /// leaves it for `digup` and the tests run from the package.
    static var modelURL: URL? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            ProcessInfo.processInfo.environment["DIGUP_SFACE"].map { URL(fileURLWithPath: $0) },
            executable.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/SFace.mlmodelc"),
            package.appendingPathComponent("Vendor/sface/SFace.mlmodelc"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// On the CPU, like Vision here (`FaceDetector.observations`): ~7 ms a face, and no Neural Engine compile to wait on.
    // Loaded once, then only used under `lock`.
    nonisolated(unsafe) private static let model: MLModel? = {
        guard let url = modelURL else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        return try? MLModel(contentsOf: url, configuration: configuration)
    }()
    private static let lock = NSLock()

    /// Whether faces can be told apart here. Without the model, photos are indexed without faces.
    public static var isAvailable: Bool { model != nil }

    /// Each face's identity (unit length), in the order of `boxes` (Vision's, normalized); nil for one that can't be
    /// read. `image` is the upright photo the boxes are in.
    static func vectors(in image: CGImage, boxes: [CGRect]) -> [[Float]?] {
        guard let model, !boxes.isEmpty else { return boxes.map { _ in nil } }
        let points = landmarks(in: image, boxes: boxes)
        return zip(boxes, points).map { box, marks in
            guard let face = aligned(image, points: marks ?? estimated(box, in: image)),
                  let input = try? MLFeatureValue(cgImage: face, pixelsWide: side, pixelsHigh: side,
                                                  pixelFormatType: kCVPixelFormatType_32BGRA, options: nil),
                  let features = try? MLDictionaryFeatureProvider(dictionary: ["face": input])
            else { return nil }
            let output = lock.withLock { try? model.prediction(from: features) }
            guard let array = output?.featureValue(for: "vector")?.multiArrayValue, array.count == dimension
            else { return nil }
            let vector = (0..<dimension).map { array[$0].floatValue }
            let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return norm > 0 ? vector.map { $0 / norm } : nil
        }
    }

    /// Eyes, nose tip and mouth corners of each face, in pixels (y down); nil where Vision finds no landmarks.
    static func landmarks(in image: CGImage, boxes: [CGRect]) -> [[CGPoint]?] {
        let request = VNDetectFaceLandmarksRequest()
        if let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { return true }; return false }) {
            request.setComputeDevice(cpu, for: .main)
        }
        request.inputFaceObservations = boxes.map { VNFaceObservation(boundingBox: $0) }
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let size = CGSize(width: image.width, height: image.height)
        let found = request.results ?? []
        return boxes.map { box in
            // Each given face comes back with its landmarks; the nearest box is it.
            let face = found.min { distance($0.boundingBox, box) < distance($1.boundingBox, box) }
            guard let face, distance(face.boundingBox, box) < 0.01, let marks = face.landmarks,
                  let left = marks.leftPupil, let right = marks.rightPupil, let crest = marks.noseCrest,
                  let lips = marks.outerLips else { return nil }
            func points(_ region: VNFaceLandmarkRegion2D) -> [CGPoint] {
                region.pointsInImage(imageSize: size).map { CGPoint(x: $0.x, y: size.height - $0.y) }
            }
            let eyes = (points(left) + points(right)).sorted { $0.x < $1.x }
            let mouth = points(lips)
            guard eyes.count >= 2, let nose = points(crest).max(by: { $0.y < $1.y }),
                  let mouthLeft = mouth.min(by: { $0.x < $1.x }), let mouthRight = mouth.max(by: { $0.x < $1.x })
            else { return nil }
            return [eyes.first!, eyes.last!, nose, mouthLeft, mouthRight]
        }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    /// Where the five points would be on an upright face filling `box`, when Vision gives no landmarks.
    static func estimated(_ box: CGRect, in image: CGImage) -> [CGPoint] {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let face = CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
        return [(0.32, 0.40), (0.68, 0.40), (0.50, 0.60), (0.36, 0.80), (0.64, 0.80)].map {
            CGPoint(x: face.minX + face.width * $0.0, y: face.minY + face.height * $0.1)
        }
    }

    /// The 112×112 face with its five points where `template` has them.
    static func aligned(_ image: CGImage, points: [CGPoint]) -> CGImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        // The transform is in image coordinates (y down); Core Graphics draws y up, in the face and in the photo.
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        context.concatenate(similarity(from: points, to: template))
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// `FaceIdentity.fit` as Core Graphics takes it.
    static func similarity(from: [CGPoint], to: [CGPoint]) -> CGAffineTransform {
        let t = fit(from: from, to: to)
        return CGAffineTransform(a: t.c, b: t.s, c: -t.s, d: t.c, tx: t.tx, ty: t.ty)
    }
}
