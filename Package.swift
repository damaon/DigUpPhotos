// swift-tools-version: 6.2
import PackageDescription

// The core, llama.cpp's runtime and their tests build everywhere. The Apple side, the macOS app and (until a
// MediaReading is built for them) the CLI are macOS only. See docs/ARCHITECTURE.md.
var products: [Product] = [.library(name: "DigUpCore", targets: ["DigUpCore"])]
var dependencies: [Package.Dependency] = []
var coreDependencies: [Target.Dependency] = []
var coreTestDependencies: [Target.Dependency] = ["DigUpCore"]
var targets: [Target] = []

#if os(macOS)
products += [
    .executable(name: "digup", targets: ["digup"]),
    .executable(name: "DigUpApp", targets: ["DigUpApp"]),
    .library(name: "DigUpApple", targets: ["DigUpApple"]),
]
// In-app updates (the app only). build.sh embeds the framework in Contents/Frameworks and signs it.
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"))
coreTestDependencies.append("DigUpApple")
targets += [
    // MediaReading and friends on Apple's frameworks: ImageIO, Vision, Core ML (SFace), PDFKit, AVFoundation.
    .target(name: "DigUpApple", dependencies: ["DigUpCore"]),
    // CLI: estimate / index / search / people / status / eval, and `digup mcp`. Doubles as the eval harness, and the
    // app runs it as its indexing helper and its query encoder.
    .executableTarget(name: "digup", dependencies: ["DigUpCore", "DigUpApple", "LlamaRuntime"]),
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
targets.append(.systemLibrary(name: "CSQLite", path: "Sources/CSQLite", pkgConfig: "sqlite3",
                              providers: [.apt(["libsqlite3-dev"])]))
#endif

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
