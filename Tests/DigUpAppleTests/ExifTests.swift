import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DigUpCore

/// The portable EXIF reader (what Linux uses) reads what ImageIO wrote, in JPEG and TIFF.
@Suite struct ExifTests {
    @Test(arguments: [UTType.jpeg, .tiff, .heic])
    func readsWhatImageIOWrote(type: UTType) throws {
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:07:14 18:03:27"],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 33.8688, kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 151.2093, kCGImagePropertyGPSLongitudeRef: "E",
            ],
        ]
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try Self.picture(), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let exif = Exif.parse([UInt8](data as Data))
        if type == .heic {
            #expect(exif == Exif()) // not read: HEIC needs libheif (and ImageIO on macOS)
            return
        }
        #expect(exif.taken == "2024:07:14 18:03:27")
        #expect(exif.orientation == 6)
        #expect(abs((exif.latitude ?? 0) + 33.8688) < 1e-4)
        #expect(abs((exif.longitude ?? 0) - 151.2093) < 1e-4)
    }

    /// WebP keeps EXIF in a RIFF chunk of its own, after the picture or before it, with "Exif\0\0" or without.
    @Test(arguments: [true, false])
    func readsWebPsChunk(prefixed: Bool) throws {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try Self.picture(), [
            kCGImagePropertyOrientation: 8,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2021:01:02 03:04:05"],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        func chunk(_ name: String, _ body: [UInt8]) -> [UInt8] {
            let size = UInt32(body.count)
            return Array(name.utf8) + [0, 8, 16, 24].map { UInt8(size >> UInt32($0) & 0xFF) } + body
                + (body.count % 2 == 1 ? [0] : [])
        }
        let exif = chunk("EXIF", (prefixed ? Array("Exif\0\0".utf8) : []) + [UInt8](data as Data))
        let body = Array("WEBP".utf8) + chunk("VP8X", [UInt8](repeating: 0, count: 10)) + chunk("VP8 ", [1, 2, 3]) + exif
        let file = Array("RIFF".utf8) + [0, 8, 16, 24].map { UInt8(UInt32(body.count) >> UInt32($0) & 0xFF) } + body
        let read = Exif.parse(file)
        #expect(read.taken == "2021:01:02 03:04:05")
        #expect(read.orientation == 8)
    }

    /// A raw photo's preview: the biggest baseline JPEG in it, not its thumbnail or its lossless-JPEG sensor data.
    @Test func findsARawsBiggestPreview() throws {
        func jpeg(_ width: Int, _ height: Int) throws -> [UInt8] {
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
            #expect(CGImageDestinationFinalize(destination))
            return [UInt8](data as Data)
        }
        // Sensor data as lossless JPEG (SOF3), as in DNG and CR2: bigger, but no preview.
        let lossless: [UInt8] = [0xFF, 0xD8, 0xFF, 0xC3, 0x00, 0x0B, 0x08, 0x10, 0x00, 0x10, 0x00, 0x01, 0x01, 0x11, 0x00]
            + [UInt8](repeating: 0x55, count: 64) + [0xFF, 0xD9]
        let thumbnail = try jpeg(40, 30), preview = try jpeg(200, 150)
        let head = Array("II*\0".utf8) + [UInt8](repeating: 0xFF, count: 33)   // stray 0xFF bytes: no JPEG
        let raw = head + thumbnail + lossless + [1, 2, 3] + preview + [UInt8](repeating: 7, count: 100)
        let found = try #require(RawPreview.largestJPEG(raw))
        let start = head.count + thumbnail.count + lossless.count + 3
        #expect(found == RawPreview.Found(range: start..<(start + preview.count), width: 200, height: 150))
        #expect(RawPreview.largestJPEG(head + lossless) == nil)
        #expect(RawPreview.largestJPEG(Array(preview.dropLast(2))) == nil)   // cut off: no end of image
    }

    @Test func nothingToReadIsEmpty() {
        #expect(Exif.parse([]) == Exif())
        #expect(Exif.parse([0xFF, 0xD8, 0xFF]) == Exif())
        #expect(Exif.parse(Array("plain text".utf8)) == Exif())
        // A JPEG cut off right after its EXIF header: bounds checks, no crash.
        #expect(Exif.parse([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x40] + Array("Exif\0\0MM\0*\0\0\0\u{8}".utf8)) == Exif())
    }

    static func picture() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        return try #require(context.makeImage())
    }
}
