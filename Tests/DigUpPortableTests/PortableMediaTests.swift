import DigUpCore
import Foundation
import Testing
@testable import DigUpPortable

@Suite struct PortableMediaTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("portable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Stored 3×2, each pixel's red its index: where each one lands once turned upright.
    @Test(arguments: [
        (1, 3, [0, 1, 2, 3, 4, 5]),
        (2, 3, [2, 1, 0, 5, 4, 3]),   // mirrored
        (3, 3, [5, 4, 3, 2, 1, 0]),   // turned 180°
        (4, 3, [3, 4, 5, 0, 1, 2]),   // flipped
        (5, 2, [0, 3, 1, 4, 2, 5]),   // transposed
        (6, 2, [3, 0, 4, 1, 5, 2]),   // turned 90° clockwise
        (7, 2, [5, 2, 4, 1, 3, 0]),   // transversed
        (8, 2, [2, 5, 1, 4, 0, 3]),   // turned 90° counterclockwise
    ])
    func turnsUpright(orientation: Int, width: Int, reds: [Int]) {
        let stored = Picture(width: 3, height: 2, pixels: (0..<6).flatMap { [UInt8($0), 0, 0] })
        let upright = stored.oriented(orientation)
        #expect(upright.width == width)
        #expect(stride(from: 0, to: upright.pixels.count, by: 3).map { Int(upright.pixels[$0]) } == reds)
    }

    @Test func bmpReadsBackAndShrinksByAveraging() throws {
        // 4×2: a white left half, a black right half, so the 2×1 copy is one white and one black pixel.
        let pixels = (0..<8).flatMap { $0 % 4 < 2 ? [UInt8](repeating: 255, count: 3) : [0, 0, 0] }
        let url = folder.appendingPathComponent("a.bmp")
        try Picture(width: 4, height: 2, pixels: pixels).writeBMP(to: url)
        let read = try #require(Picture.decode(url)).picture
        #expect(read.width == 4 && read.height == 2 && read.pixels == pixels)
        #expect(Picture.size(of: url)! == (4, 2))
        let small = read.fitted(in: 2)
        #expect(small.width == 2 && small.height == 1 && small.pixels == [255, 255, 255, 0, 0, 0])
        #expect(read.fitted(in: 100).width == 4) // never larger
    }

    @Test func imageIsPreparedForTheModel() throws {
        let url = folder.appendingPathComponent("photo.bmp")
        try Picture(width: 300, height: 200, pixels: [UInt8](repeating: 128, count: 300 * 200 * 3)).writeBMP(to: url)
        let prepared = try PortableMedia().image(url, maxPixel: 150, minSide: 100, to: folder, png: false,
                                                 scoreQuality: true, detectFaces: true)
        #expect(prepared.width == 300 && prepared.height == 200)
        #expect(prepared.quality != nil)
        let copy = try #require(Picture.decode(URL(fileURLWithPath: prepared.path))).picture
        #expect(copy.width == 150 && copy.height == 100)
        #expect(throws: ExtractError.self) {
            try PortableMedia().image(url, maxPixel: 150, minSide: 400, to: folder, png: false, scoreQuality: false,
                                      detectFaces: false)
        }
    }

    /// As on macOS (FaceIdentityTests): a mark at the photo's left eye ends up at the template's left eye, and the
    /// way back undoes the fit.
    @Test func alignedFaceIsUpright() {
        let (width, height) = (400, 300)
        let points = FaceIdentity.template.map { CGPoint(x: $0.x * 2 + 100, y: $0.y * 2 + 40) }
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        for y in Int(points[0].y) - 6 ..< Int(points[0].y) + 6 {
            for x in Int(points[0].x) - 6 ..< Int(points[0].x) + 6 { pixels[(y * width + x) * 3] = 255 }
        }
        let face = PortableFaces.aligned(Picture(width: width, height: height, pixels: pixels), points: points)
        #expect(face.width == FaceIdentity.side && face.height == FaceIdentity.side)
        func red(_ point: CGPoint) -> UInt8 { face.pixels[(Int(point.y) * face.width + Int(point.x)) * 3] }
        #expect(red(FaceIdentity.template[0]) > 200)
        #expect(red(FaceIdentity.template[4]) < 50)
        let fit = FaceIdentity.fit(from: points, to: FaceIdentity.template)
        for (point, expected) in zip(FaceIdentity.template.map(fit.inverse.apply), points) {
            #expect(abs(point.x - expected.x) < 1e-6 && abs(point.y - expected.y) < 1e-6)
        }
    }

    @Test(.enabled(if: PortableFaces.isAvailable)) func faceVectorsAreUnitLength() throws {
        let gray = Picture(width: 224, height: 224, pixels: [UInt8](repeating: 150, count: 224 * 224 * 3))
        let points = FaceIdentity.template.map { CGPoint(x: $0.x * 2, y: $0.y * 2) }
        let vector = try #require(PortableFaces.vector(of: gray, points: points))
        #expect(vector.count == FaceIdentity.dimension)
        #expect(abs(vector.reduce(0) { $0 + $1 * $1 } - 1) < 0.001)
        #expect(PortableFaces.find(in: gray).isEmpty) // a gray square is no face
    }

    @Test func captureTimesAreWrittenAsOnMacOS() {
        #expect(Probe.internetDate("2024-07-14T18:03:27.000000Z") == "2024-07-14T18:03:27Z")
        #expect(Probe.internetDate("2024-07-14T20:03:27+0200") == "2024-07-14T18:03:27Z")
        #expect(Probe.internetDate("yesterday") == nil)
    }

    static let ffmpeg = Tools.find("ffmpeg") != nil && Tools.find("ffprobe") != nil

    /// Seven seconds of a test picture with a tone: frames a step apart, and the sound in windows.
    @Test(.enabled(if: ffmpeg)) func videoBecomesFramesAndSound() async throws {
        let url = folder.appendingPathComponent("clip.mp4")
        try Tools.run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=10:duration=7",
                                 "-f", "lavfi", "-i", "sine=frequency=440:duration=7", "-shortest",
                                 "-metadata", "creation_time=2024-07-14T18:03:27Z", url.path])
        let media = PortableMedia()
        let video = try await media.keyframes(of: url, every: 3, maxPixel: 160, to: folder)
        #expect(abs(video.duration - 7) < 0.2)
        #expect(video.hasAudio)
        #expect((1...3).contains(video.frames.count))
        #expect(video.frames.first?.start == 0.5)
        #expect(video.frames.last?.end == video.duration)
        let first = try #require(video.frames.first)
        let frame = try #require(Picture.decode(URL(fileURLWithPath: first.path)))
        #expect(frame.picture.width == 160 && frame.picture.height == 120)
        let sound = try await media.audioWindows(of: url, window: 4, hop: 3, to: folder)
        #expect(sound.pieces.map(\.start) == [0, 3])
        #expect(media.capture(of: url).taken == "2024-07-14T18:03:27Z")
        #expect(abs((media.duration(of: url) ?? 0) - 7) < 0.2)
    }
}
