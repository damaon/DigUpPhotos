import CHeif
import CStb
import DigUpCore
import Foundation

/// 8-bit RGB pixels, rows top to bottom: what pictures are decoded to here.
struct Picture {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    /// HEIC, HEIF and AVIF through libheif (upright already: it applies the file's rotation); JPEG, PNG, GIF, BMP,
    /// PSD, TGA and PNM through stb_image; raw photos by the JPEG they embed (`RawPreview`); anything else ffmpeg reads
    /// (WebP, TIFF, JPEG XL where it's built with it) through ffmpeg. Nil when none of them can.
    static func decode(_ url: URL) -> (picture: Picture, exif: Exif)? {
        let ext = url.pathExtension.lowercased()
        if heifExtensions.contains(ext) { return decodeHEIF(url) }
        if rawExtensions.contains(ext) { return decodeRaw(url) }
        var width: Int32 = 0, height: Int32 = 0
        if let data = digup_stb_load_rgb(url.path, &width, &height) {
            defer { digup_stb_free(data) }
            let picture = Picture(width: Int(width), height: Int(height),
                                  pixels: [UInt8](UnsafeBufferPointer(start: data, count: Int(width * height) * 3)))
            let exif = Exif.read(url)
            return (picture.oriented(exif.orientation), exif)
        }
        return decodeWithFFmpeg(url)
    }

    /// The stored size, without decoding the pixels (for the too-small check). A raw photo's is its preview's.
    static func size(of url: URL) -> (width: Int, height: Int)? {
        let ext = url.pathExtension.lowercased()
        if heifExtensions.contains(ext) {
            return withHEIF(url) { handle in
                (Int(heif_image_handle_get_width(handle)), Int(heif_image_handle_get_height(handle)))
            }
        }
        if rawExtensions.contains(ext) { return RawPreview.largestJPEG(in: url).map { ($0.found.width, $0.found.height) } }
        var width: Int32 = 0, height: Int32 = 0
        if digup_stb_info(url.path, &width, &height) != 0 { return (Int(width), Int(height)) }
        guard let data = try? Tools.run("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                                    "stream=width,height", "-of", "csv=p=0:s=x", url.path]) else { return nil }
        let parts = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "x").compactMap { Int($0) }
        return parts.count == 2 && parts[0] > 0 && parts[1] > 0 ? (parts[0], parts[1]) : nil
    }

    static let heifExtensions: Set<String> = ["heic", "heif", "hif", "avif"]
    static let rawExtensions: Set<String> = ["dng", "cr2", "cr3", "nef", "nrw", "arw", "orf", "rw2", "raf", "srw", "pef"]

    /// The raw's biggest embedded JPEG, turned upright by the raw's own EXIF (or, in CR3 and RAF, whose containers
    /// aren't TIFF, by the JPEG's).
    private static func decodeRaw(_ url: URL) -> (picture: Picture, exif: Exif)? {
        guard let (bytes, _) = RawPreview.largestJPEG(in: url) else { return nil }
        var width: Int32 = 0, height: Int32 = 0
        guard let data = digup_stb_load_rgb_memory(bytes, Int32(bytes.count), &width, &height) else { return nil }
        defer { digup_stb_free(data) }
        let picture = Picture(width: Int(width), height: Int(height),
                              pixels: [UInt8](UnsafeBufferPointer(start: data, count: Int(width * height) * 3)))
        var exif = Exif.read(url)
        if exif == Exif() { exif = Exif.parse(bytes) }
        return (picture.oriented(exif.orientation), exif)
    }

    /// The first frame as ffmpeg decodes it, through a BMP that stb_image reads back.
    private static func decodeWithFFmpeg(_ url: URL) -> (picture: Picture, exif: Exif)? {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bmp")
        defer { try? FileManager.default.removeItem(at: out) }
        guard (try? Tools.run("ffmpeg", ["-v", "error", "-nostdin", "-i", url.path, "-frames:v", "1", "-pix_fmt", "bgr24",
                                         out.path])) != nil else { return nil }
        var width: Int32 = 0, height: Int32 = 0
        guard let data = digup_stb_load_rgb(out.path, &width, &height) else { return nil }
        defer { digup_stb_free(data) }
        let picture = Picture(width: Int(width), height: Int(height),
                              pixels: [UInt8](UnsafeBufferPointer(start: data, count: Int(width * height) * 3)))
        let exif = Exif.read(url)
        return (picture.oriented(exif.orientation), exif)
    }

    private static func withHEIF<T>(_ url: URL, _ body: (OpaquePointer) -> T?) -> T? {
        guard let context = heif_context_alloc() else { return nil }
        defer { heif_context_free(context) }
        guard heif_context_read_from_file(context, url.path, nil).code == heif_error_Ok else { return nil }
        var handle: OpaquePointer?
        guard heif_context_get_primary_image_handle(context, &handle).code == heif_error_Ok, let handle else { return nil }
        defer { heif_image_handle_release(handle) }
        return body(handle)
    }

    private static func decodeHEIF(_ url: URL) -> (picture: Picture, exif: Exif)? {
        withHEIF(url) { handle in
            var image: OpaquePointer?
            guard heif_decode_image(handle, &image, heif_colorspace_RGB, heif_chroma_interleaved_RGB, nil).code
                    == heif_error_Ok, let image else { return nil }
            defer { heif_image_release(image) }
            let width = Int(heif_image_get_width(image, heif_channel_interleaved))
            let height = Int(heif_image_get_height(image, heif_channel_interleaved))
            var stride: Int32 = 0
            guard width > 0, height > 0,
                  let plane = heif_image_get_plane_readonly(image, heif_channel_interleaved, &stride) else { return nil }
            var pixels = [UInt8](repeating: 0, count: width * height * 3)
            for row in 0..<height {
                let source = plane + row * Int(stride)
                pixels.withUnsafeMutableBufferPointer { buffer in
                    (buffer.baseAddress! + row * width * 3).update(from: source, count: width * 3)
                }
            }
            // The EXIF block: a 4-byte offset, then the TIFF structure. Its orientation is left out: libheif has turned
            // the picture upright already.
            var exif = Exif()
            var id = heif_item_id()
            if heif_image_handle_get_list_of_metadata_block_IDs(handle, "Exif", &id, 1) == 1 {
                var block = [UInt8](repeating: 0, count: heif_image_handle_get_metadata_size(handle, id))
                if block.count > 4, heif_image_handle_get_metadata(handle, id, &block).code == heif_error_Ok {
                    let skip = 4 + (Int(block[0]) << 24 | Int(block[1]) << 16 | Int(block[2]) << 8 | Int(block[3]))
                    if skip < block.count { exif = Exif.parse(Array(block[skip...])) }
                }
            }
            exif.orientation = 1
            return (Picture(width: width, height: height, pixels: pixels), exif)
        }
    }

    /// Turned upright by an EXIF orientation (1 to 8).
    func oriented(_ orientation: Int) -> Picture {
        guard (2...8).contains(orientation) else { return self }
        let swaps = orientation >= 5
        let outWidth = swaps ? height : width, outHeight = swaps ? width : height
        var out = [UInt8](repeating: 0, count: pixels.count)
        for y in 0..<outHeight {
            for x in 0..<outWidth {
                // Where the upright pixel (x, y) is stored.
                let (sx, sy): (Int, Int) = switch orientation {
                case 2: (width - 1 - x, y)
                case 3: (width - 1 - x, height - 1 - y)
                case 4: (x, height - 1 - y)
                case 5: (y, x)
                case 6: (y, height - 1 - x)
                case 7: (width - 1 - y, height - 1 - x)
                default: (width - 1 - y, x) // 8
                }
                let from = (sy * width + sx) * 3, to = (y * outWidth + x) * 3
                out[to] = pixels[from]
                out[to + 1] = pixels[from + 1]
                out[to + 2] = pixels[from + 2]
            }
        }
        return Picture(width: outWidth, height: outHeight, pixels: out)
    }

    /// At most `maxPixel` on the longer side (never larger).
    func fitted(in maxPixel: Int) -> Picture {
        let scale = min(1, Double(maxPixel) / Double(max(width, height)))
        guard scale < 1 else { return self }
        return resized(to: max(1, Int((Double(width) * scale).rounded())),
                       max(1, Int((Double(height) * scale).rounded())))
    }

    /// Shrunk to `outWidth`×`outHeight`, each pixel the average of the ones it covers.
    func resized(to outWidth: Int, _ outHeight: Int) -> Picture {
        var out = [UInt8](repeating: 0, count: outWidth * outHeight * 3)
        for y in 0..<outHeight {
            let y0 = y * height / outHeight, y1 = max(y0 + 1, (y + 1) * height / outHeight)
            for x in 0..<outWidth {
                let x0 = x * width / outWidth, x1 = max(x0 + 1, (x + 1) * width / outWidth)
                var sum = (0, 0, 0)
                for sy in y0..<y1 {
                    var at = (sy * width + x0) * 3
                    for _ in x0..<x1 {
                        sum.0 += Int(pixels[at]); sum.1 += Int(pixels[at + 1]); sum.2 += Int(pixels[at + 2])
                        at += 3
                    }
                }
                let count = (y1 - y0) * (x1 - x0), to = (y * outWidth + x) * 3
                out[to] = UInt8(sum.0 / count)
                out[to + 1] = UInt8(sum.1 / count)
                out[to + 2] = UInt8(sum.2 / count)
            }
        }
        return Picture(width: outWidth, height: outHeight, pixels: out)
    }

    /// Luma (Rec. 601), for the quality score and the frame hash.
    var gray: PhotoQuality.Gray {
        var out = [UInt8](repeating: 0, count: width * height)
        for index in out.indices {
            let r = Int(pixels[index * 3]), g = Int(pixels[index * 3 + 1]), b = Int(pixels[index * 3 + 2])
            out[index] = UInt8((299 * r + 587 * g + 114 * b) / 1000)
        }
        return PhotoQuality.Gray(width: width, height: height, pixels: out)
    }

    /// 8×8 average hash, as `VideoExtractor.averageHash` on macOS: a frame within 4 bits of the last kept one is the
    /// same shot.
    var averageHash: UInt64 {
        let gray = resized(to: 8, 8).gray.pixels
        let mean = gray.reduce(0) { $0 + Int($1) } / gray.count
        var hash: UInt64 = 0
        for (index, pixel) in gray.enumerated() where Int(pixel) > mean { hash |= 1 << UInt64(index) }
        return hash
    }

    /// An uncompressed 24-bit BMP: lossless, and llama.cpp's image loader reads it, so nothing needs encoding.
    func writeBMP(to url: URL) throws {
        let rowBytes = (width * 3 + 3) & ~3
        let size = 54 + rowBytes * height
        var data = Data(capacity: size)
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("BM".utf8)); append32(size); append32(0); append32(54)
        append32(40); append32(width); append32(height); append16(1); append16(24); append32(0)
        append32(rowBytes * height); append32(2835); append32(2835); append32(0); append32(0)
        var row = [UInt8](repeating: 0, count: rowBytes)
        for y in stride(from: height - 1, through: 0, by: -1) { // bottom-up, BGR
            for x in 0..<width {
                let from = (y * width + x) * 3
                row[x * 3] = pixels[from + 2]; row[x * 3 + 1] = pixels[from + 1]; row[x * 3 + 2] = pixels[from]
            }
            data.append(contentsOf: row)
        }
        try data.write(to: url)
    }
}
