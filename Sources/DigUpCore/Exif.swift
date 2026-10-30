import Foundation

/// The few EXIF fields indexing needs, read straight from the file: where ImageIO isn't there to read them
/// (`DigUpPortable`). JPEG (the APP1 segment) and TIFF-based files (TIFF, DNG and most raw formats) are read; anything
/// else, or a file without EXIF, gives empty fields.
public struct Exif: Sendable, Equatable {
    /// `DateTimeOriginal` as written: "YYYY:MM:DD HH:MM:SS".
    public var taken: String?
    public var latitude: Double?
    public var longitude: Double?
    /// 1 (as stored) to 8; how to turn the stored pixels upright.
    public var orientation = 1

    public init(taken: String? = nil, latitude: Double? = nil, longitude: Double? = nil, orientation: Int = 1) {
        self.taken = taken
        self.latitude = latitude
        self.longitude = longitude
        self.orientation = orientation
    }

    public var capture: CaptureInfo { CaptureInfo(taken: taken, latitude: latitude, longitude: longitude) }

    /// Reads the first 256 KiB, where EXIF sits in every file seen so far.
    public static func read(_ url: URL) -> Exif {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Exif() }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return Exif() }
        return parse([UInt8](data))
    }

    public static func parse(_ bytes: [UInt8]) -> Exif {
        if bytes.starts(with: [0xFF, 0xD8]), let tiff = jpegTIFF(bytes) { return parseTIFF(bytes, at: tiff) }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return parseTIFF(bytes, at: 0)
        }
        return Exif()
    }

    /// Where the TIFF header inside a JPEG's "Exif\0\0" APP1 segment starts.
    private static func jpegTIFF(_ bytes: [UInt8]) -> Int? {
        var at = 2
        while at + 4 <= bytes.count, bytes[at] == 0xFF {
            let marker = bytes[at + 1]
            if marker == 0xD9 || marker == 0xDA { return nil } // end of image, or the pixels: no EXIF before them
            let length = Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            if marker == 0xE1, at + 10 <= bytes.count, Array(bytes[at + 4 ..< at + 10]) == Array("Exif\0\0".utf8) {
                return at + 10
            }
            at += 2 + length
        }
        return nil
    }

    private static func parseTIFF(_ bytes: [UInt8], at base: Int) -> Exif {
        let reader = TIFFReader(bytes: bytes, base: base)
        guard let first = reader.u32(4) else { return Exif() }
        var exif = Exif()
        var exifIFD: Int?
        var gpsIFD: Int?
        reader.entries(at: Int(first)) { tag, entry in
            switch tag {
            case 0x0112: if let value = reader.short(entry), (1...8).contains(value) { exif.orientation = value }
            case 0x8769: exifIFD = reader.long(entry)
            case 0x8825: gpsIFD = reader.long(entry)
            default: break
            }
        }
        if let exifIFD {
            reader.entries(at: exifIFD) { tag, entry in
                if tag == 0x9003, let text = reader.ascii(entry), !text.isEmpty { exif.taken = text }
            }
        }
        if let gpsIFD {
            var latRef = "N", lonRef = "E"
            var latitude: Double?, longitude: Double?
            reader.entries(at: gpsIFD) { tag, entry in
                switch tag {
                case 1: latRef = reader.ascii(entry)?.uppercased() ?? latRef
                case 2: latitude = reader.degrees(entry)
                case 3: lonRef = reader.ascii(entry)?.uppercased() ?? lonRef
                case 4: longitude = reader.degrees(entry)
                default: break
                }
            }
            if let latitude, let longitude {
                let lat = latRef == "S" ? -latitude : latitude
                let lon = lonRef == "W" ? -longitude : longitude
                // Out of range is dropped, as `CaptureInfo.gps` does with ImageIO's reading.
                if abs(lat) <= 90, abs(lon) <= 180 {
                    exif.latitude = lat
                    exif.longitude = lon
                }
            }
        }
        return exif
    }
}

/// Offsets in a TIFF structure are from its header (`base`); every read is bounds-checked, so a broken file gives nil.
private struct TIFFReader {
    let bytes: [UInt8]
    let base: Int
    var little: Bool { bytes.count > base && bytes[base] == 0x49 }

    struct Entry {
        let type: Int
        let count: Int
        /// Where the value is: inline in the entry when it fits in 4 bytes, else at the offset it holds.
        let valueAt: Int
    }

    func u16(_ offset: Int) -> Int? {
        let at = base + offset
        guard offset >= 0, at + 2 <= bytes.count else { return nil }
        return little ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : Int(bytes[at]) << 8 | Int(bytes[at + 1])
    }

    func u32(_ offset: Int) -> UInt32? {
        let at = base + offset
        guard offset >= 0, at + 4 <= bytes.count else { return nil }
        let b = (UInt32(bytes[at]), UInt32(bytes[at + 1]), UInt32(bytes[at + 2]), UInt32(bytes[at + 3]))
        return little ? b.0 | b.1 << 8 | b.2 << 16 | b.3 << 24 : b.0 << 24 | b.1 << 16 | b.2 << 8 | b.3
    }

    func entries(at offset: Int, _ body: (Int, Entry) -> Void) {
        guard let count = u16(offset), count < 1000 else { return }
        for index in 0..<count {
            let at = offset + 2 + index * 12
            guard let tag = u16(at), let type = u16(at + 2), let n = u32(at + 4) else { return }
            let size = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8][type] ?? 1
            let total = size * Int(n)
            let valueAt = total <= 4 ? at + 8 : Int(u32(at + 8) ?? UInt32.max)
            body(tag, Entry(type: type, count: Int(n), valueAt: valueAt))
        }
    }

    func short(_ entry: Entry) -> Int? {
        entry.type == 3 ? u16(entry.valueAt) : entry.type == 4 ? u32(entry.valueAt).map(Int.init) : nil
    }

    func long(_ entry: Entry) -> Int? {
        entry.type == 4 || entry.type == 13 ? u32(entry.valueAt).map(Int.init) : short(entry)
    }

    func ascii(_ entry: Entry) -> String? {
        guard entry.type == 2, entry.count > 0 else { return nil }
        let start = base + entry.valueAt
        guard entry.valueAt >= 0, start + entry.count <= bytes.count else { return nil }
        let text = bytes[start ..< start + entry.count].prefix { $0 != 0 }
        return String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    /// Three rationals, degrees minutes seconds, as decimal degrees.
    func degrees(_ entry: Entry) -> Double? {
        guard entry.type == 5, entry.count >= 3 else { return nil }
        var parts: [Double] = []
        for index in 0..<3 {
            guard let numerator = u32(entry.valueAt + index * 8), let denominator = u32(entry.valueAt + index * 8 + 4),
                  denominator != 0 else { return nil }
            parts.append(Double(numerator) / Double(denominator))
        }
        return parts[0] + parts[1] / 60 + parts[2] / 3600
    }
}
