// swift-tools-version:6.2
import PackageDescription

// XKit source pinned to 2af0b67447d30063235e2adb7bdc77012f431d3a.
// LocSign builds only the library products; CLI/platform tools are excluded.
let package = Package(
    name: "xtool",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "XKit", targets: ["XKit"]),
        .library(name: "DeveloperAPI", targets: ["DeveloperAPI"]),
        .library(name: "XUtils", targets: ["XUtils"])
    ],
    dependencies: [
        .package(path: "../xtool-core"),
        .package(url: "https://github.com/krzyzanowskim/OpenSSL", exact: "3.6.5000"),
        .package(url: "https://github.com/apple/swift-system", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.3.1"),
        .package(url: "https://github.com/apple/swift-certificates", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess", from: "1.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", from: "1.3.0"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.6.2"),
        .package(url: "https://github.com/attaswift/BigInt", from: "6.0.0")
    ],
    targets: [
        .target(name: "CXKit", dependencies: [.product(name: "OpenSSL", package: "OpenSSL")],
                cSettings: [.define("XTOOL_HAS_UNCOMMITTED_CHANGES", to: "0"),
                            .define("XTOOL_VERSION", to: "\"2af0b67447d30063235e2adb7bdc77012f431d3a\"")]),
        .target(name: "DeveloperAPI", dependencies: [.product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")],
                exclude: ["openapi-generator-config.yaml", "patch.js"]),
        .target(name: "XUtils", dependencies: [
            "CXKit", .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
            .product(name: "Dependencies", package: "swift-dependencies"),
            .product(name: "SystemPackage", package: "swift-system"),
            .product(name: "Subprocess", package: "swift-subprocess", condition: .when(platforms: [.macOS]))
        ]),
        .target(name: "XKit", dependencies: [
            "DeveloperAPI", "CXKit", "XUtils",
            .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
            .product(name: "Dependencies", package: "swift-dependencies"),
            .product(name: "ProtoCodable", package: "xtool-core"),
            .product(name: "Superutils", package: "xtool-core"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "CryptoExtras", package: "swift-crypto"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "BigInt", package: "BigInt"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
            .product(name: "HTTPTypesFoundation", package: "swift-http-types"),
            .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession")
        ], exclude: [
            "Installation", "Integration", "Signer",
            "DeveloperServices/App Groups/DeveloperServicesAddAppGroupRequest.swift",
            "DeveloperServices/App Groups/DeveloperServicesListAppGroupsRequest.swift",
            "DeveloperServices/App Groups/DeveloperServicesAssignAppGroupsOperation.swift",
            "DeveloperServices/App Groups/DeveloperServicesAssignAppGroupRequest.swift",
            "DeveloperServices/App IDs",
            "DeveloperServices/Certificates", "DeveloperServices/Devices",
            "DeveloperServices/Profiles", "DeveloperServices/DeveloperServicesOperation.swift",
            "DeveloperServices/DeveloperServicesProvisioningOperation.swift",
            "Utilities/ProvisioningIdentifiers.swift", "Utilities/SigningInfo.swift",
            "Utilities/ZIPCompressor.swift"
        ])
    ]
)
