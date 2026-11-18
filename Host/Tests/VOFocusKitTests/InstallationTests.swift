import Foundation
import Testing
@testable import VOFocusKit

@Suite struct InstallationTests {
    /// A temporary folder with VOFocus's runner files at `path` inside it.
    private func makeRoot(at path: String) throws -> (base: URL, root: URL) {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "vofocus-tests-\(UUID().uuidString)").resolvingSymlinksInPath()
        let root = path.isEmpty ? base : base.appending(path: path)
        for file in ["scripts/runner.sh", "Runner/RunnerTests.swift"] {
            let url = root.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        return (base, root)
    }

    /// The path without a trailing slash, since URLs for the same folder can differ in it.
    private func path(_ url: URL?) -> String? {
        url.map { $0.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/") }
    }

    @Test func checkoutFromCurrentDirectoryBuildsInside() throws {
        let (base, root) = try makeRoot(at: "")
        defer { try? FileManager.default.removeItem(at: base) }
        let nested = root.appending(path: "scenarios/demo")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let found = Installation.locate(environment: [:], currentDirectory: nested, executable: nil)
        #expect(path(found?.root) == path(root))
        #expect(path(found?.buildDirectory) == path(root.appending(path: "build")))
    }

    @Test func installedUsesShareAndCaches() throws {
        let (base, root) = try makeRoot(at: "share/vofocus")
        defer { try? FileManager.default.removeItem(at: base) }
        let executable = base.appending(path: "bin/vofocus")

        let found = Installation.locate(
            environment: [:], currentDirectory: URL(filePath: "/"), executable: executable)
        #expect(path(found?.root) == path(root))
        #expect(found?.buildDirectory.path.hasSuffix("Library/Caches/vofocus") == true)
    }

    @Test func environmentOverridesBoth() throws {
        let found = Installation.locate(
            environment: ["VOFOCUS_ROOT": "/src/vofocus", "VOFOCUS_BUILD_DIR": "/tmp/vo"],
            currentDirectory: URL(filePath: "/"), executable: nil)
        #expect(found == Installation(root: URL(filePath: "/src/vofocus"), buildDirectory: URL(filePath: "/tmp/vo")))
    }

    @Test func notFoundOutsideAnyInstallation() {
        #expect(Installation.locate(environment: [:], currentDirectory: URL(filePath: "/"), executable: nil) == nil)
    }

    @Test func signingConfigDefaultsPrefixToTeam() {
        let config = Installation.signingConfig(team: "ABCDE12345", bundlePrefix: nil)
        #expect(config.contains("DEVELOPMENT_TEAM = ABCDE12345"))
        #expect(config.contains("VOFOCUS_BUNDLE_PREFIX = dev.vofocus.abcde12345"))
        #expect(Installation.signingConfigURL(environment: ["XDG_CONFIG_HOME": "/cfg"]).path
            == "/cfg/vofocus/signing.xcconfig")
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
