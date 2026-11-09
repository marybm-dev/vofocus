# How VOFocus works

An agent or CI job on your Mac asks for a VoiceOver gesture. A test runner on the iPhone
or Simulator performs it with real VoiceOver and replies with what VoiceOver said.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="architecture-dark.svg">
  <img src="architecture-light.svg" width="960" alt="On your Mac, an AI agent talks to the vofocus-mcp server and you or CI use the vofocus CLI; both use VOFocusKit. Its RunnerManager starts the runner once through xcodebuild test, and its RunnerClient sends HTTP commands such as POST /vo/next to VOFocusRunner on the iPhone or Simulator, which replies with what VoiceOver said, such as Save Button. The runner uses XCUIVoiceOverService to drive the real VoiceOver, which reads your unchanged app's accessibility tree.">
</picture>

Blue is the Mac side and green is the device side. The heavy outline around Save is
VoiceOver's focus. The dashed line happens once, when a session starts. Every command
after that is one HTTP request and its reply: to `localhost:8740` on a Simulator, or over the USB cable's
CoreDevice tunnel on a device.

## Two servers, two jobs

Both parts listen for requests, but they serve different callers.

| | `vofocus-mcp` | `VOFocusRunner` |
|---|---|---|
| Runs on | your Mac | the iPhone or Simulator |
| Listens to | the agent, over stdin/stdout (JSON-RPC) | HTTP on port 8740 |
| Started by | the MCP client, from its config | `xcodebuild test` (about 20 s the first time) |
| Job | turns tool calls into HTTP requests, and replies into text | runs each command with XCUITest and real VoiceOver |
| Touches VoiceOver | never | on every command |

The CLI takes the MCP server's place when there's no agent. It reads YAML scenarios,
sends the same commands through the same `VOFocusKit`, and compares what VoiceOver said
with what each scenario expects. Nobody needs to watch it, so it runs unattended in CI.

## Why a runner

XCUITest code, including `XCUIVoiceOverService`, only runs inside a UI-test process on
the iPhone or Simulator, and Apple offers no way to call it from outside. Normally that
means writing and compiling a test for every check.

VOFocus has a single generic test instead: it starts, opens a small HTTP server and
loops, waiting for a command, running it and replying. Appium's WebDriverAgent works the
same way. Agents and scenarios then send commands at runtime, with nothing to recompile,
and the app under test needs no test code or SDK. The runner finds it by bundle ID.

## One command, start to finish

An agent asks to swipe right once:

1. **Agent → vofocus-mcp:** the agent calls `vo_move` with `{"direction": "next"}`.
2. **vofocus-mcp → runner:** `RunnerClient` sends `POST /vo/next` to the runner.
3. **Runner → VoiceOver:** the runner calls `XCUIVoiceOverService.moveForward()`, the
   same as a one-finger swipe right, performed by the real VoiceOver.
4. **VoiceOver → your app:** VoiceOver moves to the next element in the app's
   accessibility tree and speaks it, as it would for a person.
5. **Runner:** the runner reads what VoiceOver said from `currentSpeech` and replies
   `{"utterance": "Save Button"}`.
6. **vofocus-mcp → agent:** the agent gets "Save Button" back and decides what to do
   next.

Because this is real VoiceOver, it follows focus the app moves itself (`.screenChanged`,
`.layoutChanged`, `@AccessibilityFocusState`) and speaks announcements. The Accessibility
Inspector only walks the accessibility tree, so it can't show either.

## Where the code lives

| Path | What it is |
|---|---|
| `Runner/` | `VOFocusRunner`: the UI test, its HTTP server and the command handlers |
| `Host/Sources/VOFocusKit/` | `RunnerManager` and `RunnerClient`, shared by the CLI and the MCP server |
| `Host/Sources/VOFocusScenarios/` | YAML scenario parsing, running and recording |
| `Host/Sources/vofocus/` | the CLI |
| `Host/Sources/vofocus-mcp/` | the MCP server (hand-written JSON-RPC over stdio) |
| `scripts/runner.sh` | builds and starts the runner on a Simulator or device |

## Limits

- **Custom actions** from the Actions rotor, and an element's own VoiceOver activation
  (`accessibilityActivate()`), can't be triggered: Apple's API has no way to. VOFocus
  can check that VoiceOver says "Actions available".
- **No audio.** VOFocus reads VoiceOver's speech as text, so it can't tell whether an
  announcement was audible over other sound.
- **macOS only.** The runner needs Xcode, so CI needs macOS runners.

For the details of how VoiceOver behaves under automation, see
[The runner](../README.md#the-runner) in the README.
