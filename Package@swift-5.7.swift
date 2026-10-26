// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "UIKitCompatKit",
    platforms: [
        .iOS("5.0")
    ],
    products: [
        .library(
            name: "UIKitCompatKit",
            targets: ["UIKitCompatKit"]
        ),
        // Pure-Swift Cassowary solver used by the legacy Auto Layout backport.
        .library(
            name: "Cassowary",
            targets: ["Cassowary"]
        ),
        // Swift port of RRAutoLayout (iOS 6 Auto Layout backport) backed by Cassowary.
        .library(
            name: "LegacyAutoLayout",
            targets: ["LegacyAutoLayout"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/j-w-i/IBPCollectionViewCompositionalLayout", branch: "master")
    ],
    targets: [
        .target(name: "LegacyAutoLayoutBootstrap", path: "Sources/LegacyAutoLayoutBootstrap", publicHeadersPath: "include"),
        .target(
            name: "UIKitCompatKit",
            dependencies: ["OAStackView", "LiveFrost", "IBPCollectionViewCompositionalLayout", "LegacyAutoLayout"],
            path: "Sources/UIKitCompatKit",
            swiftSettings: [
                .define("MODERN_BUILD")
            ]
        ),
        .target(
            name: "Cassowary",
            path: "Sources/Cassowary"
        ),
        .target(
            name: "LegacyAutoLayout",
            dependencies: ["Cassowary", "LegacyAutoLayoutBootstrap"],
            path: "Sources/LegacyAutoLayout"
        ),
        .target(
            name: "OAStackView",
            path: "Sources/OAStackView",
            publicHeadersPath: "."
        ),
        .target(
            name: "LiveFrost",
            path: "Sources/LiveFrost",
            publicHeadersPath: "."
        ),
        .testTarget(
            name: "UIKitCompatKitTests",
            dependencies: ["UIKitCompatKit", "Cassowary", "LegacyAutoLayout"]
        ),
    ]
)
