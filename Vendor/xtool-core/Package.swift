// swift-tools-version:6.0
import PackageDescription

// LocSign uses only these pure Swift utilities from xtool-core 1.5.1.
// Native signing, OpenSSL and device libraries are supplied by LocSign itself.
let package = Package(
    name: "xtool-core",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Superutils", targets: ["Superutils"]),
        .library(name: "ProtoCodable", targets: ["ProtoCodable"])
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", from: "1.3.0")
    ],
    targets: [
        .target(name: "Superutils"),
        .target(name: "ProtoCodable", dependencies: [
            .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras")
        ])
    ]
)
