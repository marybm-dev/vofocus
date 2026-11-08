// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VOFocusHost",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VOFocusKit", targets: ["VOFocusKit"]),
        .executable(name: "vofocus-mcp", targets: ["vofocus-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    ],
    targets: [
        .target(name: "VOFocusKit"),
        .executableTarget(
            name: "vofocus-mcp",
            dependencies: [
                "VOFocusKit",
                .product(name: "MCP", package: "swift-sdk"),
            ]),
        .testTarget(name: "VOFocusKitTests", dependencies: ["VOFocusKit"]),
    ]
)
