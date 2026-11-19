# Spike: hearing VoiceOver on the Simulator

Experimental. Records what VoiceOver actually plays on the Simulator, **without the
microphone**, and turns it into text an agent can read.

## Pieces

| File | Does |
|---|---|
| `tap.swift` | Records the output of Simulator processes with a Core Audio process tap (macOS 14.2+). macOS asks once for permission to record system audio (not the mic). `tap <seconds> <out.caf> [runtime\|service\|all\|name:<process>] [--mute]` |
| `transcribe.swift` | Transcribes on-device with SpeechAnalyzer, with word timings. |
| `earcons.swift` | Finds VoiceOver's sounds by normalized cross-correlation against the sound files in the Simulator runtime (`VoiceOverTouch.app/Sounds`, read in place, never copied). |
| `list.swift` | Lists Core Audio's process objects, to see which processes play audio. |

Build: `swiftc -O tap.swift -o tap -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist`,
`swiftc -O -parse-as-library transcribe.swift -o transcribe`, `swiftc -O earcons.swift -o earcons`.

## Findings (iOS 27.2 Simulator, macOS 27.2)

- **Taps work on Simulator processes.** The aggregate device needs a real output
  device as its clock, or the IO proc never runs.
- **Speech and sounds come from different processes.** Speech is `vot` (VoiceOver);
  sounds are `systemsoundserver-simd`. Recorded separately, sounds match their files
  at 0.96–1.00. Mixed with speech they score ~0.7, no better than false matches.
- **The boundary "bonk" is `WrapBoundary`.** Detected once per move past the first or
  last element.
- **Audio shows what the text API hides.** Past the last element, `/vo/next` reports
  the element again, but the audio shows VoiceOver bonking and re-speaking it. Each new
  move cuts off the previous speech mid-word ("Swipe up or down…" hint never finishes).
- **Transcription normalizes** ("2" → "two") and mishears clipped words, so compare
  fuzzily and keep the recording for a person to listen to.

## Next

Built as `vofocus run --audio` ([docs/AUDIO.md](../../docs/AUDIO.md)). The plan was:

1. Tap `vot` and `systemsoundserver-simd` as two streams, re-resolving PIDs when
   VoiceOver restarts.
2. Align both with the runner's move and speech events; report per step: transcript,
   sounds, and whether speech finished or was cut off.
3. Name sounds for people (WrapBoundary → "boundary", ActionsAvailable, ScreenChange…).
4. Devices: QuickTime-style USB capture (CoreMediaIO). That stream mixes speech and
   sounds, so matching will be weaker there.
