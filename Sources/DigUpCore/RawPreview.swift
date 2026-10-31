import Foundation

/// The biggest JPEG a raw photo carries (CR2, CR3, NEF, ARW, DNG, ORF, RW2, RAF, PEF, SRW all embed one, most of them
/// full size, for cameras to show): what a raw is looked at by where nothing decodes the sensor data itself
/// (`DigUpPortable`). Found by walking every JPEG start in the file; lossless JPEG (the raw data of DNG and CR2) is
/// passed over, as are thumbnails when a bigger preview is there.
public enum RawPreview {
    public struct Found: Equatable, Sendable {
        public let range: Range<Int>
        public let width: Int
        public let height: Int
    }

    public static func largestJPEG(in url: URL) -> (bytes: [UInt8], found: Found)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return data.withUnsafeBytes { raw -> (bytes: [UInt8], found: Found)? in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard let found = largestJPEG(bytes) else { return nil }
            return (Array(bytes[found.range]), found)
        }
    }

    public static func largestJPEG<C: RandomAccessCollection<UInt8>>(_ bytes: C) -> Found? where C.Index == Int {
        var best: Found?
        var at = bytes.startIndex
        let end = bytes.endIndex
        while at + 3 < end {
            guard bytes[at] == 0xFF, bytes[at + 1] == 0xD8, bytes[at + 2] == 0xFF else { at += 1; continue }
            if let found = jpeg(bytes, at: at) {
                if found.width * found.height > (best.map { $0.width * $0.height } ?? 0) { best = found }
                at = found.range.upperBound
            } else {
                at += 2
            }
        }
        return best
    }

    /// The JPEG starting at `start`: its size and where it ends, when it's one stb_image and friends decode (baseline
    /// or progressive Huffman).
    static func jpeg<C: RandomAccessCollection<UInt8>>(_ bytes: C, at start: Int) -> Found? where C.Index == Int {
        let end = bytes.endIndex
        var at = start + 2
        var size: (width: Int, height: Int)?
        while at + 4 <= end {
            guard bytes[at] == 0xFF else { return nil }
            let marker = bytes[at + 1]
            if marker == 0xFF { at += 1; continue }   // fill byte
            let length = Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            guard length >= 2, at + 2 + length <= end else { return nil }
            switch marker {
            case 0xC0, 0xC1, 0xC2:
                guard length >= 7 else { return nil }
                size = (Int(bytes[at + 7]) << 8 | Int(bytes[at + 8]), Int(bytes[at + 5]) << 8 | Int(bytes[at + 6]))
            case 0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
                return nil   // lossless, hierarchical or arithmetic-coded: not a preview
            case 0xDA:
                guard let size, size.width > 0, size.height > 0 else { return nil }
                // The entropy-coded data, to the end-of-image marker (0xFF00 is a stuffed byte, 0xFFD0-7 restarts).
                var scan = at + 2 + length
                while scan + 1 < end {
                    if bytes[scan] == 0xFF, bytes[scan + 1] == 0xD9 {
                        return Found(range: start..<(scan + 2), width: size.width, height: size.height)
                    }
                    scan += 1
                }
                return nil
            default:
                break
            }
            at += 2 + length
        }
        return nil
    }
}
