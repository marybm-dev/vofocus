import Foundation
import Testing
@testable import VOFocusKit

struct PlatformMismatchTests {
    func app(_ platforms: [String]) throws -> String {
        let app = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/Test.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleSupportedPlatforms": platforms], format: .binary, options: 0)
        try plist.write(to: app.appending(path: "Info.plist"))
        return app.path
    }

    @Test func simulatorBuildOnADevice() throws {
        let message = RunnerManager.platformMismatch(appAt: try app(["iPhoneSimulator"]), forDevice: true)
        #expect(message?.contains("is a Simulator build") == true)
        #expect(RunnerManager.platformMismatch(appAt: try app(["iPhoneSimulator"]), forDevice: false) == nil)
    }

    @Test func deviceBuildOnASimulator() throws {
        let message = RunnerManager.platformMismatch(appAt: try app(["iPhoneOS"]), forDevice: false)
        #expect(message?.contains("is a device build") == true)
        #expect(RunnerManager.platformMismatch(appAt: try app(["iPhoneOS"]), forDevice: true) == nil)
    }

    @Test func unreadableAppIsLeftToTheInstaller() {
        #expect(RunnerManager.platformMismatch(appAt: "/nonexistent/Test.app", forDevice: true) == nil)
    }
}
