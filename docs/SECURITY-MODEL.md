# Security model

What VOFocus runs, what it can reach, what it records, and the permissions it needs.
It's written for a security review before using VOFocus in a company. To report a
vulnerability, see [SECURITY.md](../SECURITY.md).

## In short

- Everything runs on the developer's Mac and their own Simulator or device. VOFocus
  sends nothing anywhere else: no telemetry, no analytics, no update checks, no
  cloud services. The network traffic it causes is Apple's and the build's own:
  - **Xcode signing:** building for a device lets Xcode reach Apple's developer
    services (`-allowProvisioningUpdates`) to create or refresh signing profiles.
  - **Swift Package Manager:** the first build fetches Yams from GitHub.
  - **Speech model:** the first transcription downloads Apple's speech model.
- The only network listener is the runner, on port 8740. On the Simulator it listens
  on the Mac's loopback address only. On a device it listens only on the CoreDevice
  tunnel address, the encrypted link Xcode keeps with a paired device. Every request
  also needs a random per-run token.
- Building needs one third-party library, [Yams](https://github.com/jpsim/Yams) (YAML
  parsing), pinned to one commit.
- Recording audio is experimental and opt-in. Recordings stay on the Mac and are
  transcribed on the Mac.

## Parts

| Part | Runs on | What it is |
| --- | --- | --- |
| Runner (`Runner/`) | The Simulator or device | An XCUITest app that serves HTTP and turns requests into XCUI and VoiceOver calls |
| `vofocus` CLI (`Host/`) | The Mac | Runs YAML scenarios against the runner |
| `vofocus-mcp` (`Host/`) | The Mac | An MCP server for coding agents, over standard input and output only (it opens no port) |
| Scripts (`scripts/`) | The Mac | Build and start the runner with `xcodebuild` |

There's a diagram in [ARCHITECTURE.md](ARCHITECTURE.md).

## The runner's HTTP server

The runner is the one part that accepts connections, so it carries most of the
security design.

- **Who can connect.**
  - **On the Simulator:** it binds to `127.0.0.1`. The Simulator shares the Mac's
    network, so without this the runner would be reachable from the local network.
  - **On a device:** it binds to the device's CoreDevice tunnel address
    (`devicectl device info details` → `tunnelIPAddress`), which `scripts/runner.sh`
    passes to it. Other devices on the same Wi-Fi can't connect.
  - **Started by hand** without that address: it listens on every interface, prints a
    warning, and only the token protects it.
- **Authentication.**
  - **The token:** every request needs `Authorization: Bearer <token>`. Requests
    without it get `401` and never reach XCUI.
  - **Each run makes a new token:** `openssl rand -hex 32` (256 bits), saved in
    `runner-<port>.token` in the build folder with mode `0600`.
  - **Delivery to the runner:** the token goes in through the test process
    environment.
  - **Never logged:** it isn't printed or written to any log.
  - **Comparison:** it's compared in constant time.
- **Transport.**
  - **Plain HTTP:** the server speaks it, but only inside the loopback interface or
    the CoreDevice tunnel.
  - **Encryption:** the tunnel is encrypted by Apple's CoreDevice, whether it runs over
    the cable or Wi-Fi. VOFocus only ever connects to the tunnel address.
- **Limits.**
  - **Request size:** at most 1 MB per request.
  - **Order:** requests are handled one at a time on the main thread.
- **What a client can do:** with the token, it can do what a UI test can.
  - Launch installed apps by bundle ID.
  - Tap, type, swipe and read the accessibility tree of the app under test.
  - Turn VoiceOver on and off.
  - Read what VoiceOver says.
  - **Scope:** this is XCUITest's normal reach on a device in developer mode with
    UI Automation enabled. It isn't more than that.
- **Lifetime:** the runner stops on `POST /shutdown`, when the CLI finishes (unless
  `--keep-runner`), when the MCP server exits, or when the test process is stopped.

## Commands VOFocus runs on the Mac

- **Fixed tools:** the CLI and MCP server run only `xcrun` (`simctl`, `devicectl`),
  `xcodebuild`, `scripts/runner.sh` and `plutil`.
- **No shell:** arguments are passed as an argument list, never through a shell.
- **Scenario values:** a scenario's values (an app path to install, launch arguments,
  `${VARIABLE}` from the environment) become arguments or request fields. They're
  never run as commands.
- **No downloads:** nothing is downloaded or executed at run time.
  - **One exception:** the first transcription downloads Apple's on-device speech
    model through Apple's own `AssetInventory` API.
- **No `sudo`:** none of the scripts use it.
- **`runner.sh`:**
  - **Token delivery:** it passes the token to the runner in the test process's
    environment (`TEST_RUNNER_VOFOCUS_TOKEN`). Processes running as the same user
    can read it there, as they can read the token file.
  - **Simulator restart:** it restarts the Simulator before each start, which
    `FRESH_SIM=0` skips.
- **`brand-runner.sh`:**
  - **What it does:** it gives the runner app its icon and name, then re-signs it with
    the certificate Xcode just signed it with.
  - **Entitlements:** it keeps the app's entitlements and adds none.
  - **If it fails:** the app stays as Xcode built it.
  - **Skipping it:** set `VOFOCUS_BRAND=0` and the app Xcode built isn't touched (it
    shows a blank icon).

## Data

| Data | Where | Kept |
| --- | --- | --- |
| Runner token | `build/runner-<port>.token` (checkout) or `~/Library/Caches/vofocus` (installed), mode `0600` | Replaced each run |
| Runner log (requests: method, path, status, time) | Same build folder | Previous run kept |
| Scenario results, JUnit | Printed, or the file you name | Until you delete it |
| Audio recordings (WAV) and timelines (JSON), only with `--audio` or `audio_start` | The folder you name, or `<build>/audio/` for the MCP server | Until you delete them |

Request bodies (text typed into the app, element labels) aren't logged. Scenario
results include what VoiceOver said, which is the app's on-screen text.

## Permissions

| Permission | Needed for | Granted to |
| --- | --- | --- |
| Settings → Developer → **Enable UI Automation** (device) | Running the XCUITest runner on a device | The device |
| A development team that can sign apps (device) | Installing the runner on a device | `vofocus setup` saves the team ID to `~/.config/vofocus/signing.xcconfig` |
| **System audio recording** (macOS) | Audio on the Simulator: recording VoiceOver's two Simulator processes, never the microphone | The app that runs VOFocus (such as Terminal) |
| **Camera** (macOS) | Audio on a device: macOS lists a USB-connected iPhone's audio under camera access. No camera is opened, and macOS shows the camera indicator while recording | The app that runs VOFocus |

The runner app's Info.plist comes from Xcode's XCTRunner template, which every UI test
runner uses. It lists about 50 privacy usage descriptions ("Access is necessary for
automated testing.") and `NSAllowsArbitraryLoads`. They let any UI test reach those
features if a test asks; VOFocus's runner doesn't ask for any of them.

The microphone permission isn't needed and isn't requested. Without audio, VOFocus
needs neither macOS permission. On a device, recording audio captures everything the
phone plays and silences its speaker, so VOFocus asks you to turn on Do Not Disturb.
See [AUDIO.md](AUDIO.md#privacy).

## Supply chain

- **Dependencies:** Yams 5.4.0, pinned by commit in `Host/Package.resolved`. There
  are no other third-party packages; the JSON-RPC (MCP) layer and the option parsing
  are written in this repository.
- **Build tools:** Xcode 27 and XcodeGen, which generates the Xcode project.
- **Install:** the Homebrew formula builds from a tagged source archive checked by
  SHA-256 ([RELEASING.md](RELEASING.md)).
- **CI:** the workflow's actions are pinned to commit SHAs, and its token can only
  read the repository. Dependabot proposes updates.

## Using it at a company

The smallest setup to start with:

- **Simulator only:** no device signing, no device permissions, and the runner on
  loopback only.
- **Audio off:** it's opt-in. Without it, VOFocus needs no macOS privacy permission.
- **CLI or MCP server, built from source:** a reviewed commit, or installed with
  Homebrew from a tagged release.

Things to know:

- **Agent control:** an agent with the MCP server can drive the Simulator or device
  like a UI test can. Give agents the same trust you'd give a UI test suite.
- **CI artifacts:** they can include VoiceOver's speech (the app's on-screen text)
  and, with audio on, recordings. Treat them like screenshots of the app.
