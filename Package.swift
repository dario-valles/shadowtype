// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shadowtype",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(
            name: "CLlama",
            pkgConfig: "llama",
            providers: [.brew(["llama.cpp"])]
        ),
        .executableTarget(
            name: "Shadowtype",
            dependencies: ["CLlama"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // INTEGRATOR: llama.h does `#include "ggml.h"`, but ggml.h ships in the SEPARATE
                // `ggml` Homebrew formula at /opt/homebrew/include (pkg-config "llama" only emits
                // its own includedir). Feed clang the ggml include path so the CLlama module builds.
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/include"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/opt/llama.cpp/lib",
                    "-L/opt/homebrew/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/opt/homebrew/opt/llama.cpp/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/opt/homebrew/lib",
                ]),
                .linkedLibrary("llama"),
                .linkedLibrary("ggml"),
                .linkedLibrary("ggml-base"),
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
                .unsafeFlags(["-Xcc", "-I/opt/homebrew/include"]),
            ]
        ),
    ]
)
