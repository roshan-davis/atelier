// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Atelier",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AtelierCore", targets: ["AtelierCore"]),
        .library(name: "AtelierHDRCore", targets: ["AtelierHDRCore"]),
        .executable(name: "AtelierApp", targets: ["AtelierApp"]),
        .executable(name: "AtelierHDRApp", targets: ["AtelierHDRApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "AtelierHDRCore", swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        .executableTarget(name: "AtelierHDRApp", dependencies: ["AtelierHDRCore", "AtelierCore"], resources: [.copy("Resources")], swiftSettings: [.define("ATELIER_HDR_APP")]),
        .executableTarget(name: "PresetQualification", dependencies: ["AtelierCore"]),
        .executableTarget(name: "HDRQualification", dependencies: ["AtelierHDRCore", "AtelierCore"]),
        .testTarget(name: "AtelierHDRCoreTests", dependencies: ["AtelierHDRCore"]),
        .target(
            name: "AtelierCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
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
