// swift-tools-version: 6.0
import PackageDescription

/// Swift 6 language mode (full data-race checking), turned on module by module (AT-076 C2):
/// the agent modules, HDRCore and Core first; the app follows once its reports are fixed.
let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "Atelier",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AtelierCore", targets: ["AtelierCore"]),
        .library(name: "AtelierHDRCore", targets: ["AtelierHDRCore"]),
        // The app-neutral agent action registry (AT-050), shared with Easel.
        .library(name: "AgentActions", targets: ["AgentActions"]),
        // The MCP server pieces (protocol, socket, helper relay), shared with Easel.
        .library(name: "AgentMCP", targets: ["AgentMCP"]),
        .executable(name: "AtelierApp", targets: ["AtelierApp"]),
        // The helper chat apps launch (stdio); it relays to the running app's private socket.
        .executable(name: "atelier-mcp", targets: ["AtelierMCPHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Fine Edges' model (BiRefNet, an optional download) runs with ONNX Runtime (MIT).
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
    ],
    targets: [
        // App-neutral: actions, kinds and tiers, parameter schemas, the registry and menu
        // builders. Foundation only (plus AppKit/SwiftUI for the builders), so Easel can use it
        // and its tests run anywhere. Nothing about photos or catalogs goes in it.
        .target(name: "AgentActions", swiftSettings: swift6),
        .testTarget(name: "AgentActionsTests", dependencies: ["AgentActions"]),
        // Atelier's action catalog (ids, kinds, parameter types) and typed agent tool schemas,
        // without handlers.
        .target(name: "AtelierActions", dependencies: ["AgentActions", "AgentMCP"], swiftSettings: swift6),
        .testTarget(name: "AtelierActionsTests", dependencies: ["AgentActions", "AtelierActions", "AgentMCP"]),
        // App-neutral MCP server: JSON-RPC sessions, the private Unix socket, checked client
        // identity and profiles. Foundation only, so it builds and tests without a Mac.
        .target(name: "AgentMCP", dependencies: ["AgentActions"], swiftSettings: swift6),
        .testTarget(name: "AgentMCPTests", dependencies: ["AgentMCP", "AgentActions"]),
        .executableTarget(name: "AtelierMCPHelper", dependencies: ["AgentMCP"], swiftSettings: swift6),
        .target(name: "AtelierHDRCore", swiftSettings: swift6 + [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        .executableTarget(name: "PresetQualification", dependencies: ["AtelierCore"]),
        .executableTarget(name: "HDRQualification", dependencies: ["AtelierHDRCore", "AtelierCore"]),
        .testTarget(name: "AtelierHDRCoreTests", dependencies: ["AtelierHDRCore"]),
        .target(
            name: "AtelierCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift"),
                           .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")],
            // Select People's built-in parts model (MediaPipe, Apache 2.0), compiled on first use.
            resources: [.copy("Models")],
            // Optimized in Debug too, like AtelierHDRCore: Match Look, histograms, color cubes
            // and camera matching run per-pixel Swift loops that are many times slower unoptimized,
            // and the app is run from Xcode in Debug.
            swiftSettings: swift6 + [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .executableTarget(
            name: "AtelierApp",
            dependencies: ["AtelierCore", "AtelierHDRCore", "AgentActions", "AtelierActions", "AgentMCP",
                           .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.process("Resources"), .copy("Help")]
        ),
        .testTarget(
            name: "AtelierAppTests",
            dependencies: ["AtelierApp", "AgentActions", "AtelierActions", "AgentMCP"]
        ),
        .testTarget(
            name: "AtelierCoreTests",
            dependencies: ["AtelierCore", "AtelierHDRCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
