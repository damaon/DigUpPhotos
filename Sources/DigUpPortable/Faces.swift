import DigUpCore
import Foundation

/// Faces without Vision: YuNet (OpenCV Zoo) finds each face with its eyes, nose tip and mouth corners, and SFace, the
/// model macOS runs on Core ML, tells who it is. The face is lined up with `FaceIdentity.fit` as on macOS, so a face
/// gets nearly the vector it gets there. scripts/build-onnx.sh fetches both models and ONNX Runtime.
enum PortableFaces {
    /// `$DIGUP_FACES`, then next to the language model, then where scripts/build-onnx.sh leaves them.
    static var folders: [URL] {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return [ProcessInfo.processInfo.environment["DIGUP_FACES"].map { URL(fileURLWithPath: $0) },
                ModelFiles.installed, package.appendingPathComponent("Vendor/sface")].compactMap { $0 }
    }

    private static func model(_ name: String, input: String, outputs: [String]) -> OnnxModel? {
        folders.lazy.compactMap { OnnxModel($0.appendingPathComponent(name), input: input, outputs: outputs) }.first
    }

    static let strides = [8, 16, 32]
    static let detector = model("yunet.onnx", input: "input",
                                outputs: ["cls", "obj", "bbox", "kps"].flatMap { kind in strides.map { "\(kind)_\($0)" } })
    static let identity = model("sface.onnx", input: "data", outputs: ["fc1"])

    /// Whether faces can be found and told apart here; without the models, photos are indexed without faces.
    static var isAvailable: Bool { detector != nil && identity != nil }

    /// YuNet's input side: the picture is shrunk into it, and the rest left black.
    static let inputSide = 640
    /// Lower than OpenCV's 0.9, toward what Vision finds; tiny faces are dropped by size anyway (below).
    static let minScore: Float = 0.8

    struct Found {
        var score: Float
        /// In pixels of the picture searched, y down.
        var box: (x: Double, y: Double, width: Double, height: Double)
        /// Eyes, nose tip, mouth corners: left to right as seen, as `FaceIdentity.template` has them.
        var points: [CGPoint]
    }

    /// As `FaceDetector.detect` on macOS: faces in `picture` (the copy indexed), largest first, at most `maxFaces`, none
    /// under 1.2% of the frame; small ones read from a bigger copy of `full`.
    static func detect(in picture: Picture, full: Picture) -> [DetectedFace] {
        guard isAvailable else { return [] }
        let width = Double(picture.width), height = Double(picture.height)
        let faces = find(in: picture)
            .sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height }
            .prefix(FaceDetector.maxFaces)
            .filter { $0.box.width * $0.box.height / (width * height) >= 0.012 }
        guard !faces.isEmpty else { return [] }
        // A copy in which the smallest face is `faceSide` pixels across (at most 4096 long), as on macOS.
        let longest = max(width, height)
        let smallest = faces.map { max($0.box.width, $0.box.height) }.min() ?? 0
        let wanted = min(4096, longest * 224 / max(smallest, 1))
        let large = wanted > longest * 1.1 ? full.fitted(in: Int(wanted)) : picture
        let scale = Double(large.width) / width
        return faces.compactMap { face in
            let points = refined(face.points.map { CGPoint(x: Double($0.x) * scale, y: Double($0.y) * scale) },
                                 in: large)
            guard let vector = vector(of: large, points: points) else { return nil }
            let x = max(0, face.box.x / width), y = max(0, face.box.y / height)
            let box = CGRect(x: x, y: max(0, 1 - y - face.box.height / height),
                             width: min(1 - x, face.box.width / width), height: min(1, face.box.height / height))
            return DetectedFace(box: box, vector: vector)
        }
    }

    /// The five points found again in a crop around them (three faces wide), where the face is a few hundred pixels
    /// across rather than the tens it can be in the whole photo shrunk to `inputSide`. The original points when the
    /// face isn't found there.
    static func refined(_ points: [CGPoint], in picture: Picture) -> [CGPoint] {
        let xs = points.map { Double($0.x) }, ys = points.map { Double($0.y) }
        let centre = (x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
        let span = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        let side = Int((span * 6).rounded())
        guard side >= 16 else { return points }
        let left = Int(centre.x) - side / 2, top = Int(centre.y) - side / 2
        var pixels = [UInt8](repeating: 0, count: side * side * 3)
        for y in 0..<side where top + y >= 0 && top + y < picture.height {
            for x in 0..<side where left + x >= 0 && left + x < picture.width {
                let from = ((top + y) * picture.width + left + x) * 3, to = (y * side + x) * 3
                pixels[to] = picture.pixels[from]; pixels[to + 1] = picture.pixels[from + 1]
                pixels[to + 2] = picture.pixels[from + 2]
            }
        }
        let local = (x: centre.x - Double(left), y: centre.y - Double(top))
        let nearest = find(in: Picture(width: side, height: side, pixels: pixels)).min { a, b in
            hypot(a.box.x + a.box.width / 2 - local.x, a.box.y + a.box.height / 2 - local.y)
                < hypot(b.box.x + b.box.width / 2 - local.x, b.box.y + b.box.height / 2 - local.y)
        }
        guard let nearest, hypot(nearest.box.x + nearest.box.width / 2 - local.x,
                                 nearest.box.y + nearest.box.height / 2 - local.y) < span else { return points }
        return nearest.points.map { CGPoint(x: Double($0.x) + Double(left), y: Double($0.y) + Double(top)) }
    }

    /// YuNet on `picture`: every face over `minScore`, overlaps merged (IoU 0.3, as OpenCV's FaceDetectorYN).
    static func find(in picture: Picture) -> [Found] {
        guard let detector else { return [] }
        let side = inputSide
        let small = picture.fitted(in: side)
        let scale = Double(picture.width) / Double(small.width)
        // BGR, 0–255, planes one after another; black past the picture.
        var input = [Float](repeating: 0, count: 3 * side * side)
        for y in 0..<small.height {
            for x in 0..<small.width {
                let from = (y * small.width + x) * 3, to = y * side + x
                input[to] = Float(small.pixels[from + 2])
                input[side * side + to] = Float(small.pixels[from + 1])
                input[2 * side * side + to] = Float(small.pixels[from])
            }
        }
        guard let out = detector.run(input, shape: [1, 3, Int64(side), Int64(side)]) else { return [] }
        var found: [Found] = []
        for (level, stride) in strides.enumerated() {
            let (cls, obj, bbox, kps) = (out[level], out[3 + level], out[6 + level], out[9 + level])
            let columns = side / stride
            for index in cls.indices {
                let score = (min(max(cls[index], 0), 1) * min(max(obj[index], 0), 1)).squareRoot()
                guard score >= minScore else { continue }
                let (column, row) = (Double(index % columns), Double(index / columns))
                let s = Double(stride)
                let cx = (column + Double(bbox[index * 4])) * s, cy = (row + Double(bbox[index * 4 + 1])) * s
                let w = exp(Double(bbox[index * 4 + 2])) * s, h = exp(Double(bbox[index * 4 + 3])) * s
                let points = (0..<5).map { n in
                    CGPoint(x: (Double(kps[index * 10 + 2 * n]) + column) * s * scale,
                            y: (Double(kps[index * 10 + 2 * n + 1]) + row) * s * scale)
                }
                found.append(Found(score: score, box: ((cx - w / 2) * scale, (cy - h / 2) * scale, w * scale, h * scale),
                                   points: points))
            }
        }
        var kept: [Found] = []
        for face in found.sorted(by: { $0.score > $1.score }) where !kept.contains(where: { overlap($0, face) > 0.3 }) {
            kept.append(face)
        }
        return kept
    }

    private static func overlap(_ a: Found, _ b: Found) -> Double {
        let x0 = max(a.box.x, b.box.x), y0 = max(a.box.y, b.box.y)
        let x1 = min(a.box.x + a.box.width, b.box.x + b.box.width)
        let y1 = min(a.box.y + a.box.height, b.box.y + b.box.height)
        let shared = max(0, x1 - x0) * max(0, y1 - y0)
        let union = a.box.width * a.box.height + b.box.width * b.box.height - shared
        return union > 0 ? shared / union : 0
    }

    /// SFace's 128 numbers (unit length) for the face whose five points in `picture` are `points`.
    static func vector(of picture: Picture, points: [CGPoint]) -> [Float]? {
        guard let identity else { return nil }
        let face = aligned(picture, points: points)
        // RGB, 0–255, planes one after another.
        let plane = FaceIdentity.side * FaceIdentity.side
        var input = [Float](repeating: 0, count: 3 * plane)
        for index in 0..<plane {
            for channel in 0..<3 { input[channel * plane + index] = Float(face.pixels[index * 3 + channel]) }
        }
        let side = Int64(FaceIdentity.side)
        guard let vector = identity.run(input, shape: [1, 3, side, side])?.first,
              vector.count == FaceIdentity.dimension else { return nil }
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : nil
    }

    /// The 112×112 face with its five points where `FaceIdentity.template` has them (bilinear; black outside).
    static func aligned(_ picture: Picture, points: [CGPoint]) -> Picture {
        let side = FaceIdentity.side
        let back = FaceIdentity.fit(from: points, to: FaceIdentity.template).inverse
        var out = [UInt8](repeating: 0, count: side * side * 3)
        for v in 0..<side {
            for u in 0..<side {
                // The centre of output pixel (u, v), in the picture, where pixel centres are at +0.5.
                let source = back.apply(CGPoint(x: Double(u) + 0.5, y: Double(v) + 0.5))
                let x = Double(source.x) - 0.5, y = Double(source.y) - 0.5
                let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
                let fx = x - Double(x0), fy = y - Double(y0)
                for channel in 0..<3 {
                    func at(_ px: Int, _ py: Int) -> Double {
                        guard px >= 0, py >= 0, px < picture.width, py < picture.height else { return 0 }
                        return Double(picture.pixels[(py * picture.width + px) * 3 + channel])
                    }
                    let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
                    let bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
                    out[(v * side + u) * 3 + channel] = UInt8(min(255, max(0, (top * (1 - fy) + bottom * fy).rounded())))
                }
            }
        }
        return Picture(width: side, height: side, pixels: out)
    }
}
