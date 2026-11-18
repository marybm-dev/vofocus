import Foundation

/// Where VOFocus's files are.
///
/// `root` holds what the runner is built from (the Xcode project, `Runner/` and
/// `scripts/`) and is only read. `buildDirectory` gets the runner's build, its logs and
/// the per-session tokens.
///
/// - **A checkout**, found from `$VOFOCUS_ROOT`, the current directory or the
///   executable's folder: both are in the checkout, with builds in `<checkout>/build`.
/// - **Installed** (Homebrew): `root` is `share/vofocus` beside the executable's `bin`,
///   and builds go to `~/Library/Caches/vofocus`.
///
/// `$VOFOCUS_BUILD_DIR` overrides the build directory either way.
public struct Installation: Sendable, Equatable {
    public static let version = "0.1.0"

    public var root: URL
    public var buildDirectory: URL

    public init(root: URL, buildDirectory: URL) {
        self.root = root
        self.buildDirectory = buildDirectory
    }

    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath),
        executable: URL? = Bundle.main.executableURL
    ) -> Installation? {
        let buildOverride = environment["VOFOCUS_BUILD_DIR"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
        func checkout(_ root: URL) -> Installation {
            Installation(root: root, buildDirectory: buildOverride ?? root.appending(path: "build"))
        }

        if let root = environment["VOFOCUS_ROOT"], !root.isEmpty {
            return checkout(URL(filePath: root))
        }
        let executableFolder = executable?.resolvingSymlinksInPath().deletingLastPathComponent()
        for start in [currentDirectory, executableFolder].compactMap(\.self) {
            var directory = start.standardizedFileURL
            while directory.path != "/" {
                if isRoot(directory) { return checkout(directory) }
                directory.deleteLastPathComponent()
            }
        }
        // Installed: <prefix>/bin/vofocus and <prefix>/share/vofocus.
        if let share = executableFolder?.deletingLastPathComponent().appending(path: "share/vofocus"),
           isRoot(share) {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Caches")
            return Installation(root: share, buildDirectory: buildOverride ?? caches.appending(path: "vofocus"))
        }
        return nil
    }

    /// Has what runner.sh needs to build and start the runner.
    static func isRoot(_ directory: URL) -> Bool {
        ["scripts/runner.sh", "Runner/RunnerTests.swift"].allSatisfy {
            FileManager.default.fileExists(atPath: directory.appending(path: $0).path)
        }
    }

    public static let notFoundMessage = """
        Can't find VOFocus's runner files. Run from inside a VOFocus checkout, set \
        VOFOCUS_ROOT to one, or reinstall (an installed vofocus looks in ../share/vofocus).
        """

    // MARK: - Signing

    /// Signing settings for devices, written by `vofocus setup` and read by runner.sh:
    /// `$XDG_CONFIG_HOME/vofocus/signing.xcconfig`, or `~/.config/vofocus/signing.xcconfig`.
    public static func signingConfigURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
            ?? URL(filePath: NSHomeDirectory()).appending(path: ".config")
        return base.appending(path: "vofocus/signing.xcconfig")
    }

    /// The contents of signing.xcconfig. Bundle IDs are unique across all of Apple's
    /// developer teams, so the default prefix includes the team ID.
    public static func signingConfig(team: String, bundlePrefix: String?) -> String {
        let prefix = bundlePrefix ?? "dev.vofocus.\(team.lowercased())"
        return """
            // Written by `vofocus setup`. Used to sign the runner for physical devices.
            DEVELOPMENT_TEAM = \(team)
            VOFOCUS_BUNDLE_PREFIX = \(prefix)

            """
    }
}
