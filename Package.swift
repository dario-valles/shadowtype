// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let llamaPrefix = packageRoot.appendingPathComponent("vendor/llama")
let llamaIncludePath = llamaPrefix.appendingPathComponent("include").path
let llamaLibraryPath = llamaPrefix.appendingPathComponent("lib").path

let package = Package(
    name: "Shadowtype",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(
            name: "CLlama"
        ),
        .executableTarget(
            name: "Shadowtype",
            dependencies: ["CLlama"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-Xcc", "-I\(llamaIncludePath)"]),
            ],
            linkerSettings: [
                // Static dependency order: llama -> ggml -> compiled-in CPU/BLAS/Metal
                // backends -> ggml-base. libc++ and the Apple frameworks are their only
                // dynamic closure; no rpath or runtime backend plugins are required.
                .unsafeFlags(["-L\(llamaLibraryPath)"]),
                .linkedLibrary("llama"),
                .linkedLibrary("ggml"),
                .linkedLibrary("ggml-cpu"),
                .linkedLibrary("ggml-blas"),
                .linkedLibrary("ggml-metal"),
                .linkedLibrary("ggml-base"),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        // M2: stdio JSON-RPC ↔ HTTP bridge that exposes the running Shadowtype Local API as MCP
        // tools (Claude Code / Cursor / any MCP host). Built into a tiny standalone binary that
        // make-app.sh copies into Shadowtype.app/Contents/Resources/shadowtype-mcp. Connects to
        // the in-app server via UDS first, TCP fallback with $SHADOWTYPE_API_KEY.
        .executableTarget(
            name: "MCPBridge",
            path: "Sources/MCPBridge",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "ShadowtypeTests",
            dependencies: ["Shadowtype"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // @testable import Shadowtype transitively rebuilds the CLlama clang module here.
                .unsafeFlags(["-Xcc", "-I\(llamaIncludePath)"]),
            ]
        ),
    ]
)
