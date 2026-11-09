# Scenarios

A scenario is a YAML file describing one VoiceOver check: launch an app, take some
steps, and compare what VoiceOver says with what you expect. `vofocus run` runs them
unattended and exits 1 if any fail, so they work as CI checks.

```yaml
name: Saving moves VoiceOver focus to the confirmation banner
app:
  bundleId: com.example.App            # ${NAME} is replaced with environment variable NAME
  install: build/App.app                # optional; relative to this file
  arguments: [-Screen, edit-profile]    # launch arguments that open the screen under test
  environment: {MOCK_API: "1"}          # optional launch environment
retries: 2                              # optional; rerun after a failure (the Simulator is flaky)
deviceOnly: false                       # optional; true skips it on the Simulator
steps:
  - landing: Edit Profile Heading       # where VoiceOver landed at launch
  - walk: [Edit Profile Heading, Save Button, Cancel Button]   # the whole focus order
  - focus: {identifier: save, expect: Save Button}             # move focus to an element
  - activate:                           # activate the focused element (VoiceOver double tap)
  - speech: Saved successfully          # wait (3 s) until VoiceOver says this
```

## Steps

| Step | What it does | Expectation |
|---|---|---|
| `landing: <text>` | Checks where VoiceOver landed when the app launched | the landing, without the app name |
| `walk: [<text>, …]` | Walks the whole screen from the first element | one entry per stop, same count |
| `next: <text>` / `previous: <text>` | One swipe right or left | what VoiceOver said |
| `current: <text>` | What VoiceOver last said, without moving focus: where focus is after an action | what VoiceOver said |
| `focus: {<element>, expect: <text>}` | Moves VoiceOver focus to an element | what VoiceOver said (optional) |
| `activate:` or `activate: {<element>}` | Activates the focused element, or moves focus to the given one first | none |
| `speech: <text>` or `speech: {expect: <text>, timeout: 5}` | Waits until VoiceOver says it (default 3 s): use after anything that moves focus or announces | required |
| `tap: {<element>, double: true}` | A plain tap (with VoiceOver on, a single tap only moves focus) | none |
| `type: {text: <text>, <element>}` | Types into an element, or whatever has keyboard focus | none |
| `wait: <seconds>` | Pauses | none |

A `walk` also fails, whatever it expects, if focus **loops** (swiping on returns to an
earlier element instead of stopping at the end) or never ends:

```
✗ walk
    focus loops: after "0", swiping on returns to "RESUME Button" (stop 2), so VoiceOver never reaches the end of the screen.
```

An element is any of `identifier` (accessibilityIdentifier), `label`, `type` (such as
`button` or `staticText`), plus `index` when several match and `timeout` (seconds to
wait for it, default 3).

## Matching

Expected text matches speech that **contains** it, so `Save` matches "Save Button".
Wrap it in slashes for a regular expression: `/^Count: [0-9]+$/`. Speech is what
VoiceOver says, including traits, values and hints on iOS 27.2 ("Notifications Switch
button off Double tap to toggle setting.").

## Custom actions

VOFocus can't run custom actions (the Actions rotor) or an element's own VoiceOver
activation (`accessibilityActivate()`, SwiftUI's unnamed `.accessibilityAction { }`):
there's no API for it. It can check that VoiceOver announces them, though: on iOS 27.2
VoiceOver ends the element's speech with "Actions available".

```yaml
  - focus: {identifier: photo, expect: Actions available}
```

This catches actions that a refactor silently removed. Check what each action does by
hand with VoiceOver on a device. (`activate:` on such an element runs its tap handler,
not its VoiceOver activation.)

## Recording

Leave expectations out (`landing:`, `walk:`, `next:`, `focus: {identifier: save}`) and
run `vofocus record <file>`: it runs the steps and prints the scenario with what
VoiceOver actually said filled in. `--write` saves it over the file. **Review the
recording before committing it**: it captures whatever VoiceOver did, bugs included.
Recording keeps `${NAME}` placeholders but not comments.

## Simulator or device

Order and speech checks are reliable on the Simulator. Focus and announcement checks
are flaky there (and the Simulator missed a cut-off announcement that a device caught),
so give those `retries` on the Simulator and confirm them on a device
(`--device <UDID>`). Mark checks the Simulator can't do at all with `deviceOnly: true`.

## The demo scenarios

`demo/` checks the demo app. `scripts/demo.sh` builds the app and sets
`DEMO_BUNDLE_ID` and `DEMO_APP` for them:

```sh
scripts/demo.sh run scenarios/demo                    # Simulator
scripts/demo.sh run scenarios/demo --device <UDID>    # a connected device
```
