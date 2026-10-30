// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DigUp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "digup", targets: ["digup"]),
        .executable(name: "DigUpApp", targets: ["DigUpApp"]),
        .library(name: "DigUpCore", targets: ["DigUpCore"]),
        .library(name: "DigUpApple", targets: ["DigUpApple"]),
    ],
    dependencies: [
        // In-app updates (the app only). build.sh embeds the framework in Contents/Frameworks and signs it.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // The engine: crawler, index store, the embedder interface and worker client, search, people, albums. No UI,
        // and what needs the operating system goes through protocols (MediaReading) (docs/ARCHITECTURE.md).
        .target(name: "DigUpCore"),
        // MediaReading and friends on Apple's frameworks: ImageIO, Vision, Core ML (SFace), PDFKit, AVFoundation.
        .target(name: "DigUpApple", dependencies: ["DigUpCore"]),
        // llama.cpp (scripts/build-llama.sh builds it into Vendor/llama) and EmbeddingGemma 2 on it.
        .systemLibrary(name: "CLlama", path: "Sources/CLlama"),
        .target(
            name: "LlamaRuntime",
            dependencies: ["CLlama", "DigUpCore"],
            linkerSettings: [.unsafeFlags(["-L\(Context.packageDirectory)/Vendor/llama/lib"])]
        ),
        // Developer CLI: estimate / index / search / status / eval. Doubles as the eval harness, and the app runs it as
        // its indexing helper and its query encoder.
        .executableTarget(name: "digup", dependencies: ["DigUpCore", "DigUpApple", "LlamaRuntime"]),
        // The menubar + hotkey app. build.sh wraps it into build.noindex/DigUp.app. (The product can't be called
        // "DigUp": on a case-insensitive disk it would collide with the `digup` CLI binary.)
        .executableTarget(
            name: "DigUpApp",
            dependencies: ["DigUpCore", "DigUpApple", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "DigUpCoreTests", dependencies: ["DigUpCore", "DigUpApple"]),
        .testTarget(name: "DigUpAppleTests", dependencies: ["DigUpApple", "DigUpCore"]),
        .testTarget(name: "LlamaRuntimeTests", dependencies: ["LlamaRuntime"]),
    ]
)
