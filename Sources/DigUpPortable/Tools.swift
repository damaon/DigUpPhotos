import DigUpCore
import Foundation

/// The programs that read what has no Swift library here: ffmpeg and ffprobe (sound and video), poppler-utils' pdfinfo,
/// pdftotext and pdftoppm (PDF), and tesseract (text in pictures, optional). Found on PATH.
enum Tools {
    static func find(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        for folder in path.split(separator: ":") {
            let url = URL(fileURLWithPath: String(folder)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Runs `name` and returns what it printed. Throws when it isn't installed or fails.
    @discardableResult
    static func run(_ name: String, _ arguments: [String]) throws -> Data {
        let running = try start(name, arguments)
        let output = running.stdout.fileHandleForReading.readDataToEndOfFile()
        try running.finish(name)
        return output
    }

    final class Running: @unchecked Sendable {
        let process = Process()
        let stdout = Pipe()
        private let stderr = Pipe()
        private var errors = Data()
        private let errorsRead = DispatchGroup()

        fileprivate init(_ executable: URL, _ arguments: [String]) throws {
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice
            try process.run()
            // Drained on the side, so a full stderr pipe can't stall a program the caller is reading stdout from.
            errorsRead.enter()
            DispatchQueue.global().async { [self] in
                errors = stderr.fileHandleForReading.readDataToEndOfFile()
                errorsRead.leave()
            }
        }

        /// Waits for it to exit; throws with its last line of errors when it failed.
        func finish(_ name: String) throws {
            process.waitUntilExit()
            errorsRead.wait()
            guard process.terminationStatus == 0 else {
                let why = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw ToolError.failed(name, why.split(separator: "\n").last.map(String.init)
                                       ?? "exit \(process.terminationStatus)")
            }
        }
    }

    /// Starts `name`; the caller reads stdout as it comes (a long decode), then calls `finish`.
    static func start(_ name: String, _ arguments: [String]) throws -> Running {
        guard let executable = find(name) else { throw ToolError.missing(name) }
        return try Running(executable, arguments)
    }
}

enum ToolError: Error, CustomStringConvertible {
    case missing(String)
    case failed(String, String)

    var description: String {
        switch self {
        case .missing(let name):
            "needs \(name) (\(name.hasPrefix("ff") ? "ffmpeg" : name.hasPrefix("pdf") ? "poppler-utils" : name))"
        case .failed(let name, let why): "\(name): \(why)"
        }
    }
}
