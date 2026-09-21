// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "verdict",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VerdictCore", targets: ["VerdictCore"]),
        .executable(name: "verdict", targets: ["verdict"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "VerdictCore",
            linkerSettings: [.linkedFramework("FoundationModels")]
        ),
        .executableTarget(
            name: "verdict",
            dependencies: [
                "VerdictCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "VerdictCoreTests",
            dependencies: ["VerdictCore"]
        ),
    ]
)
