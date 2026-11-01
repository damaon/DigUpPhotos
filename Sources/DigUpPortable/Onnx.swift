import CONNX
import Foundation

/// An ONNX model on ONNX Runtime's CPU provider, through its C API: one float tensor in, float tensors out.
final class OnnxModel: @unchecked Sendable {
    // Set once, then only read (ONNX Runtime's API table and environment are safe to share between threads).
    nonisolated(unsafe) private static let api: OrtApi = OrtGetApiBase().pointee.GetApi(UInt32(ORT_API_VERSION))!.pointee
    nonisolated(unsafe) private static let environment: OpaquePointer? = {
        var env: OpaquePointer?
        _ = check(api.CreateEnv(ORT_LOGGING_LEVEL_ERROR, "digup", &env))
        return env
    }()

    private let session: OpaquePointer
    private let memory: OpaquePointer
    private let input: String
    let outputs: [String]
    private let lock = NSLock()

    /// Nil when the file is missing or ONNX Runtime can't load it.
    init?(_ url: URL, input: String, outputs: [String]) {
        let api = Self.api
        guard FileManager.default.fileExists(atPath: url.path), let env = Self.environment else { return nil }
        var options: OpaquePointer?
        guard Self.check(api.CreateSessionOptions(&options)), let options else { return nil }
        defer { api.ReleaseSessionOptions(options) }
        _ = Self.check(api.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_ALL))
        var session: OpaquePointer?
        #if os(Windows)
        // ORTCHAR_T is wchar_t on Windows: the path goes in as UTF-16.
        let created = url.path.withCString(encodedAs: UTF16.self) { api.CreateSession(env, $0, options, &session) }
        #else
        let created = api.CreateSession(env, url.path, options, &session)
        #endif
        guard Self.check(created), let session else { return nil }
        var memory: OpaquePointer?
        guard Self.check(api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory)), let memory else {
            api.ReleaseSession(session)
            return nil
        }
        self.session = session
        self.memory = memory
        self.input = input
        self.outputs = outputs
    }

    deinit {
        Self.api.ReleaseMemoryInfo(memory)
        Self.api.ReleaseSession(session)
    }

    /// Runs the model on `values` shaped `shape`; each output, flat, in the order of `outputs`. One run at a time.
    func run(_ values: [Float], shape: [Int64]) -> [[Float]]? {
        let api = Self.api
        return lock.withLock {
            var values = values
            var tensor: OpaquePointer?
            let made = values.withUnsafeMutableBytes { bytes in
                Self.check(api.CreateTensorWithDataAsOrtValue(memory, bytes.baseAddress, bytes.count, shape, shape.count,
                                                              ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &tensor))
            }
            guard made, let tensor else { return nil }
            defer { api.ReleaseValue(tensor) }
            var results = [OpaquePointer?](repeating: nil, count: outputs.count)
            let ran = withCStrings([input]) { inputNames in
                withCStrings(outputs) { outputNames in
                    var inputs: [OpaquePointer?] = [tensor]
                    return Self.check(api.Run(session, nil, inputNames, &inputs, 1, outputNames, outputs.count,
                                              &results))
                }
            }
            defer { for result in results { if let result { api.ReleaseValue(result) } } }
            guard ran else { return nil }
            let arrays = results.map { $0.flatMap(Self.floats) }
            return arrays.contains { $0 == nil } ? nil : arrays.map { $0! }
        }
    }

    /// A float tensor's values, flat.
    private static func floats(_ value: OpaquePointer) -> [Float]? {
        var info: OpaquePointer?
        guard check(api.GetTensorTypeAndShape(value, &info)), let info else { return nil }
        defer { api.ReleaseTensorTypeAndShapeInfo(info) }
        var count = 0
        var data: UnsafeMutableRawPointer?
        guard check(api.GetTensorShapeElementCount(info, &count)), check(api.GetTensorMutableData(value, &data)),
              let data else { return nil }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
    }

    /// True for success; a failure's status is released (its message isn't needed: a nil result says it failed).
    private static func check(_ status: OpaquePointer?) -> Bool {
        guard let status else { return true }
        api.ReleaseStatus(status)
        return false
    }
}

/// `names` as C strings for as long as `body` runs.
private func withCStrings<T>(_ names: [String], _ body: ([UnsafePointer<CChar>?]) -> T) -> T {
    let copies = names.map { strdup($0) }
    defer { copies.forEach { free($0) } }
    return body(copies.map { UnsafePointer($0) })
}
