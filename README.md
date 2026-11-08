# VOFocus

<p align="center"><img src="docs/brand/banner-1280x640.png" alt="VOFocus: real VoiceOver focus order, verified by agents and CI" width="720"></p>

Automated verification of **real VoiceOver focus order** on iOS, built for agents and CI.

Checking VoiceOver focus has meant a person swiping through screens on a device. VOFocus
drives VoiceOver itself through `XCUIVoiceOverService` (new in Xcode 27 / iOS 27), so an
agent or CI job can launch a screen, trigger an action and verify where VoiceOver goes,
including focus the app moves itself with `.screenChanged`, `.layoutChanged` or
`@AccessibilityFocusState`.

> **Status: early.** The runner and the MCP server work on the iOS 27 Simulator. A CLI
> and YAML scenarios come next.

## Use it from an agent (MCP)

`vofocus-mcp` is an MCP server (stdio) that starts the runner and exposes it as tools.

```sh
swift build -c release --package-path Host
claude mcp add vofocus --env VOFOCUS_ROOT="$PWD" -- "$PWD/Host/.build/release/vofocus-mcp"
```

| Tool | What it does |
|---|---|
| `runner_start`, `runner_status`, `runner_stop` | Start (or attach to), check and stop the runner |
| `app_install`, `app_launch` | Install a Simulator `.app`; launch an app with VoiceOver on |
| `vo_move`, `vo_walk` | Move VoiceOver one step; get the whole focus order |
| `vo_focus`, `vo_activate` | Move VoiceOver to an element; activate (VoiceOver double tap) |
| `vo_speech` | What VoiceOver said, or wait until it says something (programmatic focus) |
| `ui_tree`, `ui_tap`, `ui_type` | The UI as a compact outline; plain XCUI actions |

A typical check: `runner_start` → `app_launch` (with launch arguments that open the
screen) → `vo_focus` on the trigger → `vo_activate` → `vo_speech` with `contains`.

Settings: `VOFOCUS_ROOT` (the checkout), `VOFOCUS_PORT` (8740), `VOFOCUS_SIMULATOR`
("iPhone 18 Pro") and `DEVELOPER_DIR`. `scripts/mcp_smoke.py` checks the whole flow
end to end.

## Why not the Accessibility Inspector or the accessibility tree?

Both walk the accessibility tree. Neither follows programmatic focus, so they can't show
where VoiceOver lands when a sheet, error or banner appears. That's the part that most
often breaks. VOFocus asks VoiceOver itself.

## Requirements

- Xcode 27.2 or later, with an iOS 27.2 Simulator runtime (27.0 works, with the bugs listed
  below)
- An iOS 27.2 Simulator or device. The Simulator covers most checks; confirm focus checks
  on a device (see below). On a device, turn on **Settings → Developer → Enable UI
  Automation** and keep it unlocked while tests start.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) and jq: `brew install xcodegen jq`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## The runner

The runner is a single long-running UI test, in the style of WebDriverAgent. It serves
HTTP on `localhost:8740` and drives any installed app by bundle ID, so apps need no test
code of their own.

```sh
scripts/runner.sh     # restarts the Simulator, builds, serves until POST /shutdown
scripts/smoke.sh      # in another terminal: checks the runner against the demo app
```

```sh
curl -X POST localhost:8740/session -d '{"bundleId":"com.example.App","arguments":["-VOScenario","uikit-banner"]}'
curl -X POST localhost:8740/vo/focus -d '{"element":{"identifier":"save"}}'
curl -X POST localhost:8740/vo/activate
curl 'localhost:8740/vo/current?contains=Saved%20successfully&timeout=3'
```

| Endpoint | What it does |
|---|---|
| `GET /status` | Runner health, current app, whether VoiceOver is on |
| `POST /session` | Launch or relaunch an app: `bundleId`, `arguments`, `environment`, `voiceOver` (default true) |
| `POST /vo/next`, `/vo/previous`, `/vo/in`, `/vo/out` | Move VoiceOver, like a swipe; returns the speech |
| `POST /vo/walk` | The whole focus order: `{"from":"start"\|"current","direction":"next"\|"previous","max":50}` |
| `GET /vo/current` | VoiceOver's last speech; `?contains=…&timeout=…` waits for it, e.g. after programmatic focus |
| `POST /vo/focus` | Move VoiceOver to an element (a single tap with VoiceOver on) |
| `POST /vo/activate` | Activate the focused element (VoiceOver double tap), or `{"element":…}` |
| `POST /tap`, `/doubleTap`, `/type` | Plain XCUI actions |
| `GET /tree` | The app's UI tree as JSON: type, identifier, label, value, frame |
| `POST /vo/enable`, `/vo/disable` | Toggle VoiceOver (see the caveats below) |
| `POST /shutdown` | Stop the runner |

Elements are found with `{"identifier": …, "label": …, "type": "button", "index": 0, "timeout": 3}`.
Give at least an identifier or a label. Errors come back as `{"error": {"code", "message"}}`.

### How VoiceOver behaves under automation

Found by testing on the iOS 27.0 and 27.2 Simulators and on an iPhone 14 Pro running
iOS 27.2. **Use iOS 27.2 or later:** 27.0 has several bugs in `XCUIVoiceOverService`.

**On every version tested**

- **`currentSpeech()` is the last thing VoiceOver said,** not a description of the focused
  element. Right after `enable()` it can be "VoiceOver on".
- **XCUI can't send a real VoiceOver double tap.** A single `tap()` goes through
  VoiceOver and only moves focus, as a user's tap does. But `doubleTap()` and
  `tap(withNumberOfTaps:)` activate the element under the tap and ignore VoiceOver
  focus. So `/vo/activate` moves VoiceOver focus to the element first and then activates
  it directly. That matches VoiceOver in the common case, but not for elements that
  override `accessibilityActivate()` or `accessibilityActivationPoint`. Without an
  element, it activates the element VoiceOver is on, found by matching speech to labels.
- **VoiceOver occasionally swallows a move,** especially right after it lands in an app.
  `/vo/walk` retries a repeated element once before treating it as the edge of the screen.

**iOS 27.2 (device and Simulator)**

- **The captured speech is complete:** label, trait, value and hint, with no length limit
  ("Notifications Switch button off Double tap to toggle setting."; a 648-character label
  came back whole). A value change captures just the new value ("on"), and returning to
  the element captures the full announcement again, matching what VoiceOver speaks.
- **VoiceOver can be turned off and on again within one runner,** so each session does
  that around the launch and reports where VoiceOver landed.

**iOS 27.0 only (fixed in 27.2)**

- **The captured speech is capped at 64 characters** and is mostly just the label; traits
  are captured inconsistently, and values, hints and value changes not at all.
- **Turning VoiceOver off and on again within one test process breaks it** until the
  Simulator restarts (speech stops; moves fail with "Failed to send navigation command").
  The runner turns it on once, so only the first session reports where VoiceOver landed,
  and `runner.sh` restarts the Simulator first (`FRESH_SIM=0` skips this).

**Simulator vs device (iOS 27.2)**

Programmatic focus is reliable on the iPhone but flaky on the Simulator, where the same
check passes in one run and fails in the next. Treat a Simulator failure of a focus check
as "rerun it", and confirm on a device before filing a bug. A SwiftUI `Toggle` changes
on activation on the device but not on the Simulator.

| Focus API (banner scenario, `-VOFocusAPI`) | iPhone 14 Pro, 27.2 | Simulator, 27.2 |
|---|---|---|
| `UIAccessibility.post(notification: .layoutChanged, argument:)` | ✅ | 2 of 3 runs |
| `UIAccessibility.post(notification: .screenChanged, argument:)` | not yet tested | 1 of 3 runs |
| `AccessibilityNotification.LayoutChanged(_:).post()` | not yet tested | 0 of 3 runs |
| `AccessibilityNotification.ScreenChanged(_:).post()` | not yet tested | 0 of 3 runs |
| `AccessibilityNotification.Announcement(_:).post()` (spoken, no focus move) | not yet tested | 2 of 2 runs |
| SwiftUI `@AccessibilityFocusState` | ✅ | 1 of 2 runs |

## Run the spike

```sh
scripts/spike.sh                       # iOS 27 Simulator (iPhone 18 Pro by default)
SIM_NAME="iPhone 17" scripts/spike.sh  # another Simulator
scripts/spike.sh --device <UDID>       # physical device (name works too; UDID avoids quoting)
```

Scripts use the Xcode that `xcode-select` points to unless `DEVELOPER_DIR` is set, and
the newest iOS 27 runtime that has a Simulator named `SIM_NAME`. For a physical
device, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your team.

Each VoiceOver utterance is printed with a `VOSPIKE` prefix. The full log is in
`build/spike.log`, and the result bundle is in `build/`.

## The demo app

Launch with `-VOScenario <name>` to open one scenario with no navigation around it.

| Scenario | What it checks |
|---|---|
| `static` | Heading and three buttons, a known baseline order |
| `counter` | Whether an XCUI `tap()` activates a control while VoiceOver is on |
| `uikit-banner` | Save posts `.layoutChanged` to a banner at the bottom |
| `swiftui-error` | Submit moves focus to an error with `@AccessibilityFocusState` |

The app also logs every VoiceOver focus change to `os.log` (subsystem
`dev.vofocus.DemoApp`, category `focus`) for cross-checking in Console.app.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
