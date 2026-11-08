import Foundation

/// Runs command-line tools and finds the pieces of the VOFocus checkout.
public enum Shell {
    public struct Output: Sendable {
        public let status: Int32
        public let text: String
    }

    /// The Xcode to use: $DEVELOPER_DIR, else Xcode-beta if installed (the iOS 27 SDK
    /// may only be there), else whatever xcode-select points to.
    public static var developerDir: String? {
        if let dir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !dir.isEmpty {
            return dir
        }
        let beta = "/Applications/Xcode-beta.app/Contents/Developer"
        return FileManager.default.fileExists(atPath: beta) ? beta : nil
    }

    static func environment(adding extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let developerDir { environment["DEVELOPER_DIR"] = developerDir }
        environment.merge(extra) { _, new in new }
        return environment
    }

    /// Runs a command to completion and returns its combined output.
    public static func run(_ arguments: [String], in directory: URL? = nil) async throws -> Output {
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "vofocus-\(UUID().uuidString).out")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = environment()
        process.currentDirectoryURL = directory
        process.standardOutput = handle
        process.standardError = handle

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        let text = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        return Output(status: status, text: text)
    }

    /// The UDID of an available iOS Simulator with this name on the given runtime
    /// (e.g. "iOS-27"), so names shared across runtimes aren't ambiguous.
    public static func simulatorUDID(named name: String, runtime: String = "iOS-27") async throws -> String? {
        let output = try await run(["xcrun", "simctl", "list", "devices", "available", "-j"])
        struct Listing: Decodable {
            struct Device: Decodable { let name: String; let udid: String }
            let devices: [String: [Device]]
        }
        let listing = try JSONDecoder().decode(Listing.self, from: Data(output.text.utf8))
        return listing.devices
            .filter { $0.key.contains(runtime) }
            .sorted { $0.key > $1.key }
            .flatMap(\.value)
            .first { $0.name == name }?.udid
    }

    /// The VOFocus checkout: $VOFOCUS_ROOT, or the nearest folder above the current
    /// directory or this executable that has project.yml and Runner/.
    public static func findProjectRoot() -> URL? {
        let fileManager = FileManager.default
        if let root = ProcessInfo.processInfo.environment["VOFOCUS_ROOT"], !root.isEmpty {
            return URL(filePath: root)
        }
        let starts = [
            URL(filePath: fileManager.currentDirectoryPath),
            URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent(),
        ]
        for start in starts {
            var directory = start.standardizedFileURL
            while directory.path != "/" {
                if fileManager.fileExists(atPath: directory.appending(path: "project.yml").path),
                   fileManager.fileExists(atPath: directory.appending(path: "Runner/RunnerTests.swift").path) {
                    return directory
                }
                directory.deleteLastPathComponent()
            }
        }
        return nil
    }
}
