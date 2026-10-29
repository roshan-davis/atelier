// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Atelier",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AtelierCore", targets: ["AtelierCore"]),
        .executable(name: "AtelierApp", targets: ["AtelierApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "AtelierCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "AtelierApp",
            dependencies: ["AtelierCore", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.process("Resources"), .copy("Help")]
        ),
        .testTarget(
            name: "AtelierCoreTests",
            dependencies: ["AtelierCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
