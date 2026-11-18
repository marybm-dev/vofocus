import Foundation
import VOFocusKit
import VOFocusScenarios

let usage = """
    vofocus: check real VoiceOver focus order with YAML scenarios.

    USAGE
      vofocus run <scenario files or folders>... [options]
          Run scenarios and report pass or fail. Exits 1 if any scenario fails.
      vofocus record <scenario file> [--write] [options]
          Run a scenario and fill in its expectations with what VoiceOver actually said.
          Prints the YAML, or overwrites the file with --write. Review the result before
          approving it: the recording is whatever VoiceOver did, bugs included. Comments
          in the file aren't kept.
      vofocus setup [--team <ID>] [--bundle-prefix <prefix>]
          Save the Apple developer team that signs the runner for physical devices
          (the Simulator needs none). Without --team, shows the current settings.
          The bundle prefix defaults to dev.vofocus.<team ID>.
      vofocus --version

    OPTIONS
      --device <name or UDID>  Run on a connected device instead of a Simulator
                               (or set VOFOCUS_DEVICE)
      --simulator <name>       Simulator name, on the newest iOS 27 runtime
                               (default "iPhone 18 Pro")
      --port <number>          Runner port (default 8740)
      --keep-runner            Leave the runner running afterwards, to save start-up
                               time on the next run
      --retries <number>       run: rerun a failed scenario up to this many times
                               (a scenario's own `retries` wins if higher)
      --junit <file>           run: write a JUnit XML report, for CI
      --write                  record: overwrite the scenario file
      --team <ID>              setup: your 10-character Apple developer team ID
      --bundle-prefix <prefix> setup: bundle ID prefix for the runner
      -h, --help               Show this help

    Exit status: 0 all passed, 1 a scenario failed, 2 usage or setup error.
    """

struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct RuntimeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Parsed command-line options.
struct Options {
    var paths: [String] = []
    var device: String?
    var simulator = "iPhone 18 Pro"
    var port = 8740
    var keepRunner = false
    var retries = 0
    var junit: String?
    var write = false
    var team: String?
    var bundlePrefix: String?

    static let valueOptions: Set = ["--device", "--simulator", "--port", "--retries", "--junit", "--team", "--bundle-prefix"]
    static let flags: Set = ["--keep-runner", "--write"]

    /// Parses options in any order; `--name=value` and `--name value` both work.
    static func parse(_ arguments: ArraySlice<String>, allowed: Set<String>) throws -> Options {
        var options = Options()
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            guard argument.hasPrefix("--") else {
                options.paths.append(argument)
                continue
            }
            var name = argument
            var inlineValue: String?
            if let equals = argument.firstIndex(of: "=") {
                name = String(argument[..<equals])
                inlineValue = String(argument[argument.index(after: equals)...])
            }
            guard allowed.contains(name) else { throw UsageError("unknown option \(name)") }
            if flags.contains(name) {
                if name == "--keep-runner" { options.keepRunner = true }
                if name == "--write" { options.write = true }
                continue
            }
            guard let value = inlineValue ?? rest.popFirst() else { throw UsageError("\(name) needs a value") }
            switch name {
            case "--device": options.device = value
            case "--simulator": options.simulator = value
            case "--port":
                guard let port = Int(value) else { throw UsageError("--port needs a number") }
                options.port = port
            case "--retries":
                guard let retries = Int(value), retries >= 0 else { throw UsageError("--retries needs a number") }
                options.retries = retries
            case "--junit": options.junit = value
            case "--team": options.team = value
            case "--bundle-prefix": options.bundlePrefix = value
            default: break
            }
        }
        return options
    }

    func makeManager() throws -> RunnerManager {
        guard let installation = Installation.locate() else {
            throw RuntimeError(Installation.notFoundMessage)
        }
        let device = self.device ?? ProcessInfo.processInfo.environment["VOFOCUS_DEVICE"].flatMap { $0.isEmpty ? nil : $0 }
        return RunnerManager(configuration: .init(installation: installation, port: port, simulator: simulator, device: device))
    }
}

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Starts the runner (or attaches to one) and waits until it's ready.
func readyRunner(_ manager: RunnerManager) async throws -> RunnerClient {
    note("Starting the runner on \(manager.configuration.targetDescription)…")
    let started = Date()
    var lastNote: String?
    while true {
        switch try await manager.start(wait: 30) {
        case .waitingForUser(let reason):
            if reason != lastNote { note(reason) }
            lastNote = reason
            guard Date().timeIntervalSince(started) < 900 else {
                throw RuntimeError("The runner didn't start within 15 minutes: \(reason)")
            }
        case .ready:
            note("Runner ready (\(Int(Date().timeIntervalSince(started))) s).")
            return try await manager.client()
        case .failed(let logTail):
            throw RuntimeError("The runner failed to start. End of its log:\n\(logTail)")
        case .starting, .stopped:
            guard Date().timeIntervalSince(started) < 900 else {
                throw RuntimeError("The runner didn't start within 15 minutes; see \(manager.configuration.logURL.path).")
            }
            note("  still starting (\(Int(Date().timeIntervalSince(started))) s)…")
        }
    }
}

/// Collects scenario files from files and folders (*.yml, *.yaml), sorted by path.
func scenarioFiles(_ paths: [String]) throws -> [URL] {
    var files: [URL] = []
    for path in paths {
        let url = URL(filePath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw UsageError("no such file or folder: \(path)")
        }
        if isDirectory.boolValue {
            let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            files += contents.filter { ["yml", "yaml"].contains($0.pathExtension) }
        } else {
            files.append(url)
        }
    }
    return files.sorted { $0.path < $1.path }
}

/// Installs a scenario's app, if it names one.
func installIfNeeded(_ scenario: Scenario, manager: RunnerManager) async throws {
    guard let install = scenario.install else { return }
    let base = scenario.file?.deletingLastPathComponent() ?? URL(filePath: FileManager.default.currentDirectoryPath)
    let path = install.hasPrefix("/") ? install : base.appending(path: install).standardizedFileURL.path
    let output = try await manager.install(appAt: path)
    guard output.status == 0 else { throw RuntimeError("Installing \(path) failed:\n\(output.text)") }
}

// MARK: - Commands

/// Returns the exit status: 0 if every scenario passed or was skipped, 1 otherwise.
func runCommand(_ options: Options) async throws -> Int32 {
    let files = try scenarioFiles(options.paths)
    guard !files.isEmpty else { throw UsageError("no scenario files given or found") }
    let scenarios = try files.map { try Scenario.load(from: $0) }

    let manager = try options.makeManager()
    let onDevice = manager.configuration.device != nil
    let runner = ScenarioRunner(client: try await readyRunner(manager))
    var results: [ScenarioResult] = []

    for scenario in scenarios {
        if scenario.deviceOnly && !onDevice {
            let skipped = ScenarioResult(scenario: scenario, steps: [], seconds: 0, skipped: "device only", attempts: 0)
            Report.print(skipped)
            results.append(skipped)
            continue
        }
        try await installIfNeeded(scenario, manager: manager)
        var attempts = 0
        var result: ScenarioResult
        repeat {
            attempts += 1
            result = await runner.run(scenario)
        } while !result.passed && attempts <= max(options.retries, scenario.retries)
        result = ScenarioResult(scenario: result.scenario, steps: result.steps, seconds: result.seconds,
                                skipped: nil, attempts: attempts)
        Report.print(result)
        results.append(result)
    }

    if !options.keepRunner {
        await manager.shutdownIfOwned()
    }
    Report.printSummary(results)
    if let junit = options.junit {
        try Report.junit(results, target: manager.configuration.targetDescription)
            .write(toFile: junit, atomically: true, encoding: .utf8)
        note("JUnit report: \(junit)")
    }
    return results.contains { $0.skipped == nil && !$0.passed } ? 1 : 0
}

func recordCommand(_ options: Options) async throws -> Int32 {
    guard options.paths.count == 1 else { throw UsageError("record takes exactly one scenario file") }
    let url = URL(filePath: options.paths[0]).standardizedFileURL
    // Run with ${NAME} placeholders replaced, but write back the version that keeps them.
    let scenario = try Scenario.load(from: url)
    let template = try Scenario.loadTemplate(from: url)

    let manager = try options.makeManager()
    // Start the runner first: it boots the Simulator, which installing needs.
    let runner = ScenarioRunner(client: try await readyRunner(manager))
    try await installIfNeeded(scenario, manager: manager)
    let result = await runner.run(scenario)
    if !options.keepRunner {
        await manager.shutdownIfOwned()
    }
    Report.print(result)

    let yaml = ScenarioWriter.yaml(for: template, recordedFrom: result)
    if options.write {
        try yaml.write(to: url, atomically: true, encoding: .utf8)
        note("Wrote \(url.path). Review the changes (git diff) before committing.")
    } else {
        print(yaml, terminator: "")
    }
    if !result.passed {
        note("Note: a step failed, so later steps weren't recorded.")
        return 1
    }
    return 0
}

// MARK: - Setup

/// Writes (or, without --team, shows) the signing settings runner.sh uses for devices.
func setupCommand(_ options: Options) throws -> Int32 {
    guard options.paths.isEmpty else { throw UsageError("setup takes no file arguments") }
    let url = Installation.signingConfigURL()
    guard let team = options.team else {
        guard options.bundlePrefix == nil else { throw UsageError("--bundle-prefix needs --team") }
        if let saved = try? String(contentsOf: url, encoding: .utf8) {
            print("Device signing (\(url.path)):")
            for line in saved.split(separator: "\n") where !line.hasPrefix("//") { print("  \(line)") }
        } else {
            print("No device signing set up; the Simulator needs none. For a device, run:")
            print("  vofocus setup --team <your team ID>")
            print("Your team ID is in Xcode > Settings > Accounts, or at developer.apple.com/account.")
        }
        if let installation = Installation.locate() {
            print("Runner files: \(installation.root.path)")
            print("Builds, logs and tokens: \(installation.buildDirectory.path)")
        }
        return 0
    }
    guard team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil else {
        throw UsageError("--team needs a 10-character team ID such as ABCDE12345")
    }
    if let prefix = options.bundlePrefix,
       prefix.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) == nil {
        throw UsageError("--bundle-prefix needs a reverse-DNS prefix such as com.example.vofocus")
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Installation.signingConfig(team: team, bundlePrefix: options.bundlePrefix)
        .write(to: url, atomically: true, encoding: .utf8)
    print("Saved device signing to \(url.path). The next runner start on a device uses it.")
    return 0
}

// MARK: - Main

// Line-buffer stdout so results and stderr notes stay in order when piped (as in CI).
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = CommandLine.arguments.dropFirst()
do {
    if arguments.first == "--version" || arguments.first == "version" {
        print(Installation.version)
        exit(0)
    }
    guard let command = arguments.first, !["-h", "--help", "help"].contains(command) else {
        print(usage)
        exit(arguments.isEmpty ? 2 : 0)
    }
    let rest = arguments.dropFirst()
    if rest.contains(where: { $0 == "-h" || $0 == "--help" }) {
        print(usage)
        exit(0)
    }
    switch command {
    case "run":
        let allowed: Set = ["--device", "--simulator", "--port", "--keep-runner", "--retries", "--junit"]
        exit(try await runCommand(Options.parse(rest, allowed: allowed)))
    case "record":
        let allowed: Set = ["--device", "--simulator", "--port", "--keep-runner", "--write"]
        exit(try await recordCommand(Options.parse(rest, allowed: allowed)))
    case "setup":
        exit(try setupCommand(Options.parse(rest, allowed: ["--team", "--bundle-prefix"])))
    default:
        throw UsageError("unknown command \(command)")
    }
} catch let error as UsageError {
    note("vofocus: \(error)\n\n\(usage)")
    exit(2)
} catch {
    note("vofocus: \(error)")
    exit(2)
}
