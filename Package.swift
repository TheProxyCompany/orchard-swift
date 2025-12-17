// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Orchard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "Orchard",
            targets: ["Orchard"]
        ),
    ],
    dependencies: [
        // NNG Swift bindings - we'll vendor the C library
    ],
    targets: [
        .target(
            name: "Orchard",
            dependencies: [],
            path: "Sources/Orchard"
        ),
        .testTarget(
            name: "OrchardTests",
            dependencies: ["Orchard"],
            path: "Tests/OrchardTests"
        ),
    ]
)
