import Foundation

/// Starts, watches and stops the runner (scripts/runner.sh, which builds the runner
/// and serves until POST /shutdown) on a Simulator or a connected device.
public actor RunnerManager {
    public struct Configuration: Sendable {
        public var installation: Installation
        public var port: Int
        public var simulator: String
        /// A connected device's name or UDID. When set, the runner runs there instead of
        /// on the Simulator and is reached over the cable's CoreDevice tunnel.
        public var device: String?

        public init(installation: Installation, port: Int = 8740, simulator: String = "iPhone 18 Pro", device: String? = nil) {
            self.installation = installation
            self.port = port
            self.simulator = simulator
            self.device = device
        }

        /// "device <name>" or "Simulator <name>", for messages.
        public var targetDescription: String {
            device.map { "device \($0)" } ?? "Simulator \(simulator)"
        }

        public var logURL: URL { installation.buildDirectory.appending(path: "runner-mcp.log") }
    }

    public enum State: Sendable, Equatable {
        case stopped
        case starting
        /// Starting, but blocked until someone acts, such as unlocking the device.
        case waitingForUser(String)
        /// Answering on its port. `owned` is false when someone else started it.
        case ready(owned: Bool)
        /// The runner process exited before it was ready; the log tail says why.
        case failed(logTail: String)
    }

    public enum Failure: Error, CustomStringConvertible {
        case deviceUnreachable(String)

        public var description: String {
            switch self {
            case .deviceUnreachable(let device):
                "Can't reach device \(device). Is it connected by cable, unlocked and trusted?"
            }
        }
    }

    nonisolated public let configuration: Configuration
    private var cachedClient: RunnerClient?
    private var process: Process?
    private var exitedEarly = false
    private var launchedAt: Date?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// The client for the runner. On a device this looks up the tunnel address, which
    /// changes if the device reconnects, and every start makes a new token, so both are
    /// re-read whenever the runner isn't up.
    public func client() async throws -> RunnerClient {
        if let cachedClient { return cachedClient }
        let client: RunnerClient
        let token = RunnerClient.savedToken(buildDirectory: configuration.installation.buildDirectory, port: configuration.port)
        if let device = configuration.device {
            guard let address = try await Shell.deviceTunnelAddress(device) else {
                throw Failure.deviceUnreachable(device)
            }
            client = RunnerClient(host: address, port: configuration.port, token: token)
        } else {
            client = RunnerClient(port: configuration.port, token: token)
        }
        cachedClient = client
        return client
    }

    private func isUp() async -> Bool {
        guard let client = try? await client() else { return false }
        if await client.isUp() { return true }
        cachedClient = nil
        return false
    }

    public func state() async -> State {
        if await isUp() {
            return .ready(owned: process?.isRunning == true)
        }
        if let process, process.isRunning {
            if let reason = blockingReason() { return .waitingForUser(reason) }
            return .starting
        }
        if exitedEarly {
            return .failed(logTail: logTail())
        }
        return .stopped
    }

    /// Starts the runner if needed and waits up to `wait` seconds for it. A first
    /// start (Simulator restart plus build) often takes longer; in that case this
    /// returns `.starting` and the runner keeps coming up in the background.
    public func start(wait: TimeInterval, freshSimulator: Bool = true) async throws -> State {
        let current = await state()
        if case .ready = current { return current }
        if current != .starting {
            try launch(freshSimulator: freshSimulator)
        }
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            let now = await state()
            switch now {
            case .ready, .failed: return now
            case .starting, .stopped, .waitingForUser: try await Task.sleep(for: .seconds(1))
            }
        }
        return await state()
    }

    /// Asks the runner to shut down and waits for xcodebuild to exit, so whatever
    /// runs next (another runner, a Simulator restart) doesn't cut it short.
    public func stop(timeout: TimeInterval = 90) async -> String {
        let wasUp = await isUp()
        if wasUp, let client = try? await client() {
            _ = try? await client.send("POST", "/shutdown", timeout: 10)
        }
        guard let process else {
            return wasUp ? "Asked the runner to shut down (it was started elsewhere)." : "No runner was running."
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if process.isRunning {
            process.terminate()
            self.process = nil
            return "The runner didn't exit within \(Int(timeout)) s, so it was terminated."
        }
        self.process = nil
        return "Runner stopped (exit status \(process.terminationStatus))."
    }

    private func launch(freshSimulator: Bool) throws {
        let log = configuration.logURL
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)

        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [configuration.installation.root.appending(path: "scripts/runner.sh").path]
            + (configuration.device.map { ["--device", $0] } ?? [])
        process.currentDirectoryURL = configuration.installation.root
        process.environment = Shell.environment(adding: [
            "PORT": String(configuration.port),
            "VOFOCUS_BUILD_DIR": configuration.installation.buildDirectory.path,
            "SIM_NAME": configuration.simulator,
            "FRESH_SIM": freshSimulator ? "1" : "0",
        ])
        // Never inherit stdout: for an MCP server it carries the protocol.
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            try? handle.close()
            Task { await self?.markExited() }
        }
        exitedEarly = false
        launchedAt = Date()
        try process.run()
        self.process = process
    }

    private func markExited() async {
        guard let process else { return }
        // Exiting before ever answering on the port is a failed start.
        if !(await isUp()) && process.terminationStatus != 0 {
            exitedEarly = true
        }
        self.process = nil
    }

    /// Something in the runner's log that needs a person: Xcode waits indefinitely for
    /// a locked device instead of failing.
    private func blockingReason() -> String? {
        // runner.sh passes only VOFocus lines through to our log; xcodebuild's own
        // messages, such as the locked-device one, are in its full log.
        let fullLog = configuration.installation.buildDirectory.appending(path: "runner.log")
        // Ignore a log left over from an earlier run.
        guard let launchedAt,
              let modified = try? fullLog.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              modified >= launchedAt
        else { return nil }
        let tail = (try? String(contentsOf: fullLog, encoding: .utf8))?.suffix(6000) ?? ""
        if tail.contains("device is locked") {
            let device = configuration.device ?? "the device"
            return "Unlock \(device) to continue: Xcode can't start the runner while it's locked."
        }
        return nil
    }

    private func logTail(lines: Int = 25) -> String {
        guard let text = try? String(contentsOf: configuration.logURL, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    /// Installs an .app on the runner's Simulator or device (a build for that platform).
    public func install(appAt path: String) async throws -> Shell.Output {
        if let mismatch = Self.platformMismatch(appAt: path, forDevice: configuration.device != nil) {
            return Shell.Output(status: 1, text: mismatch)
        }
        if let device = configuration.device {
            return try await Shell.run(["xcrun", "devicectl", "device", "install", "app", "--device", device, path])
        }
        guard let udid = try await Shell.simulatorUDID(named: configuration.simulator) else {
            return Shell.Output(status: 1, text: "No iOS 27 Simulator named \"\(configuration.simulator)\".")
        }
        return try await Shell.run(["xcrun", "simctl", "install", udid, path])
    }

    /// Explains why an .app built for the other platform can't be installed, instead of
    /// devicectl's code-signature error or simctl's architecture error. Nil when the app
    /// matches, or its Info.plist can't be read (the install then reports its own error).
    static func platformMismatch(appAt path: String, forDevice: Bool) -> String? {
        let plist = URL(filePath: path).appending(path: "Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let platforms = info["CFBundleSupportedPlatforms"] as? [String] else { return nil }
        let builtForSimulator = platforms.contains("iPhoneSimulator")
        if forDevice && builtForSimulator {
            return """
            \(path) is a Simulator build, so it can't be installed on a device. Build it for \
            the device (a Debug-iphoneos folder) and point `install` at that, or leave \
            `install` out to use the copy already on the phone.
            """
        }
        if !forDevice && platforms.contains("iPhoneOS") && !builtForSimulator {
            return """
            \(path) is a device build, so it can't be installed on a Simulator. Build it for \
            the Simulator (a Debug-iphonesimulator folder) and point `install` at that.
            """
        }
        return nil
    }

    /// Stops the runner if this manager started it. Call when the host process exits.
    public func shutdownIfOwned() async {
        if process != nil {
            _ = await stop(timeout: 30)
        }
    }
}
