#if canImport(Accelerate)
import Accelerate
#endif
import Foundation

/// The vector math search and face grouping need, on Accelerate where there is one (macOS) and in plain loops
/// elsewhere (Linux, Windows), so the core builds everywhere.
enum Linear {
    /// `sum += vector`, element by element.
    static func add(_ vector: [Float], to sum: inout [Float]) {
        #if canImport(Accelerate)
        vDSP_vadd(sum, 1, vector, 1, &sum, 1, vDSP_Length(sum.count))
        #else
        for i in sum.indices { sum[i] += vector[i] }
        #endif
    }

    /// `vector - other`, element by element.
    static func subtract(_ other: [Float], from vector: [Float]) -> [Float] {
        #if canImport(Accelerate)
        var out = [Float](repeating: 0, count: vector.count)
        vDSP_vsub(other, 1, vector, 1, &out, 1, vDSP_Length(vector.count))
        return out
        #else
        return zip(vector, other).map { $0 - $1 }
        #endif
    }

    static func sumOfSquares(_ vector: [Float]) -> Float {
        #if canImport(Accelerate)
        var sum: Float = 0
        vDSP_svesq(vector, 1, &sum, vDSP_Length(vector.count))
        return sum
        #else
        return vector.reduce(0) { $0 + $1 * $1 }
        #endif
    }

    /// `out = matrix · vector`, where `matrix` is `rows × columns`, row-major.
    static func multiply(_ matrix: UnsafePointer<Float>, rows: Int, columns: Int, by vector: UnsafePointer<Float>,
                         into out: UnsafeMutablePointer<Float>) {
        guard rows > 0 else { return }
        #if canImport(Accelerate)
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(rows), Int32(columns), 1, matrix, Int32(columns), vector, 1, 0,
                    out, 1)
        #else
        for row in 0..<rows {
            var sum: Float = 0
            let start = matrix + row * columns
            for column in 0..<columns { sum += start[column] * vector[column] }
            out[row] = sum
        }
        #endif
    }

    /// `matrix · matrixᵀ` (`rows × rows`), where `matrix` is `rows × columns`, row-major: every row's dot product with
    /// every row.
    static func gram(_ matrix: [Float], rows: Int, columns: Int) -> [Float] {
        var out = [Float](repeating: 0, count: rows * rows)
        guard rows > 0 else { return out }
        #if canImport(Accelerate)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(rows), Int32(columns), 1, matrix,
                    Int32(columns), matrix, Int32(columns), 0, &out, Int32(rows))
        #else
        matrix.withUnsafeBufferPointer { m in
            for a in 0..<rows {
                for b in a..<rows {
                    var sum: Float = 0
                    for i in 0..<columns { sum += m[a * columns + i] * m[b * columns + i] }
                    out[a * rows + b] = sum
                    out[b * rows + a] = sum
                }
            }
        }
        #endif
        return out
    }

    /// Converts `count` float16s into float32s.
    static func floats(fromHalf source: UnsafePointer<Float16>, count: Int, to destination: UnsafeMutablePointer<Float>) {
        #if canImport(Accelerate)
        var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: 1,
                                 width: vImagePixelCount(count), rowBytes: count * 2)
        var to = vImage_Buffer(data: destination, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
        vImageConvert_Planar16FtoPlanarF(&from, &to, vImage_Flags(kvImageNoFlags))
        #else
        for i in 0..<count { destination[i] = Float(source[i]) }
        #endif
    }
}
