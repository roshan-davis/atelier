// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Atelier",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AtelierCore", targets: ["AtelierCore"]),
        .library(name: "AtelierHDRCore", targets: ["AtelierHDRCore"]),
        .executable(name: "AtelierApp", targets: ["AtelierApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Fine Edges' model (BiRefNet, an optional download) runs with ONNX Runtime (MIT).
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
    ],
    targets: [
        .target(name: "AtelierHDRCore", swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
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
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .executableTarget(
            name: "AtelierApp",
            dependencies: ["AtelierCore", "AtelierHDRCore", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.process("Resources"), .copy("Help")]
        ),
        .testTarget(
            name: "AtelierAppTests",
            dependencies: ["AtelierApp"]
        ),
        .testTarget(
            name: "AtelierCoreTests",
            dependencies: ["AtelierCore", "AtelierHDRCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
