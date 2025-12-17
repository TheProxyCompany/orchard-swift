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
            url: "https://github.com/TheProxyCompany/nng/releases/download/1.0.0/nng.xcframework.zip",
            checksum: "f53b5b0c9f864c755a2b64b982b31ccadfb8a7fefbc2086e71b8e02474227051"
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
