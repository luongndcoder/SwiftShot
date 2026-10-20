// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftShotMCP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "swiftshot-mcp",
            targets: ["SwiftShotMCP"]
        )
    ],
    targets: [
        .executableTarget(
            name: "SwiftShotMCP",
            path: "Sources/SwiftShotMCP"
        )
    ]
)
