import Testing
@testable import DigUpCore

/// What `Linear` computes, on whichever path this platform builds (Accelerate on macOS, loops elsewhere).
@Suite struct LinearTests {
    @Test func elementwise() {
        var sum: [Float] = [1, 2, 3]
        Linear.add([10, 20, 30], to: &sum)
        #expect(sum == [11, 22, 33])
        #expect(Linear.subtract([1, 1, 1], from: [3, 2, 1]) == [2, 1, 0])
        #expect(Linear.sumOfSquares([3, 4]) == 25)
    }

    @Test func matrixTimesVectorAndGram() {
        let matrix: [Float] = [1, 2, 3,
                               4, 5, 6]
        var out = [Float](repeating: 0, count: 2)
        matrix.withUnsafeBufferPointer { m in
            [Float(1), 0, -1].withUnsafeBufferPointer { v in
                Linear.multiply(m.baseAddress!, rows: 2, columns: 3, by: v.baseAddress!, into: &out)
            }
        }
        #expect(out == [-2, -2])
        #expect(Linear.gram(matrix, rows: 2, columns: 3) == [14, 32, 32, 77])
    }

    @Test func halvesToFloats() {
        let halves: [Float16] = [0.5, -2, 1024]
        var out = [Float](repeating: 0, count: 3)
        halves.withUnsafeBufferPointer { Linear.floats(fromHalf: $0.baseAddress!, count: 3, to: &out) }
        #expect(out == [0.5, -2, 1024])
    }
}
