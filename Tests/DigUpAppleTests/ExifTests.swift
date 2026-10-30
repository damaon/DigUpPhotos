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
