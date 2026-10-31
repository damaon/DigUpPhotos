import DigUpCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches the model files into `ModelFiles.installed`, as the macOS app does on first launch: each file into a
/// `.part` file first, given its name only once its SHA-256 checks out. A file already in the Hugging Face cache is
/// copied from there. Where faces aren't found by Vision, YuNet and SFace come first (40 MB), so they're there before
/// any photo is read. For `digup download` and `digup serve` (where nothing else would fetch them).
final class ModelFetch: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Progress {
        var done: Int64 = 0
        var total: Int64 = ModelFetch.files.reduce(0) { $0 + $1.bytes }
        var file: String?
        var error: String?
        var running = false
    }

    static var files: [ModelFiles.File] {
        #if canImport(DigUpApple)
        ModelFiles.all
        #else
        ModelFiles.faces + ModelFiles.all
        #endif
    }

    /// The files not downloaded yet.
    static var missing: [ModelFiles.File] {
        files.filter { !FileManager.default.fileExists(atPath: ModelFiles.installed.appendingPathComponent($0.name).path) }
    }

    private let lock = NSLock()
    private var state = Progress()
    private var finishedBefore: Int64 = 0
    private var current: (file: ModelFiles.File, done: DispatchSemaphore, result: Result<URL, Error>?)?

    var progress: Progress { lock.withLock { state } }

    /// Starts on a thread of its own unless it's running already.
    func start(onDone: @escaping @Sendable () -> Void = {}) {
        guard lock.withLock({ () -> Bool in
            guard !state.running else { return false }
            state = Progress(running: true)
            return true
        }) else { return }
        Thread.detachNewThread { [self] in
            do {
                try fetchAll()
            } catch {
                lock.withLock { state.error = "\(error)" }
            }
            lock.withLock { state.running = false }
            onDone()
        }
    }

    /// Fetches what's missing, in order; throws on the first failure.
    func fetchAll(report: ((Progress) -> Void)? = nil) throws {
        let folder = ModelFiles.installed
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in Self.files {
            let target = folder.appendingPathComponent(file.name)
            defer { lock.withLock { finishedBefore += file.bytes; state.done = finishedBefore } }
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            lock.withLock { state.file = file.name }
            let part = folder.appendingPathComponent(file.name + ".part")
            try? FileManager.default.removeItem(at: part)
            if file.source == nil, let cached = ModelFiles.cachedCopy(of: file) {
                try FileManager.default.copyItem(at: cached, to: part)
            } else {
                try download(file, to: part, report: report)
            }
            guard try ModelFiles.sha256(of: part) == file.sha256 else {
                try? FileManager.default.removeItem(at: part)
                throw CLIError("\(file.name) didn't download whole (its checksum is wrong); try again")
            }
            try FileManager.default.moveItem(at: part, to: target)
        }
    }

    private func download(_ file: ModelFiles.File, to part: URL, report: ((Progress) -> Void)?) throws {
        let done = DispatchSemaphore(value: 0)
        lock.withLock { current = (file, done, nil) }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        session.downloadTask(with: file.url).resume()
        while done.wait(timeout: .now() + 1) == .timedOut { report?(progress) }
        report?(progress)
        guard let result = lock.withLock({ current?.result }) else { throw CLIError("download stopped") }
        let downloaded = try result.get()
        try FileManager.default.moveItem(at: downloaded, to: part)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.withLock { state.done = finishedBefore + totalBytesWritten }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is gone once this returns: keep it next to where it's going.
        let keep = ModelFiles.installed.appendingPathComponent(UUID().uuidString + ".download")
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let result: Result<URL, Error>
        if status != 200 {
            result = .failure(CLIError("Hugging Face answered \(status)"))
        } else {
            result = Result { try FileManager.default.moveItem(at: location, to: keep); return keep }
        }
        lock.withLock { current?.result = result }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock {
            if let error, current?.result == nil { current?.result = .failure(error) }
            current?.done.signal()
        }
    }
}

/// `digup download`: the model files, with progress on the terminal.
func download(_ args: Arguments) throws {
    let missing = ModelFetch.missing
    guard !missing.isEmpty else {
        print("the model is there: \(tilde(ModelFiles.installed.path))")
        return
    }
    print("downloading the model (\(ByteCountFormatter.string(fromByteCount: missing.reduce(0) { $0 + $1.bytes }, countStyle: .file))) "
          + "to \(tilde(ModelFiles.installed.path))")
    let fetch = ModelFetch()
    try fetch.fetchAll { progress in
        let percent = Double(progress.done) / Double(max(1, progress.total)) * 100
        print(String(format: "\r%5.1f%%  %@", percent, progress.file ?? ""), terminator: "")
        fflush(nil)   // every stream: Glibc's stdout is a mutable global
    }
    print("\ndone")
}
