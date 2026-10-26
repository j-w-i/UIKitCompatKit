// swift-tools-version: 5.6
import PackageDescription

// The UIKit APIs that used to live here (Auto Layout, UILayoutGuide, UIStackView,
// UIScrollView refresh control, collection views, compositional layout) are now
// part of the legacy iOS 5 toolchain itself: `import UIKit` provides them and the
// compiler gates them by deployment target. This package keeps only the helpers
// that are intentionally *not* SDK APIs.
let package = Package(
    name: "UIKitCompatKit",
    platforms: [
        .iOS("5.0")
    ],
    products: [
        .library(
            name: "UIKitCompatKit",
            targets: ["UIKitCompatKit"]
        )
    ],
    targets: [
        .target(
            name: "UIKitCompatKit",
            path: "Sources/UIKitCompatKit"
        ),
        .testTarget(
            name: "UIKitCompatKitTests",
            dependencies: ["UIKitCompatKit"]
        ),
    ]
)
