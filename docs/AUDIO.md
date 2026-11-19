# Hearing VoiceOver (experimental)

`vofocus run --audio <folder>` records what VoiceOver actually plays, on the Simulator
or a connected device, while scenarios run, and reports what was heard at each step:

```
PASS  Moving past both ends (edges.yml, 17 s)
    ✓ previous: Traits Heading
    ✓ next: Notifications Switch button off Double tap to toggle setting.
    ✓ next: Share Button Shares this page
    audio (experimental), in /tmp/audio: edges-speech.wav, edges-sounds.wav
      previous: heard nothing; sounds: boundary (nothing further)
      next: heard "Notification.", cut off (1 of 9 words)
      next: heard nothing; sounds: focus moved
```

Agents get the same through the MCP server: `audio_start`, then any tools, then
`audio_report`, which reports what was heard after each call:

```
Heard (experimental; transcription can mishear clipped words):
  vo_move previous: heard nothing; sounds: boundary (nothing further)
  vo_move next: heard "Notification,", cut off (1 of 9 words); sounds: focus moved
Files in build/audio/20261118-201502: session-speech.wav, session-sounds.wav, report.json
```

It's opt-in because the report waits for VoiceOver to finish speaking (2.5 s of quiet)
and transcribes, which adds a few seconds. Listening stops on `audio_report`, on
`runner_stop`, when the server exits, or after `maxMinutes` (default 10), so nothing
records unnoticed. A report after an automatic stop still covers what was recorded.

The text the runner reports is what VoiceOver *meant* to say. The audio shows what
was actually spoken: speech cut off by the next change, speech never heard at all,
and VoiceOver's sounds (the boundary "bonk", focus moves, screen changes), which the
text doesn't include.

## Privacy

### Simulator

- **Never the microphone.** A Core Audio process tap receives only the audio that
  specific processes send to the speakers.
- **Only VoiceOver, only on the chosen Simulator.** The taps are on two processes
  found through that Simulator's own launchd: VoiceOver (`vot`, speech) and the
  system sound server (VoiceOver's sounds). Other apps, other Simulators and the Mac
  aren't recorded.
- **Transcribed on the Mac** with Apple's SpeechAnalyzer. Nothing is uploaded; the
  first run downloads Apple's speech model.
- macOS asks once for permission to record system audio (System Settings > Privacy &
  Security > Screen & System Audio Recording), for the app running `vofocus`.

### Device

- **The phone's own output, over USB, the way QuickTime records an iPhone.** Not the
  phone's microphone or the Mac's.
- **But everything the phone plays,** not only VoiceOver: notifications and other apps
  too, which is why VOFocus asks you to **turn on Do Not Disturb** on the phone
  (`--audio` prints it; `audio_start` tells the agent to tell you). The phone's
  speaker is silent while recording.
- **Camera permission.** macOS files an iPhone's capture stream under camera access,
  as it does for QuickTime, and asks once for the app running VOFocus. The Mac's camera
  isn't used. Microphone permission isn't needed: tested with fresh apps, audio came
  through with camera allowed and microphone explicitly denied, and didn't with only
  microphone access.
- **What people see:** while the iPhone is recorded, macOS shows the green camera
  indicator in the menu bar, and Control Center lists the app running VOFocus under the
  camera icon, because the iPhone's stream counts as a camera. The Mac's camera isn't
  used. There's no microphone indicator (unless that app also has microphone access
  from something else).
- **Alternative without camera permission:** AirPlay mirroring to the Mac plays the
  phone's audio through a Mac process, which the Simulator's process tap could record
  with only system audio permission. It has to be started by hand on the phone each
  time and runs over Wi-Fi (more latency), so it isn't built yet.
- Transcribed on the Mac, as on the Simulator.

## What it saves

For each scenario, in the folder:

| File | |
|---|---|
| `<scenario>-speech.wav` | VoiceOver's speech, for listening to (device: `<scenario>.wav`, speech and sounds together) |
| `<scenario>-sounds.wav` | VoiceOver's sounds (Simulator only) |
| `<scenario>.json` (MCP: `report.json`, in the build folder's `audio/<time>/`) | Each step with what was reported, heard, cut off and the sounds; every word with its time; every sound with its file name and match score |

## How it works

- **Sounds** are found by matching the sounds recording against VoiceOver's own sound
  files, which the Simulator runtime ships (`VoiceOverTouch.app/Sounds`; read in
  place, never copied). Recorded on their own, real sounds match at 0.95–1.00; the
  threshold is 0.9. What each sound means is inferred from Apple's file names and
  when they play; Apple doesn't document them.
- **Speech** is matched to steps by content, not just time, because VoiceOver's audio
  lags the runner: a step often finishes before its speech is heard.
  Among equally good matches, each word goes to the step that started most recently
  before it; speech can't belong to a step that started after it began, except steps
  that only wait for speech (`speech`, `vo_speech`).
- **Sounds** go by time: VoiceOver plays them as soon as it acts, 0.1–0.2 s after a step.
- **"Heard speech that wasn't transcribed"** means the recording was loud enough for
  speech during the step but the transcriber returned no words, which happens with
  short isolated words ("Undo"). Listen to the recording.
- **On a device** speech and sounds arrive mixed in one recording. Sounds are matched
  against the files of the installed Simulator runtime with the phone's iOS version
  (or the newest), and still match at 0.97–1.00 when they don't overlap speech.
- **Cut off** means VoiceOver stopped mid-way and the next step's speech followed
  immediately.
- **VoiceOver restarts** as a new process when an app launches with VoiceOver, and
  speaks at once, so the recorder recognizes the new process directly (its executable,
  and the Simulator's launchd_sim as parent) and taps it within milliseconds.

## Limits

- macOS 26 or later. Devices over USB only (no Wi-Fi).
- On a device, sounds that overlap speech can be missed, and moving back from the first
  element repeats it rather than playing the boundary sound the Simulator plays.
- Transcription normalizes ("2" → "two") and mishears clipped words ("bezel" for
  "Basil"); comparisons allow for small differences. Listen to the WAV to judge
  pronunciation.
- The runner activates elements directly rather than with a real VoiceOver double
  tap, so speech VoiceOver would say on a double tap (and that could cut off an
  announcement) doesn't happen here.
- The sound server can only be recorded once it has played something, so the very
  first sound after a Simulator restart can be missed.
- Agent-driven runs move fast, so walks naturally cut each stop short.
