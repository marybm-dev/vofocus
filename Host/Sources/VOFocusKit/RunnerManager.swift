import Foundation

/// Starts, watches and stops the runner (scripts/runner.sh, which restarts the
/// Simulator, builds the runner and serves until POST /shutdown).
public actor RunnerManager {
    public struct Configuration: Sendable {
        public var root: URL
        public var port: Int
        public var simulator: String

        public init(root: URL, port: Int = 8740, simulator: String = "iPhone 18 Pro") {
            self.root = root
            self.port = port
            self.simulator = simulator
        }

        public var logURL: URL { root.appending(path: "build/runner-mcp.log") }
    }

    public enum State: Sendable, Equatable {
        case stopped
        case starting
        /// Answering on its port. `owned` is false when someone else started it.
        case ready(owned: Bool)
        /// The runner process exited before it was ready; the log tail says why.
        case failed(logTail: String)
    }

    public let configuration: Configuration
    public let client: RunnerClient
    private var process: Process?
    private var exitedEarly = false

    public init(configuration: Configuration) {
        self.configuration = configuration
        client = RunnerClient(port: configuration.port)
    }

    public func state() async -> State {
        if await client.isUp() {
            return .ready(owned: process?.isRunning == true)
        }
        if let process, process.isRunning {
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
            case .starting, .stopped: try await Task.sleep(for: .seconds(1))
            }
        }
        return await state()
    }

    /// Asks the runner to shut down and waits for xcodebuild to exit, so whatever
    /// runs next (another runner, a Simulator restart) doesn't cut it short.
    public func stop(timeout: TimeInterval = 90) async -> String {
        let wasUp = await client.isUp()
        if wasUp {
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
        process.arguments = [configuration.root.appending(path: "scripts/runner.sh").path]
        process.currentDirectoryURL = configuration.root
        process.environment = Shell.environment(adding: [
            "PORT": String(configuration.port),
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
        try process.run()
        self.process = process
    }

    private func markExited() async {
        guard let process else { return }
        // Exiting before ever answering on the port is a failed start.
        if !(await client.isUp()) && process.terminationStatus != 0 {
            exitedEarly = true
        }
        self.process = nil
    }

    private func logTail(lines: Int = 25) -> String {
        guard let text = try? String(contentsOf: configuration.logURL, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    /// Installs an .app on the runner's Simulator.
    public func install(appAt path: String) async throws -> Shell.Output {
        guard let udid = try await Shell.simulatorUDID(named: configuration.simulator) else {
            return Shell.Output(status: 1, text: "No iOS 27 Simulator named \"\(configuration.simulator)\".")
        }
        return try await Shell.run(["xcrun", "simctl", "install", udid, path])
    }

    /// Stops the runner if this manager started it. Call when the host process exits.
    public func shutdownIfOwned() async {
        if process != nil {
            _ = await stop(timeout: 30)
        }
    }
}
