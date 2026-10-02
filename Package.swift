// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "thinner",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "thinner", targets: ["thinner"]),
        .library(name: "ThinnerCore", targets: ["ThinnerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
    ],
    targets: [
        .target(name: "ThinnerCore"),
        .executableTarget(
            name: "thinner",
            dependencies: [
                "ThinnerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Depends on the CLI so the tests can run the built binary.
        .testTarget(name: "ThinnerCoreTests", dependencies: ["ThinnerCore", "thinner"]),
    ]
)
