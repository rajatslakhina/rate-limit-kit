// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RateLimitKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "RateLimitKit",
            targets: ["RateLimitKit"]
        )
    ],
    targets: [
        .target(
            name: "RateLimitKit",
            dependencies: []
        ),
        .testTarget(
            name: "RateLimitKitTests",
            dependencies: ["RateLimitKit"]
        )
    ]
)
