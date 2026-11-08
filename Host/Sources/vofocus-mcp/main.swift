import Foundation
import MCP
import VOFocusKit

// vofocus-mcp: an MCP server (stdio) that lets agents drive real VoiceOver through
// the VOFocus runner.
//
// Environment:
//   VOFOCUS_ROOT       the VOFocus checkout (found automatically when run from inside it)
//   VOFOCUS_PORT       runner port (default 8740)
//   VOFOCUS_SIMULATOR  iOS 27 Simulator name (default "iPhone 18 Pro", newest iOS 27 runtime)
//   DEVELOPER_DIR      Xcode to use (default: xcode-select)
//
// stdout carries the MCP protocol, so anything else goes to stderr.

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
    simulator: environment["VOFOCUS_SIMULATOR"] ?? "iPhone 18 Pro"))

let server = Server(
    name: "vofocus",
    version: "0.1.0",
    capabilities: .init(tools: .init(listChanged: false)))

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: ToolCatalog.tools)
}
await server.withMethodHandler(CallTool.self) { params in
    await ToolCatalog.call(params.name, params.arguments ?? [:], manager: manager)
}

log("serving (project: \(root.path))")
try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
await manager.shutdownIfOwned()
