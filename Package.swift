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
            url: "https://github.com/TheProxyCompany/nng/releases/download/1.0.2/nng.xcframework.zip",
            checksum: "c4c75d37a9b030756ba362ffd9202368969bfe746c8d1a74101014e5e0585e1b"
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
