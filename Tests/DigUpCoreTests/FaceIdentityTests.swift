import CoreGraphics
import Testing
@testable import DigUpCore

@Suite struct FaceIdentityTests {
    /// A face turned, smaller and elsewhere in the photo lands on the template: what SFace was trained on.
    @Test func lineUpUndoesTurnScaleAndShift() {
        let turn = CGAffineTransform(rotationAngle: 0.3).scaledBy(x: 2.5, y: 2.5)
            .concatenating(CGAffineTransform(translationX: 400, y: 120))
        let seen = FaceIdentity.template.map { $0.applying(turn) }
        let back = FaceIdentity.similarity(from: seen, to: FaceIdentity.template)
        for (point, expected) in zip(seen.map { $0.applying(back) }, FaceIdentity.template) {
            #expect(abs(point.x - expected.x) < 0.001 && abs(point.y - expected.y) < 0.001)
        }
    }

    /// The face is drawn the right way up: a mark at the left eye of the photo ends up at the template's left eye.
    @Test func alignedFaceIsUpright() throws {
        let width = 400, height = 300
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Points in image coordinates (y down); Core Graphics fills y up.
        let points = FaceIdentity.template.map { CGPoint(x: $0.x * 2 + 100, y: $0.y * 2 + 40) }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: points[0].x - 6, y: CGFloat(height) - points[0].y - 6, width: 12, height: 12))
        let photo = try #require(context.makeImage())
        let face = try #require(FaceIdentity.aligned(photo, points: points))
        #expect(face.width == FaceIdentity.side && face.height == FaceIdentity.side)
        let eye = FaceIdentity.template[0], mouth = FaceIdentity.template[4]
        #expect(try red(face, x: Int(eye.x), y: Int(eye.y)) > 200)
        #expect(try red(face, x: Int(mouth.x), y: Int(mouth.y)) < 50)
    }

    @Test func faceVectorsAreUnitLengthWhenTheModelIsBuilt() throws {
        guard FaceIdentity.isAvailable else { return }   // scripts/build-sface.sh not run here
        let context = try #require(CGContext(data: nil, width: 224, height: 224, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 224, height: 224))
        let box = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let photo = try #require(context.makeImage())
        let vector = try #require(FaceIdentity.vectors(in: photo, boxes: [box]).first ?? nil)
        #expect(vector.count == FaceIdentity.dimension)
        #expect(abs(vector.reduce(0) { $0 + $1 * $1 } - 1) < 0.001)
    }

    /// Red at (x, y), y down.
    private func red(_ image: CGImage, x: Int, y: Int) throws -> UInt8 {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return bytes[0]
    }
}
