// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "verdict",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VerdictCore", targets: ["VerdictCore"]),
        .executable(name: "verdict", targets: ["verdict"]),
        .library(name: "VerdictServer", targets: ["VerdictServer"]),
        .executable(name: "verdictd", targets: ["verdictd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.26.0"),
    ],
    targets: [
        .target(
            name: "VerdictCore",
            linkerSettings: [.linkedFramework("FoundationModels"), .linkedFramework("CoreML")]
        ),
        .executableTarget(
            name: "verdict",
            dependencies: [
                "VerdictCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "VerdictServer",
            dependencies: [
                "VerdictCore",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .executableTarget(
            name: "verdictd",
            dependencies: [
                "VerdictServer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "VerdictServerTests",
            dependencies: [
                "VerdictServer",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
        .testTarget(
            name: "VerdictCoreTests",
            dependencies: ["VerdictCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
