// swift-tools-version: 6.2
import PackageDescription

// The core, llama.cpp's runtime, the CLI (with `digup mcp`) and their tests build everywhere: on macOS files are read
// with Apple's frameworks (DigUpApple), elsewhere with DigUpPortable. The menubar app is macOS only.
// See docs/ARCHITECTURE.md.
var products: [Product] = [
    .library(name: "DigUpCore", targets: ["DigUpCore"]),
    .executable(name: "digup", targets: ["digup"]),
]
var dependencies: [Package.Dependency] = []
var coreDependencies: [Target.Dependency] = []
var coreTestDependencies: [Target.Dependency] = ["DigUpCore"]
var targets: [Target] = []
let reader: Target.Dependency

#if os(macOS)
products += [
    .executable(name: "DigUpApp", targets: ["DigUpApp"]),
    .library(name: "DigUpApple", targets: ["DigUpApple"]),
]
// In-app updates (the app only). build.sh embeds the framework in Contents/Frameworks and signs it.
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"))
reader = "DigUpApple"
targets += [
    // MediaReading and friends on Apple's frameworks: ImageIO, Vision, Core ML (SFace), PDFKit, AVFoundation.
    .target(name: "DigUpApple", dependencies: ["DigUpCore"]),
    // The menubar + hotkey app. build.sh wraps it into build.noindex/DigUp.app. (The product can't be called
    // "DigUp": on a case-insensitive disk it would collide with the `digup` CLI binary.)
    .executableTarget(
        name: "DigUpApp",
        dependencies: ["DigUpCore", "DigUpApple", .product(name: "Sparkle", package: "Sparkle")],
        swiftSettings: [.defaultIsolation(MainActor.self)],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
    ),
    .testTarget(name: "DigUpAppleTests", dependencies: ["DigUpApple", "DigUpCore"]),
]
#else
// What macOS ships and other systems don't: SQLite (libsqlite3-dev) and SHA-256 (swift-crypto, CryptoKit's API).
dependencies.append(.package(url: "https://github.com/apple/swift-crypto", exact: "4.5.2"))
coreDependencies += ["CSQLite", .product(name: "Crypto", package: "swift-crypto")]
coreTestDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
reader = "DigUpPortable"
targets += [
    .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
    // HEIC and AVIF photos (libheif-dev, and libheif-plugin-libde265 to decode HEVC).
    .systemLibrary(name: "CHeif", path: "Sources/CHeif", pkgConfig: "libheif", providers: [.apt(["libheif-dev"])]),
    // JPEG, PNG, GIF and friends: stb_image, vendored.
    .target(name: "CStb", path: "Sources/CStb", exclude: ["stb_image.h"]),
    // ONNX Runtime, for faces (scripts/build-onnx.sh puts Microsoft's build in Vendor/onnxruntime).
    .systemLibrary(name: "CONNX", path: "Sources/CONNX"),
    // MediaReading without Apple: stb_image and libheif, YuNet and SFace on ONNX Runtime, ffmpeg, poppler-utils,
    // tesseract.
    .target(
        name: "DigUpPortable",
        dependencies: ["DigUpCore", "CStb", "CHeif", "CONNX"],
        linkerSettings: [.unsafeFlags([
            "-L\(Context.packageDirectory)/Vendor/onnxruntime/lib",
            "-Xlinker", "-rpath", "-Xlinker", "$ORIGIN",
            "-Xlinker", "-rpath", "-Xlinker", "\(Context.packageDirectory)/Vendor/onnxruntime/lib",
        ])]
    ),
    .testTarget(name: "DigUpPortableTests", dependencies: ["DigUpPortable", "DigUpCore"]),
]
#endif
coreTestDependencies.append(reader)

targets += [
    // llama.cpp (scripts/build-llama.sh builds it into Vendor/llama) and EmbeddingGemma 2 on it: Metal on macOS, the
    // CPU elsewhere.
    .systemLibrary(name: "CLlama", path: "Sources/CLlama"),
    .target(
        name: "LlamaRuntime",
        dependencies: ["CLlama", "DigUpCore"],
        linkerSettings: [
            .unsafeFlags(["-L\(Context.packageDirectory)/Vendor/llama/lib"]),
            .linkedLibrary("c++", .when(platforms: [.macOS])),
            .linkedLibrary("stdc++", .when(platforms: [.linux])),
            .linkedFramework("Accelerate", .when(platforms: [.macOS])),
            .linkedFramework("Foundation", .when(platforms: [.macOS])),
            .linkedFramework("Metal", .when(platforms: [.macOS])),
            .linkedFramework("MetalKit", .when(platforms: [.macOS])),
        ]
    ),
    .testTarget(name: "LlamaRuntimeTests", dependencies: ["LlamaRuntime"]),
    // CLI: estimate / index / search / people / status / eval, and `digup mcp`. Doubles as the eval harness, and the
    // app runs it as its indexing helper and its query encoder.
    .executableTarget(name: "digup", dependencies: ["DigUpCore", reader, "LlamaRuntime"]),
    // The engine: crawler, index store, the embedder interface and worker client, search, people, albums. No UI,
    // and what needs the operating system goes through protocols (MediaReading).
    .target(name: "DigUpCore", dependencies: coreDependencies),
    .testTarget(name: "DigUpCoreTests", dependencies: coreTestDependencies),
]

let package = Package(
    name: "DigUp",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
