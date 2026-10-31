import Foundation

/// Reads files out of a ZIP archive (docx, odt): the central directory, then each entry stored or deflated. Enough for
/// documents, with nothing to install: no ZIP64, encryption or spanned archives.
public struct ZipArchive {
    public struct Entry {
        public let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localHeader: Int
    }

    let bytes: [UInt8]
    public let entries: [Entry]

    public init?(_ url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(bytes: [UInt8](data))
    }

    public init?(bytes: [UInt8]) {
        self.bytes = bytes
        // The end-of-central-directory record: in the last 64 KiB + 22 bytes (it may carry a comment).
        guard bytes.count >= 22 else { return nil }
        var end = bytes.count - 22
        let stop = max(0, bytes.count - 22 - 65_535)
        while end >= stop, !(bytes[end] == 0x50 && bytes[end + 1] == 0x4B && bytes[end + 2] == 5 && bytes[end + 3] == 6) {
            end -= 1
        }
        guard end >= stop else { return nil }
        let count = Self.u16(bytes, end + 10)
        var at = Int(Self.u32(bytes, end + 16))
        var entries: [Entry] = []
        for _ in 0..<count {
            guard at + 46 <= bytes.count, Self.u32(bytes, at) == 0x0201_4B50 else { return nil }
            let nameLength = Int(Self.u16(bytes, at + 28))
            let extra = Int(Self.u16(bytes, at + 30)), comment = Int(Self.u16(bytes, at + 32))
            guard at + 46 + nameLength <= bytes.count else { return nil }
            entries.append(Entry(name: String(decoding: bytes[at + 46 ..< at + 46 + nameLength], as: UTF8.self),
                                 method: Self.u16(bytes, at + 10), compressedSize: Int(Self.u32(bytes, at + 20)),
                                 size: Int(Self.u32(bytes, at + 24)), localHeader: Int(Self.u32(bytes, at + 42))))
            at += 46 + nameLength + extra + comment
        }
        self.entries = entries
    }

    /// The entry's bytes; nil when it isn't there or can't be read.
    public func read(_ name: String) -> [UInt8]? {
        guard let entry = entries.first(where: { $0.name == name }) else { return nil }
        let at = entry.localHeader
        guard at + 30 <= bytes.count, Self.u32(bytes, at) == 0x0403_4B50 else { return nil }
        let start = at + 30 + Int(Self.u16(bytes, at + 26)) + Int(Self.u16(bytes, at + 28))
        guard start + entry.compressedSize <= bytes.count else { return nil }
        let data = bytes[start ..< start + entry.compressedSize]
        switch entry.method {
        case 0: return Array(data)
        case 8: return Inflate.inflate(data, expected: entry.size)
        default: return nil
        }
    }

    static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
    static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 { UInt32(u16(bytes, at)) | UInt32(u16(bytes, at + 2)) << 16 }
}

/// Raw DEFLATE (RFC 1951), as ZIP stores it.
enum Inflate {
    /// Nil on a broken stream.
    static func inflate(_ input: ArraySlice<UInt8>, expected: Int = 0) -> [UInt8]? {
        var state = State(input: Array(input))
        state.output.reserveCapacity(expected)
        return state.run() ? state.output : nil
    }

    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []

        init(lengths: ArraySlice<Int>) {
            for length in lengths { counts[length] += 1 }
            counts[0] = 0
            var offsets = [Int](repeating: 0, count: 16)
            for bits in 1..<16 { offsets[bits] = offsets[bits - 1] + counts[bits - 1] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (symbol, length) in lengths.enumerated() where length != 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
        }
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99,
                                     115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025,
                                       1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
                                        12, 12, 13, 13]
    private static let fixed: (Huffman, Huffman) = {
        var lengths = [Int](repeating: 8, count: 288)
        for symbol in 144..<256 { lengths[symbol] = 9 }
        for symbol in 256..<280 { lengths[symbol] = 7 }
        return (Huffman(lengths: lengths[...]), Huffman(lengths: [Int](repeating: 5, count: 30)[...]))
    }()

    private struct State {
        let input: [UInt8]
        var at = 0
        var bitBuffer = 0
        var bitCount = 0
        var output: [UInt8] = []
        var broken = false

        init(input: [UInt8]) { self.input = input }

        mutating func bits(_ count: Int) -> Int {
            while bitCount < count {
                guard at < input.count else { broken = true; return 0 }
                bitBuffer |= Int(input[at]) << bitCount
                at += 1
                bitCount += 8
            }
            let value = bitBuffer & ((1 << count) - 1)
            bitBuffer >>= count
            bitCount -= count
            return value
        }

        mutating func decode(_ huffman: Huffman) -> Int {
            var code = 0, first = 0, index = 0
            for length in 1..<16 {
                code |= bits(1)
                let count = huffman.counts[length]
                if code - count < first { return broken ? -1 : huffman.symbols[index + code - first] }
                index += count
                first = (first + count) << 1
                code <<= 1
            }
            broken = true
            return -1
        }

        mutating func run() -> Bool {
            var last = 0
            repeat {
                last = bits(1)
                switch bits(2) {
                case 0: guard stored() else { return false }
                case 1: guard codes(Inflate.fixed.0, Inflate.fixed.1) else { return false }
                case 2:
                    guard let (lengths, distances) = dynamicTables(), codes(lengths, distances) else { return false }
                default: return false
                }
                if broken { return false }
            } while last == 0
            return true
        }

        mutating func stored() -> Bool {
            bitBuffer = 0
            bitCount = 0
            guard at + 4 <= input.count else { return false }
            let length = Int(input[at]) | Int(input[at + 1]) << 8
            at += 4
            guard at + length <= input.count else { return false }
            output.append(contentsOf: input[at ..< at + length])
            at += length
            return true
        }

        mutating func dynamicTables() -> (Huffman, Huffman)? {
            let literals = bits(5) + 257, distances = bits(5) + 1, codeLengths = bits(4) + 4
            let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
            var lengths = [Int](repeating: 0, count: 19)
            for index in 0..<codeLengths { lengths[order[index]] = bits(3) }
            let lengthCode = Huffman(lengths: lengths[...])
            var all: [Int] = []
            while all.count < literals + distances {
                let symbol = decode(lengthCode)
                switch symbol {
                case 0..<16: all.append(symbol)
                case 16:
                    guard let previous = all.last else { return nil }
                    all += [Int](repeating: previous, count: 3 + bits(2))
                case 17: all += [Int](repeating: 0, count: 3 + bits(3))
                case 18: all += [Int](repeating: 0, count: 11 + bits(7))
                default: return nil
                }
            }
            guard all.count == literals + distances, !broken else { return nil }
            return (Huffman(lengths: all[0..<literals]), Huffman(lengths: all[literals...]))
        }

        mutating func codes(_ lengths: Huffman, _ distances: Huffman) -> Bool {
            while true {
                let symbol = decode(lengths)
                if symbol < 0 { return false }
                if symbol < 256 {
                    output.append(UInt8(symbol))
                    continue
                }
                if symbol == 256 { return true }
                let index = symbol - 257
                guard index < 29 else { return false }
                let length = Inflate.lengthBase[index] + bits(Inflate.lengthExtra[index])
                let code = decode(distances)
                guard code >= 0, code < 30 else { return false }
                let distance = Inflate.distanceBase[code] + bits(Inflate.distanceExtra[code])
                guard distance <= output.count, !broken else { return false }
                let from = output.count - distance
                for offset in 0..<length { output.append(output[from + offset]) }
            }
        }
    }
}
