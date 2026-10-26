// swift-tools-version: 5.6
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
        .target(
            name: "UIKitCompatKit",
            dependencies: ["OAStackView", "LiveFrost", "IBPCollectionViewCompositionalLayout", "LegacyAutoLayout", "PSTCollectionView"],
            path: "Sources/UIKitCompatKit"
        ),
        .target(
            name: "Cassowary",
            path: "Sources/Cassowary"
        ),
        .target(
            name: "LegacyAutoLayout",
            dependencies: ["Cassowary"],
            path: "Sources/LegacyAutoLayout"
        ),
        // PSTCollectionView: registers UICollectionView-named classes at load
        // time on iOS 5 (MIT, see Sources/PSTCollectionView/LICENSE).
        .target(
            name: "PSTCollectionView",
            path: "Sources/PSTCollectionView",
            publicHeadersPath: "."
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
