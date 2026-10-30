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
