// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VOFocusHost",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VOFocusKit", targets: ["VOFocusKit"]),
        .executable(name: "vofocus-mcp", targets: ["vofocus-mcp"]),
        .executable(name: "vofocus", targets: ["vofocus"]),
    ],
    dependencies: [
        // The only dependency, for the YAML scenario format.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(name: "VOFocusKit"),
        .target(
            name: "VOFocusScenarios",
            dependencies: ["VOFocusKit", .product(name: "Yams", package: "Yams")]),
        .executableTarget(
            name: "vofocus",
            dependencies: ["VOFocusKit", "VOFocusScenarios"]),
        .executableTarget(
            name: "vofocus-mcp",
            dependencies: ["VOFocusKit"]),
        .testTarget(name: "VOFocusKitTests", dependencies: ["VOFocusKit"]),
        .testTarget(name: "VOFocusScenariosTests", dependencies: ["VOFocusScenarios"]),
    ]
)
