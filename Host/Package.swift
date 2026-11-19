// swift-tools-version: 6.0
import Foundation
import PackageDescription

// macOS asks before an app records system audio (`vofocus run --audio`, audio_start),
// and shows NSAudioCaptureUsageDescription from the executable's embedded Info.plist.
func embeddedInfoPlist(_ target: String) -> [LinkerSetting] {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Sources/\(target)/Info.plist").path
    return [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", path])]
}

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
        // Experimental: records VoiceOver's speech and sounds on the Simulator.
        .target(name: "VOFocusAudio", dependencies: ["VOFocusKit"]),
        .target(
            name: "VOFocusScenarios",
            dependencies: ["VOFocusKit", .product(name: "Yams", package: "Yams")]),
        .executableTarget(
            name: "vofocus",
            dependencies: ["VOFocusKit", "VOFocusScenarios", "VOFocusAudio"],
            exclude: ["Info.plist"],
            linkerSettings: embeddedInfoPlist("vofocus")),
        .executableTarget(
            name: "vofocus-mcp",
            dependencies: ["VOFocusKit", "VOFocusAudio"],
            exclude: ["Info.plist"],
            linkerSettings: embeddedInfoPlist("vofocus-mcp")),
        .testTarget(name: "VOFocusKitTests", dependencies: ["VOFocusKit"]),
        .testTarget(name: "VOFocusScenariosTests", dependencies: ["VOFocusScenarios"]),
        .testTarget(name: "VOFocusAudioTests", dependencies: ["VOFocusAudio"]),
    ]
)
