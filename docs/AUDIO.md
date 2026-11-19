# Hearing VoiceOver (experimental)

`vofocus run --audio <folder>` records what VoiceOver actually plays on the Simulator
while scenarios run, and reports what was heard at each step:

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

The text the runner reports is what VoiceOver *meant* to say. The audio shows what
was actually spoken: speech cut off by the next change, speech never heard at all,
and VoiceOver's sounds (the boundary "bonk", focus moves, screen changes), which the
text doesn't include.

## Privacy

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

## What it saves

For each scenario, in the folder:

| File | |
|---|---|
| `<scenario>-speech.wav` | VoiceOver's speech, for listening to |
| `<scenario>-sounds.wav` | VoiceOver's sounds |
| `<scenario>.json` | Each step with what was reported, heard, cut off and the sounds; every word with its time; every sound with its file name and match score |

## How it works

- **Sounds** are found by matching the sounds recording against VoiceOver's own sound
  files, which the Simulator runtime ships (`VoiceOverTouch.app/Sounds`; read in
  place, never copied). Recorded on their own, real sounds match at 0.95–1.00; the
  threshold is 0.9. What each sound means is inferred from Apple's file names and
  when they play; Apple doesn't document them.
- **Speech** is matched to steps by content, not just time, because VoiceOver's audio
  lags the runner: a step often finishes before its speech is heard.
- **Cut off** means VoiceOver stopped mid-way and the next step's speech followed
  immediately.

## Limits

- Simulator only, macOS 26 or later. Devices would need QuickTime-style USB capture,
  where speech and sounds arrive mixed (weaker sound matching).
- Transcription normalizes ("2" → "two") and mishears clipped words ("bezel" for
  "Basil"); comparisons allow for small differences. Listen to the WAV to judge
  pronunciation.
- The runner activates elements directly rather than with a real VoiceOver double
  tap, so speech VoiceOver would say on a double tap (and that could cut off an
  announcement) doesn't happen here.
- The sound server can only be recorded once it has played something, so the very
  first sound after a Simulator restart can be missed.
- Agent-driven runs move fast, so walks naturally cut each stop short.
