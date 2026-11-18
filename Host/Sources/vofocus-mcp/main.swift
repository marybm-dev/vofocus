import Foundation
import VOFocusKit

// vofocus-mcp: an MCP server (stdio) that lets agents drive real VoiceOver through
// the VOFocus runner. It speaks MCP's JSON-RPC directly (one JSON message per line)
// and needs no MCP library: it implements initialize, ping, tools/list and tools/call.
//
// Environment:
//   VOFOCUS_ROOT       the VOFocus checkout (found automatically when run from inside it)
//   VOFOCUS_PORT       runner port (default 8740)
//   VOFOCUS_SIMULATOR  iOS 27 Simulator name (default "iPhone 18 Pro", newest iOS 27 runtime)
//   VOFOCUS_DEVICE     run on this connected device (name or UDID) instead of a Simulator
//   DEVELOPER_DIR      Xcode to use (default: xcode-select)
//
// stdout carries the protocol, so anything else goes to stderr.

func log(_ message: String) {
    FileHandle.standardError.write(Data("vofocus-mcp: \(message)\n".utf8))
}

guard let root = Shell.findProjectRoot() else {
    log("can't find the VOFocus checkout; run from inside it or set VOFOCUS_ROOT")
    exit(1)
}

let environment = ProcessInfo.processInfo.environment
let manager = RunnerManager(configuration: .init(
    root: root,
    port: environment["VOFOCUS_PORT"].flatMap(Int.init) ?? 8740,
    simulator: environment["VOFOCUS_SIMULATOR"] ?? "iPhone 18 Pro",
    device: environment["VOFOCUS_DEVICE"].flatMap { $0.isEmpty ? nil : $0 }))

/// Protocol versions this server accepts, newest first. It only uses tools, which
/// work the same way in all of them.
let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

/// Sent to the client on initialize; clients show it to the agent.
let instructions = """
    VOFocus drives real VoiceOver on an iOS Simulator or device. Start with runner_start. \
    When you're finished, call runner_stop: it turns VoiceOver off and stops the runner \
    app, leaving the Simulator or device as you found it. Don't leave VoiceOver on for \
    someone to find on their phone. If this server started the runner, it also stops it \
    when the session ends, but stop it yourself as soon as you're done.
    """

/// Writes one message per line; an actor so concurrent replies don't interleave.
actor Output {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return encoder
    }()

    func send(_ message: Value) {
        guard var data = try? encoder.encode(message) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }
}

let output = Output()

func reply(_ id: Value, result: Value) -> Value {
    ["jsonrpc": "2.0", "id": id, "result": result]
}

func reply(_ id: Value, errorCode: Int, _ message: String) -> Value {
    ["jsonrpc": "2.0", "id": id, "error": ["code": .int(errorCode), "message": .string(message)]]
}

/// Handles one request and returns its reply.
func handle(_ method: String, _ params: [String: Value], id: Value) async -> Value {
    switch method {
    case "initialize":
        let requested = params["protocolVersion"]?.stringValue ?? ""
        let version = supportedVersions.contains(requested) ? requested : supportedVersions[0]
        return reply(id, result: [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "vofocus", "version": "0.1.0"],
            "instructions": .string(instructions),
        ])
    case "ping":
        return reply(id, result: [:])
    case "tools/list":
        return reply(id, result: ["tools": .array(ToolCatalog.tools.map(\.json))])
    case "tools/call":
        guard let name = params["name"]?.stringValue else {
            return reply(id, errorCode: -32602, "tools/call needs a tool name")
        }
        let result = await ToolCatalog.call(name, params["arguments"]?.objectValue ?? [:], manager: manager)
        return reply(id, result: result.json)
    default:
        return reply(id, errorCode: -32601, "Method not found: \(method)")
    }
}

// Clean up however the session ends. A client that quits closes stdin (handled after
// the loop below) or sends a signal; either way stop the runner this server started,
// which turns VoiceOver off. A runner started elsewhere is left alone.
var signalSources: [any DispatchSourceSignal] = []
for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        log("got signal \(signalNumber); stopping the runner if this server started it")
        Task {
            await manager.shutdownIfOwned()
            exit(0)
        }
    }
    source.resume()
    signalSources.append(source)
}

log("serving (project: \(root.path), target: \(manager.configuration.targetDescription))")

// Requests run concurrently, so a long tool call (such as runner_start) doesn't hold
// up pings or other calls.
var inFlight: [Task<Void, Never>] = []
do {
    for try await line in FileHandle.standardInput.bytes.lines where !line.isEmpty {
        guard let message = try? JSONDecoder().decode([String: Value].self, from: Data(line.utf8)) else {
            await output.send(reply(.null, errorCode: -32700, "Parse error"))
            continue
        }
        // Responses and notifications (no method, or no id) need no reply.
        guard let method = message["method"]?.stringValue, let id = message["id"] else { continue }
        let params = message["params"]?.objectValue ?? [:]
        inFlight.append(Task {
            await output.send(await handle(method, params, id: id))
        })
    }
} catch {
    log("stdin failed: \(error)")
}
for task in inFlight {
    await task.value
}
await manager.shutdownIfOwned()
