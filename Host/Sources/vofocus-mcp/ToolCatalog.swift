import Foundation
import MCP
import VOFocusKit

/// The MCP tools. Each one is a thin layer over a runner endpoint; descriptions carry
/// what an agent needs to know about how VoiceOver behaves under automation.
enum ToolCatalog {
    // MARK: - Schemas

    private static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }

    private static func prop(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static let element: Value = .object([
        "type": "object",
        "description": """
            Finds one element. Give an identifier (accessibilityIdentifier) or a label, or both. \
            Use ui_tree to see what's there.
            """,
        "properties": .object([
            "identifier": prop("string", "accessibilityIdentifier"),
            "label": prop("string", "Exact accessibility label"),
            "type": prop("string", "Element type, e.g. button, staticText, textField, cell"),
            "index": prop("integer", "Which match to use when several match (default 0)"),
            "timeout": prop("number", "Seconds to wait for it to exist (default 3)"),
        ]),
    ])

    static let tools: [Tool] = [
        Tool(
            name: "runner_start",
            description: """
                Start the VOFocus runner on the iOS 27 Simulator, or attach to one already running. \
                A first start restarts the Simulator and builds the runner, which can take a few \
                minutes; if it isn't ready within `wait` seconds this returns "starting" and you \
                should call runner_status until it's "ready". Required before any other tool.
                """,
            inputSchema: object([
                "wait": prop("integer", "Seconds to wait for the runner (default 45)"),
                "freshSimulator": prop("boolean",
                    "Restart the Simulator first (default true). VoiceOver can get stuck in a state only a restart clears."),
            ])),
        Tool(
            name: "runner_status",
            description: "Whether the runner is starting, ready, stopped or failed (with the end of its log).",
            inputSchema: object([:])),
        Tool(
            name: "runner_stop",
            description: "Stop the runner and wait for it to exit.",
            inputSchema: object([:])),
        Tool(
            name: "app_install",
            description: "Install a built .app (a Simulator build) on the runner's Simulator.",
            inputSchema: object(["path": prop("string", "Path to the .app bundle")], required: ["path"])),
        Tool(
            name: "app_launch",
            description: """
                Launch or relaunch an app with VoiceOver on. Use launch arguments or environment to \
                open the screen under test directly. Returns `utterance`, where VoiceOver landed, \
                only for the first launch of a runner; after that it's null because VoiceOver doesn't \
                speak on a relaunch, though focus still starts on the first element.
                """,
            inputSchema: object([
                "bundleId": prop("string", "The app's bundle identifier"),
                "arguments": .object(["type": "array", "items": .object(["type": "string"]),
                                      "description": "Launch arguments, e.g. [\"-Screen\", \"settings\"]"]),
                "environment": .object(["type": "object", "additionalProperties": .object(["type": "string"]),
                                        "description": "Launch environment variables"]),
                "voiceOver": prop("boolean", "Run with VoiceOver on (default true)"),
            ], required: ["bundleId"])),
        Tool(
            name: "vo_move",
            description: """
                Move VoiceOver one step, like a swipe, and return what it said. At the first or last \
                element VoiceOver stays put and repeats that element. The captured speech is at most \
                64 characters and is usually just the label: traits are captured only sometimes, and \
                values and hints never. Compare labels, and use ui_tree for traits and values.
                """,
            inputSchema: object([
                "direction": .object(["type": "string", "enum": ["next", "previous", "in", "out"],
                                      "description": "next/previous = swipe right/left; in/out = into/out of a container"]),
            ], required: ["direction"])),
        Tool(
            name: "vo_walk",
            description: """
                Return VoiceOver's focus order as a list of what it says at each stop. By default it \
                rewinds to the first element and walks the whole screen; from=current walks on from \
                the focused element instead (its first stop can be stale right after a launch).
                """,
            inputSchema: object([
                "from": .object(["type": "string", "enum": ["start", "current"]]),
                "direction": .object(["type": "string", "enum": ["next", "previous"]]),
                "max": prop("integer", "Maximum moves (default 50)"),
            ])),
        Tool(
            name: "vo_speech",
            description: """
                What VoiceOver last said. With `contains`, waits until VoiceOver says that text, \
                which is how to check where focus went after an action that moves focus \
                programmatically (.screenChanged, .layoutChanged, @AccessibilityFocusState). \
                Errors with speechTimeout and the last thing heard if it never does.
                """,
            inputSchema: object([
                "contains": prop("string", "Text to wait for"),
                "timeout": prop("number", "Seconds to wait (default 3)"),
            ])),
        Tool(
            name: "vo_focus",
            description: "Move VoiceOver focus to an element (a single tap with VoiceOver on) and return what it said.",
            inputSchema: object(["element": element], required: ["element"])),
        Tool(
            name: "vo_activate",
            description: """
                Activate the VoiceOver-focused element, as a VoiceOver double tap does. VoiceOver \
                activates whatever has focus, so call vo_focus on the element first; `element` only \
                says where to double-tap. Without it, the focused element is found by matching \
                VoiceOver's speech to labels. Follow with vo_speech (contains) to see where focus \
                went. Known gap: SwiftUI toggles don't change this way yet.
                """,
            inputSchema: object(["element": element])),
        Tool(
            name: "ui_tree",
            description: """
                The app's UI as an indented outline: type, "label", #identifier, = value, [x,y,w,h]. \
                Unlabeled containers are left out. This is the XCUI tree, not VoiceOver's order; use \
                vo_walk for that.
                """,
            inputSchema: object([:])),
        Tool(
            name: "ui_tap",
            description: """
                Tap or double-tap an element with plain XCUI. With VoiceOver on, a single tap only \
                moves focus and a double tap activates; prefer vo_focus and vo_activate.
                """,
            inputSchema: object([
                "element": element,
                "double": prop("boolean", "Double tap (default false)"),
            ], required: ["element"])),
        Tool(
            name: "ui_type",
            description: "Type text into an element, or into whatever has keyboard focus.",
            inputSchema: object([
                "text": prop("string", "Text to type"),
                "element": element,
            ], required: ["text"])),
    ]

    // MARK: - Calls

    static func call(_ name: String, _ arguments: [String: Value], manager: RunnerManager) async -> CallTool.Result {
        do {
            switch name {
            case "runner_start":
                let state = try await manager.start(
                    wait: TimeInterval(arguments["wait"]?.intValue ?? 45),
                    freshSimulator: arguments["freshSimulator"]?.boolValue ?? true)
                return describe(state, manager: manager)
            case "runner_status":
                return describe(await manager.state(), manager: manager)
            case "runner_stop":
                return text(await manager.stop())
            case "app_install":
                guard let path = arguments["path"]?.stringValue else { return failure("path is required") }
                let output = try await manager.install(appAt: path)
                return output.status == 0 ? text("Installed \(path)") : failure(output.text)
            case "app_launch":
                return try await forward(manager, "POST", "/session", body: arguments)
            case "vo_move":
                let direction = arguments["direction"]?.stringValue ?? ""
                guard ["next", "previous", "in", "out"].contains(direction) else {
                    return failure("direction must be next, previous, in or out")
                }
                return try await forward(manager, "POST", "/vo/\(direction)")
            case "vo_walk":
                return try await forward(manager, "POST", "/vo/walk", body: arguments)
            case "vo_speech":
                var query: [String: String] = [:]
                if let contains = arguments["contains"]?.stringValue { query["contains"] = contains }
                if let timeout = arguments["timeout"].flatMap({ $0.doubleValue ?? $0.intValue.map(Double.init) }) {
                    query["timeout"] = String(timeout)
                }
                return try await forward(manager, "GET", "/vo/current", query: query)
            case "vo_focus":
                return try await forward(manager, "POST", "/vo/focus", body: arguments)
            case "vo_activate":
                return try await forward(manager, "POST", "/vo/activate", body: arguments)
            case "ui_tree":
                let response = try await manager.client.send("GET", "/tree")
                guard response.ok else { return failure(response.text) }
                return text(try TreeFormatter.outline(fromJSON: response.body))
            case "ui_tap":
                let path = arguments["double"]?.boolValue == true ? "/doubleTap" : "/tap"
                var body = arguments
                body["double"] = nil
                return try await forward(manager, "POST", path, body: body)
            case "ui_type":
                return try await forward(manager, "POST", "/type", body: arguments)
            default:
                return failure("Unknown tool \(name)")
            }
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return failure("The runner isn't running. Call runner_start first.")
        } catch {
            return failure(String(describing: error))
        }
    }

    /// Sends a request to the runner and returns its JSON as the tool's text.
    private static func forward(
        _ manager: RunnerManager, _ method: String, _ path: String,
        query: [String: String] = [:], body: [String: Value]? = nil
    ) async throws -> CallTool.Result {
        let data = try body.map { try JSONEncoder().encode(Value.object($0)) }
        let response = try await manager.client.send(method, path, query: query, body: data)
        return response.ok ? text(response.text) : failure(response.text)
    }

    private static func describe(_ state: RunnerManager.State, manager: RunnerManager) -> CallTool.Result {
        switch state {
        case .ready(let owned):
            return text(owned ? "ready" : "ready (attached to a runner started elsewhere)")
        case .starting:
            return text("starting: the runner is still coming up. Call runner_status again shortly.")
        case .stopped:
            return text("stopped")
        case .failed(let logTail):
            return failure("failed: the runner exited before it was ready. End of its log:\n\(logTail)")
        }
    }

    private static func text(_ string: String) -> CallTool.Result {
        .init(content: [.text(string)], isError: false)
    }

    private static func failure(_ string: String) -> CallTool.Result {
        .init(content: [.text(string)], isError: true)
    }
}
