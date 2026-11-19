# VOFocus

<p align="center"><img src="docs/brand/banner-1280x640.png" alt="VOFocus: real VoiceOver focus order, verified by agents and CI" width="720"></p>

Automated verification of **real VoiceOver focus order** on iOS, built for agents and CI.

Checking VoiceOver focus has meant a person swiping through screens on a device. VOFocus
drives VoiceOver itself through `XCUIVoiceOverService` (new in Xcode 27 / iOS 27), so an
agent or CI job can launch a screen, trigger an action and verify where VoiceOver goes,
including focus the app moves itself with `.screenChanged`, `.layoutChanged` or
`@AccessibilityFocusState`. It can also change adjustable controls the way a VoiceOver
user does, and (experimental) record what VoiceOver actually says and plays.

**How it works:** a test runner on the iPhone or Simulator drives real VoiceOver, and the
CLI or MCP server on your Mac sends it commands. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the diagram.

> **Status: early.** The runner, the MCP server and the `vofocus` CLI work on the iOS 27.2
> Simulator and on devices. Recording VoiceOver's audio is experimental and opt-in.

### Why not the Accessibility Inspector or the accessibility tree?

Both walk the accessibility tree. Neither follows programmatic focus, so they can't show
where VoiceOver lands when a sheet, error or banner appears. That's the part that most
often breaks. VOFocus asks VoiceOver itself.

## Requirements

- macOS with Xcode 27.2 or later and an iOS 27.2 Simulator runtime (27.0 works, with the
  bugs [listed below](#ios-270-only-fixed-in-272)). CI jobs need macOS runners.
- An iOS 27.2 Simulator or device. **iOS 27 or later is required**:
  `XCUIVoiceOverService` doesn't exist on earlier versions. The Simulator covers most
  checks; confirm focus checks on a device ([why](#simulator-vs-device-ios-272)). On a
  device, turn on **Settings → Developer → Enable UI Automation** and keep it unlocked
  while tests start.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), to work in
  a checkout or install from one. An installed VOFocus doesn't need it.

## Install

```sh
git clone https://github.com/marybm-dev/vofocus.git && cd vofocus
scripts/install.sh ~/.local      # vofocus and vofocus-mcp in ~/.local/bin
```

`install.sh` builds both tools and copies the runner's files to
`<prefix>/share/vofocus`. An installed VOFocus builds the runner the first time it starts
(a few minutes), into `~/Library/Caches/vofocus`. Everything below also works straight
from the checkout, using `Host/.build/release/` and `build/` instead.

For physical devices, save the Apple developer team that signs the runner once (the
Simulator needs nothing):

```sh
vofocus setup --team <your team ID>   # Xcode > Settings > Accounts shows it
vofocus setup                         # shows the current settings and folders
```

## Run checks unattended (CLI)

Write a check as a YAML scenario ([format](scenarios/README.md)), then run it from a
script or CI. No agent or person needed:

```sh
vofocus run scenarios/ --junit report.xml              # Simulator
vofocus run scenarios/ --device <UDID>                 # a device
vofocus record scenarios/new-check.yml --write         # fill in expectations
```

```
FAIL  Static screen reads heading, then One, Two, Three (static-order.yml, 28 s)
    ✓ landing: Static Order Heading
    ✗ walk
        focus order differs (expected 4 stops, VoiceOver made 4):
            1. expected "Static Order Heading", heard "Static Order Heading"
            2. expected "One Button", heard "One Button"
          ✗ 3. expected "Three Button", heard "Two Button"
          ✗ 4. expected "Two Button", heard "Three Button"
```

It starts and stops the runner itself (`--keep-runner` leaves it up between runs), exits
1 if any scenario fails, and writes JUnit XML with `--junit`. Simulator runs are fully
unattended; device runs need the device connected, unlocked and with UI Automation
enabled.

Scenarios can move focus, activate, wait for speech after programmatic focus, and swipe
up or down to change adjustable controls (`swipe: {direction: up, expect: "3"}`). See
[scenarios/README.md](scenarios/README.md) for every step.

### In CI

`.github/workflows/voiceover-checks.yml` runs the demo scenarios on a GitHub-hosted
runner's Simulator and uploads the JUnit report. It uses GitHub's `xcode-27` image
(`macos-latest` only has Xcode 26); a run there with Xcode 27.2 and an iOS 27.2
Simulator took about 6 minutes, most of it building and starting the runner.

It only runs when started by hand; uncomment `pull_request` to run it on every pull
request. On private repositories, macOS runner minutes count against your plan at a
higher rate than Linux, so check GitHub's current pricing first. Any CI works the same
way on a macOS machine with Xcode 27.2: install XcodeGen, build your app, and run
`vofocus run`. No signing team is needed for the Simulator.

## Use it from an agent (MCP)

`vofocus-mcp` is an MCP server (stdio) that starts the runner and exposes it as tools.
It implements MCP's JSON-RPC directly, with no MCP library.

```sh
claude mcp add vofocus -- ~/.local/bin/vofocus-mcp                 # installed
claude mcp add vofocus --env VOFOCUS_ROOT="$PWD" -- "$PWD/Host/.build/release/vofocus-mcp"   # from a checkout
```

| Tool | What it does |
|---|---|
| `runner_start`, `runner_status`, `runner_stop` | Start (or attach to), check and stop the runner; stopping turns VoiceOver off |
| `app_install`, `app_launch` | Install a Simulator `.app`; launch an app with VoiceOver on |
| `vo_move`, `vo_walk` | Move VoiceOver one step; get the whole focus order |
| `vo_focus`, `vo_activate` | Move VoiceOver to an element; activate (VoiceOver double tap) |
| `vo_swipe` | VoiceOver's swipe up or down: adjust a slider or other adjustable control, or read the next custom action |
| `vo_speech` | What VoiceOver said, or wait until it says something (programmatic focus) |
| `ui_tree`, `ui_tap`, `ui_type` | The UI as a compact outline; plain XCUI actions |
| `audio_start`, `audio_report` | Experimental: hear what VoiceOver actually said and played after each call ([below](#hear-what-voiceover-says-experimental)) |

A typical check: `runner_start` → `app_launch` (with launch arguments that open the
screen) → `vo_focus` on the trigger → `vo_activate` → `vo_speech` with `contains` →
`runner_stop`.

**Cleaning up:** stopping the runner turns VoiceOver off and closes the runner app, so
nobody picks up their phone to find VoiceOver on. The server tells agents when they
connect (MCP `instructions`) to call `runner_stop` when they're done, and it stops a
runner it started itself when the session ends, whether the client closes the
connection or sends SIGTERM, SIGINT or SIGHUP. It leaves alone a runner it attached to
but didn't start, such as one you started with `scripts/runner.sh`.

**Settings** (environment): `VOFOCUS_ROOT` (a checkout to use; not needed when
installed), `VOFOCUS_BUILD_DIR` (where the runner is built and its logs and tokens go),
`VOFOCUS_PORT` (8740), `VOFOCUS_SIMULATOR` ("iPhone 18 Pro"), `VOFOCUS_DEVICE` and
`DEVELOPER_DIR`.

**On a device:** set `VOFOCUS_DEVICE` to a connected device's UDID (from
`xcrun devicectl list devices`) or name. The runner then builds for and runs on that
device, and the server reaches it over the cable's CoreDevice tunnel, with no port
forwarding. The device needs Settings → Developer → Enable UI Automation, and must be
unlocked when the runner starts. To keep both targets available, register a second
server on another port:

```sh
claude mcp add vofocus-device --env VOFOCUS_DEVICE=<UDID> --env VOFOCUS_PORT=8741 \
  -- ~/.local/bin/vofocus-mcp
```

`scripts/mcp_smoke.py` checks the whole flow end to end, on the Simulator or (with
`VOFOCUS_DEVICE`) a device.

## Hear what VoiceOver says (experimental)

The speech the runner reports is what VoiceOver *meant* to say. Opt in to recording, and
VOFocus reports what was actually heard at each step: speech that was cut off or never
audible, and VoiceOver's sounds (the boundary "bonk", focus moves, screen changes),
which the text doesn't include.

```sh
vofocus run scenarios/ --audio audio/        # CLI: per-step report, WAV files, JSON timeline
```

```
✓ next: Notifications Switch button off Double tap to toggle setting.
✓ next: Share Button Shares this page
  next: heard "Notification,", cut off (1 of 9 words); sounds: focus moved
  next: heard nothing; sounds: focus moved
```

Agents use `audio_start`, then any tools, then `audio_report`. Nothing is recorded from
a microphone, and speech is transcribed on the Mac.

- **Simulator:** records only VoiceOver's two processes on that Simulator. macOS asks
  once for permission to record system audio.
- **Device (USB):** records everything the phone plays, the way QuickTime does, so turn
  on Do Not Disturb. The phone's speaker is silent while recording. macOS asks once for
  camera access, which it requires to capture an iPhone (the Mac's camera isn't used),
  and shows the green camera indicator while recording.

See [docs/AUDIO.md](docs/AUDIO.md) for how it works, what it saves and its limits.

## The runner

The runner is a single long-running UI test, in the style of WebDriverAgent. It serves
HTTP on port 8740 and drives any installed app by bundle ID, so apps need no test code of
their own. On a Simulator it's at `localhost:8740`; on a device, at the device's
CoreDevice tunnel address (`http://[<tunnelIPAddress>]:8740`, from
`xcrun devicectl device info details --device <UDID>`).

```sh
scripts/runner.sh                    # restarts the Simulator, builds, serves until POST /shutdown
scripts/runner.sh --device <UDID>    # on a connected device; prints the address to use
```

`POST /shutdown` ends the test, which turns VoiceOver off and closes the runner app. On
the Home Screen the runner app is "VOFocus Runner" with its own icon. It's Xcode's
generic test runner app, which has no setting for either, so `scripts/brand-runner.sh`
adds them after each build and re-signs the app (the icon's source is
`Icons/runner.svg`).

Anyone who can reach the runner can tap, type and read the screen, so it only answers
requests that carry its token. `runner.sh` makes a new one on every start and saves it
to `runner-<port>.token` in the build folder (`build/` in a checkout,
`~/Library/Caches/vofocus` when installed), readable only by you; other requests get
401. On the Simulator the runner also listens on `127.0.0.1` only, so other machines on
your network can't connect. On a device the host's traffic goes over the USB cable's
tunnel, and the token covers any other route to the phone. The CLI and the MCP server
read the token for you; with `curl`:

```sh
AUTH="Authorization: Bearer $(cat build/runner-8740.token)"
curl -H "$AUTH" -X POST localhost:8740/session -d '{"bundleId":"com.example.App","arguments":["-VOScenario","uikit-banner"]}'
curl -H "$AUTH" -X POST localhost:8740/vo/focus -d '{"element":{"identifier":"save"}}'
curl -H "$AUTH" -X POST localhost:8740/vo/activate
curl -H "$AUTH" 'localhost:8740/vo/current?contains=Saved%20successfully&timeout=3'
```

| Endpoint | What it does |
|---|---|
| `GET /status` | Runner health, current app, whether VoiceOver is on |
| `POST /session` | Launch or relaunch an app: `bundleId`, `arguments`, `environment`, `voiceOver` (default true). If VoiceOver doesn't announce the app, the session still starts and `note` says the landing is unknown |
| `POST /vo/next`, `/vo/previous`, `/vo/in`, `/vo/out` | Move VoiceOver, like a swipe; returns the speech |
| `POST /vo/walk` | The whole focus order: `{"from":"start"\|"current","direction":"next"\|"previous","max":50}` |
| `GET /vo/current` | VoiceOver's last speech; `?contains=…&timeout=…` waits for it, e.g. after programmatic focus |
| `POST /vo/focus` | Move VoiceOver to an element (a single tap with VoiceOver on) |
| `POST /vo/activate` | Activate the focused element (VoiceOver double tap), or `{"element":…}` |
| `POST /swipe` | `{"direction":"up"\|"down","element":…}`: VoiceOver's swipe up or down, made across the screen. Returns what VoiceOver said and the element's value |
| `POST /tap`, `/doubleTap`, `/type` | Plain XCUI actions. With VoiceOver on, a tap only moves focus, and the response's `note` says so; use `/vo/activate` to activate |
| `GET /tree` | The app's UI tree as JSON: type, identifier, label, value, frame |
| `POST /vo/enable`, `/vo/disable` | Toggle VoiceOver (see the caveats below) |
| `POST /shutdown` | Stop the runner |

Elements are found with `{"identifier": …, "label": …, "type": "button", "index": 0, "timeout": 3}`.
Give at least an identifier or a label. Errors come back as `{"error": {"code", "message"}}`.

### How VoiceOver behaves under automation

Found by testing on the iOS 27.0 and 27.2 Simulators and on an iPhone 14 Pro running
iOS 27.2. **Use iOS 27.2 or later:** 27.0 has several bugs in `XCUIVoiceOverService`.

#### On every version tested

- **`currentSpeech()` is the last thing VoiceOver said,** not a description of the
  focused element. Right after `enable()` it can be "VoiceOver on".
- **XCUI can't send a real VoiceOver double tap.** A single `tap()` goes through
  VoiceOver and only moves focus, as a user's tap does. But `doubleTap()` and
  `tap(withNumberOfTaps:)` activate the element under the tap and ignore VoiceOver
  focus, even on empty space, where VoiceOver would activate the focused element. So
  `/vo/activate` moves VoiceOver focus to the element first and then activates it
  directly. That matches VoiceOver in the common case, but not for elements that
  override `accessibilityActivate()` or `accessibilityActivationPoint`. Without an
  element, it activates the element VoiceOver is on, found by matching speech to labels.
- **Adjustable controls work through synthesized swipes.** `XCUIVoiceOverService` has
  no increment or decrement, but VoiceOver interprets an XCUI swipe up or down as its
  own gesture, on the Simulator and on devices. `/swipe` focuses the element, then
  swipes across the screen: a swipe within a small element is too short for VoiceOver
  to read as one. VoiceOver says the new value ("3", "60%").
- **Custom actions can be listed but not run.** `XCUIVoiceOverService` has no activate,
  rotor or custom-actions API, and XCUI's double taps bypass VoiceOver. So VOFocus can't
  trigger named actions (the Actions rotor, `.accessibilityAction(named:)`,
  `accessibilityCustomActions`) or an element's own VoiceOver activation
  (`accessibilityActivate()`, SwiftUI's unnamed `.accessibilityAction { }`). For a
  standard button, activating directly has the same effect; for these it runs different
  code. What it **can** check:
  - that the actions exist: on iOS 27.2 VoiceOver's speech ends with "Actions available"
    for an element that has them ("Done Button Actions available"), so
    `focus: {…, expect: Actions available}` catches actions that disappear. On a device
    this needs Settings → Accessibility → VoiceOver → Verbosity → Actions set to
    **Speak** (with nothing selected there, VoiceOver stays silent about actions).
  - their names: a swipe down reads each action (`swipe: {direction: down, expect:
    Undo}`), as a user flicking through them hears.

  Check what they do by hand, on a device.
- **VoiceOver occasionally swallows a move,** especially right after it lands in an app.
  `/vo/walk` retries a repeated element once before treating it as the edge of the
  screen.

#### iOS 27.2 (device and Simulator)

- **The captured speech is complete:** label, trait, value and hint, with no length limit
  ("Notifications Switch button off Double tap to toggle setting."; a 648-character label
  came back whole). A value change captures just the new value ("on"), and returning to
  the element captures the full announcement again, matching what VoiceOver speaks.
- **VoiceOver can be turned off and on again within one runner,** so each session does
  that around the launch and reports where VoiceOver landed.

#### iOS 27.0 only (fixed in 27.2)

- **The captured speech is capped at 64 characters** and is mostly just the label; traits
  are captured inconsistently, and values, hints and value changes not at all.
- **Turning VoiceOver off and on again within one test process breaks it** until the
  Simulator restarts (speech stops; moves fail with "Failed to send navigation command").
  The runner turns it on once, so only the first session reports where VoiceOver landed,
  and `runner.sh` restarts the Simulator first (`FRESH_SIM=0` skips this).

#### Simulator vs device (iOS 27.2)

On the iPhone every focus API moved focus instantly. On the Simulator the same checks
pass in one run and fail in the next, and `AccessibilityNotification`'s focus
notifications never moved focus at all. The Simulator also missed a real bug the device
caught: an announcement posted while VoiceOver activates a button gets cut off by
VoiceOver's own speech for the button (confirmed by listening on the device: only the
delayed announcement was heard). **Use the Simulator for order and speech checks;
confirm focus and announcement checks on a device.** A SwiftUI `Toggle` also changes on
activation on the device but not on the Simulator.

| API (banner scenario, `-VOFocusAPI`) | iPhone 14 Pro, 27.2 | Simulator, 27.2 |
|---|---|---|
| `UIAccessibility.post(notification: .layoutChanged, argument:)` | ✅ | 2 of 3 runs |
| `UIAccessibility.post(notification: .screenChanged, argument:)` | ✅ | 1 of 3 runs |
| `AccessibilityNotification.LayoutChanged(_:).post()` | ✅ | 0 of 3 runs |
| `AccessibilityNotification.ScreenChanged(_:).post()` | ✅ | 0 of 3 runs |
| SwiftUI `@AccessibilityFocusState` | ✅ | 1 of 2 runs |
| `AccessibilityNotification.Announcement` posted in the button's action | ❌ cut off by "Save" (not heard) | ✅ heard in full (misses the bug) |
| The same announcement posted 0.5 s later (`announcement-delayed`) | ✅ heard | ✅ heard |

On the Simulator, "heard" was checked by recording ([above](#hear-what-voiceover-says-experimental)).

## The demo app

`DemoApp/` has one screen per behavior worth checking; `scenarios/demo/` has the
scenarios that check them (`scripts/demo.sh run scenarios/demo` builds the app and runs
them). Launch it with `-VOScenario <name>` to open one screen with no navigation around
it, which keeps the focus order deterministic. Its icon is the VOFocus logo
(`Icons/demo.svg`, on a square tile for iOS to round).

| Screen | What it checks |
|---|---|
| `static` | Heading and three buttons, a known baseline order |
| `counter` | Whether an XCUI `tap()` activates a control while VoiceOver is on |
| `uikit-banner` | Save shows a banner and notifies VoiceOver with the API from `-VOFocusAPI` |
| `swiftui-error` | Submit moves focus to an error with `@AccessibilityFocusState` |
| `traits` | A toggle, a hint, long labels and a custom action: what speech capture includes |
| `long-list` | An off-screen row whose combined label has commas, which VoiceOver speaks with extra spaces |
| `adjustable` | A custom adjustable control and a slider, changed with VoiceOver's swipe up and down |

The app also logs every VoiceOver focus change to `os.log` (subsystem
`dev.vofocus.DemoApp`, category `focus`) for cross-checking in Console.app.

## The spike

The first experiment, kept for checking `XCUIVoiceOverService` on new iOS versions:

```sh
scripts/spike.sh                       # iOS 27 Simulator (iPhone 18 Pro by default)
SIM_NAME="iPhone 17" scripts/spike.sh  # another Simulator
scripts/spike.sh --device <UDID>       # physical device (name works too; UDID avoids quoting)
```

Scripts use the Xcode that `xcode-select` points to unless `DEVELOPER_DIR` is set, and
the newest iOS 27 runtime that has a Simulator named `SIM_NAME`. For a physical device,
copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your team, or run
`vofocus setup --team <ID>`.

Each VoiceOver utterance is printed with a `VOSPIKE` prefix. The full log is in
`build/spike.log`, and the result bundle is in `build/`.

## Dependencies

Nothing from VOFocus goes into the app under test: the runner is a separate UI-test
bundle that uses only XCTest, Network and Synchronization. The Mac-side tools in `Host/`
have one dependency, [Yams](https://github.com/jpsim/Yams) (MIT, includes LibYAML), for
parsing scenarios. The MCP server doesn't use it. Recording audio uses only Apple's
frameworks (Core Audio, AVFoundation, Speech).

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
