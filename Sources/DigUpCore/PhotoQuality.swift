import Foundation

/// How good a photo looks, from cheap local signals (no cloud, no extra model).
///
/// Combines sharpness, exposure, contrast, and (when faces are present) how well they're framed.
/// Landscapes without faces are not penalized. Score is 0…100 for sorting and a light search boost.
public struct PhotoQuality: Sendable, Equatable {
    /// Overall score, 0…100.
    public let score: Int
    /// Laplacian variance mapped to 0…1 (blurry → crisp).
    public let sharpness: Double
    /// How close luminance is to a well-exposed midtone, 0…1.
    public let exposure: Double
    /// Luminance spread, 0…1.
    public let contrast: Double
    /// How well a face fills and sits in the frame, 0…1. Neutral (1) when there is no face.
    public let framing: Double
    /// Faces Vision found (0 when detection was skipped or none).
    public let faces: Int

    /// Version stamp stored in `info` / the index fingerprint when scoring changes.
    public static let version = 2

    public init(score: Int, sharpness: Double, exposure: Double, contrast: Double, faces: Int, framing: Double = 1) {
        self.score = score
        self.sharpness = sharpness
        self.exposure = exposure
        self.contrast = contrast
        self.framing = framing
        self.faces = faces
    }

    /// Stored on the file. Component scores are 0…100. `q_frame` is omitted when no face was found, so a landscape
    /// is not shown as if it were composed around a person.
    public var infoFields: [String: String] {
        var fields = [
            "quality": "\(score)",
            "quality_v": "\(Self.version)",
            "q_sharp": "\(Self.percent(sharpness))",
            "q_light": "\(Self.percent(exposure))",
            "q_contrast": "\(Self.percent(contrast))",
            "q_faces": "\(faces)",
        ]
        if faces > 0 { fields["q_frame"] = "\(Self.percent(framing))" }
        return fields
    }

    private static func percent(_ value: Double) -> Int {
        Int((value * 100).rounded().clamped(to: 0...100))
    }

    /// Scores a photo from its pixels in grayscale (`gray`, at most 256 on a side: the thumbnail DigUp embeds,
    /// shrunk) and the faces found on it (normalized boxes, origin bottom-left).
    public static func assess(_ gray: Gray, faceBoxes: [CGRect]) -> PhotoQuality {
        let (sharp, exposure, contrast) = metrics(gray)
        // Landscapes (no faces): face term stays neutral at 1 so they aren't ranked down.
        let framing = faceBoxes.isEmpty ? 1.0 : faceFraming(faceBoxes)
        let combined = 0.40 * sharp + 0.25 * exposure + 0.20 * contrast + 0.15 * framing
        let score = Int((combined * 100).rounded().clamped(to: 0...100))
        return PhotoQuality(score: score, sharpness: sharp, exposure: exposure, contrast: contrast,
                            faces: faceBoxes.count, framing: framing)
    }

    // MARK: Pixels

    /// A picture as 8-bit gray, row by row.
    public struct Gray {
        public let width: Int
        public let height: Int
        public let pixels: [UInt8]

        public init(width: Int, height: Int, pixels: [UInt8]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }
    }

    private static func metrics(_ gray: Gray) -> (sharpness: Double, exposure: Double, contrast: Double) {
        let n = gray.pixels.count
        guard n > 0 else { return (0, 0, 0) }
        var sum = 0.0, sumSq = 0.0
        var dark = 0, bright = 0
        for value in gray.pixels {
            let x = Double(value) / 255
            sum += x
            sumSq += x * x
            if value <= 8 { dark += 1 }
            if value >= 247 { bright += 1 }
        }
        let mean = sum / Double(n)
        let variance = max(0, sumSq / Double(n) - mean * mean)
        let std = variance.squareRoot()
        // Well-exposed midtones; heavy clipping hurts.
        let mid = 1 - min(1, abs(mean - 0.48) / 0.48)
        let clip = Double(dark + bright) / Double(n)
        let exposure = (0.75 * mid + 0.25 * (1 - min(1, clip * 4))).clamped(to: 0...1)
        // Typical photo stddev sits around 0.12–0.25; flat UI greys and fog score low.
        let contrast = (std / 0.22).clamped(to: 0...1)

        // Laplacian variance on the interior (skip a 1-px border).
        var lapSum = 0.0, lapSumSq = 0.0, lapCount = 0
        if gray.width >= 3, gray.height >= 3 {
            for y in 1..<(gray.height - 1) {
                for x in 1..<(gray.width - 1) {
                    let i = y * gray.width + x
                    let lap = Int(gray.pixels[i]) * 4
                        - Int(gray.pixels[i - 1]) - Int(gray.pixels[i + 1])
                        - Int(gray.pixels[i - gray.width]) - Int(gray.pixels[i + gray.width])
                    let v = Double(lap)
                    lapSum += v
                    lapSumSq += v * v
                    lapCount += 1
                }
            }
        }
        let lapVar: Double
        if lapCount > 0 {
            let mu = lapSum / Double(lapCount)
            lapVar = max(0, lapSumSq / Double(lapCount) - mu * mu)
        } else {
            lapVar = 0
        }
        // Empirically: soft phone blur ~50–200, crisp detail often 400–2000+ on this scale.
        let sharpness = (lapVar / 800).clamped(to: 0...1)
        return (sharpness, exposure, contrast)
    }

    // MARK: Faces

    /// 0…1 how well faces fill and sit in the frame.
    private static func faceFraming(_ faces: [CGRect]) -> Double {
        guard !faces.isEmpty else { return 1 }
        var best = 0.0
        for box in faces {
            // Vision: normalized, origin bottom-left.
            let area = box.width * box.height
            // Tiny faces in the corner score low; a headshot around 8–35% of the frame is ideal.
            let sizeScore: Double
            switch area {
            case 0.04...0.40: sizeScore = 1
            case 0.015..<0.04: sizeScore = 0.6
            case 0.40..<0.65: sizeScore = 0.7
            default: sizeScore = 0.25
            }
            let center = 1 - min(1, hypot(box.midX - 0.5, box.midY - 0.5) / 0.75)
            let margin = min(box.minX, box.minY, 1 - box.maxX, 1 - box.maxY)
            let edge = margin < 0.02 ? 0.35 : 1.0
            best = max(best, 0.50 * sizeScore + 0.30 * center + 0.20 * edge)
        }
        let crowd = faces.count <= 4 ? 1.0 : 0.85
        return (best * crowd).clamped(to: 0...1)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
