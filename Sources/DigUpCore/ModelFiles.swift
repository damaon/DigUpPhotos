#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// The EmbeddingGemma 2 files the app runs: ggml-org's Q8_0 GGUF conversion at one pinned revision of the repo (made
/// from google/embeddinggemma-2 at 914f7f8, the weights the mlx-vlm reference runs). Never the F16 files: the model's
/// activations overflow float16.
///
/// The app downloads them on first launch (`ModelDownload`) and the helper loads them (`LlamaModels`); this is what
/// both agree on.
public enum ModelFiles {
    public static let repository = "ggml-org/embeddinggemma-2-GGUF"
    public static let revision = "bfcd298762cc34d0357ece5ebdd31791a3a374d8"

    public struct File: Sendable, Equatable {
        public let name: String
        public let bytes: Int64
        public let sha256: String
        /// Where it comes from when that isn't the model's Hugging Face repository.
        public let source: URL?

        public init(name: String, bytes: Int64, sha256: String, source: URL? = nil) {
            self.name = name
            self.bytes = bytes
            self.sha256 = sha256
            self.source = source
        }

        /// Hugging Face's address for this file at the pinned revision (it redirects to a CDN that takes HTTP ranges).
        public var url: URL {
            source ?? URL(string: "https://huggingface.co/\(ModelFiles.repository)/resolve/\(ModelFiles.revision)/\(name)")!
        }
    }

    /// The text model (310 MB): all that queries need.
    public static let text = File(name: "embeddinggemma-2-Q8_0.gguf", bytes: 309_855_456,
                                  sha256: "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135")
    /// The image and audio encoders (555 MB).
    public static let media = File(name: "mmproj-embeddinggemma-2-Q8_0.gguf", bytes: 554_821_024,
                                   sha256: "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f")
    /// In download order.
    public static let all = [text, media]
    public static let totalBytes = all.reduce(0) { $0 + $1.bytes }

    /// The face models where Vision and Core ML aren't (`DigUpPortable`): YuNet finds faces, SFace tells them apart.
    /// OpenCV Zoo's (Apache-2.0), pinned by commit, as scripts/build-onnx.sh fetches them.
    public static let faces = [
        File(name: "yunet.onnx", bytes: 232_589,
             sha256: "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4",
             source: URL(string: "https://media.githubusercontent.com/media/opencv/opencv_zoo/"
                         + "f12e12798e8314f7c074a6656816c048dcc95b7a/models/face_detection_yunet/face_detection_yunet_2023mar.onnx")),
        File(name: "sface.onnx", bytes: 38_696_353,
             sha256: "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79",
             source: URL(string: "https://media.githubusercontent.com/media/opencv/opencv_zoo/"
                         + "ba91a3b91d00d76e86540d4013f944bd6b514e39/models/face_recognition_sface/face_recognition_sface_2021dec.onnx")),
    ]

    /// Where the app keeps them.
    public static let installed = dataFolder.appendingPathComponent("Models")

    /// The pinned revision's folder in the Hugging Face cache (`hf download` puts the files there): `$HF_HUB_CACHE`,
    /// `$HF_HOME/hub`, or `~/.cache/huggingface/hub`.
    public static var huggingFaceSnapshot: URL {
        let environment = ProcessInfo.processInfo.environment
        let hub = environment["HF_HUB_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? environment["HF_HOME"].map { URL(fileURLWithPath: $0).appendingPathComponent("hub") }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
        return hub.appendingPathComponent("models--\(repository.replacingOccurrences(of: "/", with: "--"))/snapshots/\(revision)")
    }

    /// `file` in the Hugging Face cache, when it's there at the right size (its checksum is for the caller to check).
    public static func cachedCopy(of file: File,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let candidates = [
            huggingFaceSnapshot.appendingPathComponent(file.name),
            home.appendingPathComponent("Library/Application Support/DigUp/Models/\(file.name)"),
        ]
        for candidate in candidates {
            let url = candidate.resolvingSymlinksInPath()
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            if size == file.bytes { return url }
        }
        return nil
    }

    /// The files that aren't in `folder` yet. Only verified files get their final name, so being there is enough.
    public static func missing(in folder: URL) -> [File] {
        all.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.name).path) }
    }

    /// The SHA-256 of a file as lowercase hex, read in 8 MB pieces (a 555 MB file takes about half a second).
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let done = try drainingPool { () -> Bool in
                guard let data = try handle.read(upToCount: 8 << 20), !data.isEmpty else { return true }
                hasher.update(data: data)
                return false
            }
            if done { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
