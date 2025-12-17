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
    targets: [
        .binaryTarget(
            name: "nng",
            url: "https://github.com/TheProxyCompany/nng/releases/download/v2.0.0-swift.1/nng.xcframework.zip",
            checksum: "73e7f43b78eb6a6cb7582bb2c4f36ddaaed427e16a67afaa9ce8b788410c7c74"
        ),
        .target(
            name: "Orchard",
            dependencies: ["nng"],
            path: "Sources/Orchard"
        ),
        .testTarget(
            name: "OrchardTests",
            dependencies: ["Orchard"],
            path: "Tests/OrchardTests"
        ),
    ]
)
