import Foundation

/// A face found in a photo: normalized Vision box and who it is (`FaceIdentity`).
public struct DetectedFace: Sendable {
    /// Vision bounding box (normalized, origin bottom-left).
    public let box: CGRect
    /// SFace's 128 numbers, unit length.
    public let vector: [Float]

    public init(box: CGRect, vector: [Float]) {
        self.box = box
        self.vector = vector
    }
}

public enum FaceDetector {
    /// Bump when face crops change. Photo embeddings stay; only photos that have faces are read again
    /// (`IndexStore.reread`), so a change in which faces are found needs a `PhotoQuality.version` bump too.
    /// 2: crops from a bigger copy of the photo, less margin, 140 tokens (2026-10-28).
    /// 3: a face-recognition model (`FaceIdentity`) instead of EmbeddingGemma (2026-10-30).
    public static let version = 3
    /// Most faces worth naming: the biggest ones on a crowd photo are kept.
    public static let maxFaces = 12
}

/// Who a face is: 128 numbers from SFace (OpenCV Zoo, Apache-2.0), a face-recognition model, for a face lined up by its
/// eyes, nose and mouth (`aligned`). Faces of one person are close whatever they wear or where they are.
///
/// EmbeddingGemma did this before (`FaceDetector.version` 2). It describes a picture, so it grouped a face with
/// whatever was around it: one man's 532 faces in ~1,500 came out as 23 people, and other people on the same photo
/// were put together 3× as often (4.7% vs 1.7% at the same threshold, 2026-10-30).
public enum FaceIdentity {
    public static let dimension = 128
}

extension FaceIdentity {
    /// SFace's input: a face lined up in 112×112 pixels.
    public static let side = 112

    /// Where the eyes, nose tip and mouth corners go in the 112×112 face (left to right as seen, y down): ArcFace's,
    /// which SFace was trained on.
    public static let template: [CGPoint] = [CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014),
                                             CGPoint(x: 56.0252, y: 71.7366), CGPoint(x: 41.5493, y: 92.3655),
                                             CGPoint(x: 70.7299, y: 92.2041)]

    /// A rotation, scale and shift: (x, y) → (c·x − s·y + tx, s·x + c·y + ty).
    public struct Similarity: Sendable, Equatable {
        public var c = 1.0, s = 0.0, tx = 0.0, ty = 0.0

        public func apply(_ point: CGPoint) -> CGPoint {
            let (x, y) = (Double(point.x), Double(point.y))
            return CGPoint(x: c * x - s * y + tx, y: s * x + c * y + ty)
        }

        /// The way back.
        public var inverse: Similarity {
            let scale = c * c + s * s
            guard scale > 0 else { return Similarity() }
            let (ic, is_) = (c / scale, -s / scale)
            return Similarity(c: ic, s: is_, tx: -(ic * tx - is_ * ty), ty: -(is_ * tx + ic * ty))
        }
    }

    /// The similarity that best takes `from` onto `to` (least squares): how a face's five points are lined up with
    /// `template`, on every platform.
    public static func fit(from: [CGPoint], to: [CGPoint]) -> Similarity {
        let n = Double(from.count)
        guard n > 0 else { return Similarity() }
        let meanFrom = (x: from.map { Double($0.x) }.reduce(0, +) / n, y: from.map { Double($0.y) }.reduce(0, +) / n)
        let meanTo = (x: to.map { Double($0.x) }.reduce(0, +) / n, y: to.map { Double($0.y) }.reduce(0, +) / n)
        var dot = 0.0, cross = 0.0, spread = 0.0
        for (p, q) in zip(from, to) {
            let (px, py) = (Double(p.x) - meanFrom.x, Double(p.y) - meanFrom.y)
            let (qx, qy) = (Double(q.x) - meanTo.x, Double(q.y) - meanTo.y)
            dot += px * qx + py * qy
            cross += px * qy - py * qx
            spread += px * px + py * py
        }
        guard spread > 0 else { return Similarity() }
        let (c, s) = (dot / spread, cross / spread)   // scale × cos, scale × sin
        return Similarity(c: c, s: s, tx: meanTo.x - (c * meanFrom.x - s * meanFrom.y),
                          ty: meanTo.y - (s * meanFrom.x + c * meanFrom.y))
    }
}
