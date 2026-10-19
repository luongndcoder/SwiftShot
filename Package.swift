// swift-tools-version: 5.9
//
// NOTE: This SwiftPM manifest exists only as a fast type-check / compile-check
// harness (`swift build`). It does NOT produce a runnable app: the shipping
// artifact is the macOS app bundle built with Xcode (see `install.sh` and
// `project.yml`), which additionally bundles Info.plist, the entitlements and
// the asset catalog.
//
//   ./generate.sh     # regenerate SwiftShot.xcodeproj from project.yml
//   ./install.sh      # build + sign + install the real app bundle
//
import PackageDescription

let package = Package(
    name: "SwiftShot",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "SwiftShot",
            targets: ["SwiftShot"]
        )
    ],
    targets: [
        .executableTarget(
            name: "SwiftShot",
            path: "Sources",
            exclude: [
                "Info.plist",
                "SwiftShot.entitlements",
                "Resources"
            ]
        )
    ]
)
