// swift-tools-version: 5.9
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
