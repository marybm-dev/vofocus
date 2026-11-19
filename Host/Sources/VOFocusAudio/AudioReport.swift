import Foundation

/// Something that happened while listening (a scenario step, or an MCP tool call),
/// for lining the audio up with.
public struct AudioEvent: Sendable {
    public let label: String
    public let started: Date
    /// What the runner reported VoiceOver saying, if anything.
    public let reportedSpeech: String?
    /// It only waited for speech something else caused (a `speech` step, vo_speech).
    public let listensOnly: Bool

    public init(label: String, started: Date, reportedSpeech: String?, listensOnly: Bool = false) {
        self.label = label
        self.started = started
        self.reportedSpeech = reportedSpeech
        self.listensOnly = listensOnly
    }
}

/// What was heard while listening, step by step. Saved as JSON beside the recordings.
public struct AudioReport: Sendable, Codable {
    public let title: String
    public let started: Date
    public let folder: String
    public let speechFile: String?
    public let soundsFile: String?
    public let steps: [StepAudio]
    public let words: [HeardWord]
    public let sounds: [HeardSound]
    public let notes: [String]

    /// One line per step that heard something, reported speech or played a sound,
    /// then any notes.
    public var lines: [String] {
        var lines: [String] = []
        for step in steps where !step.heard.isEmpty || !step.sounds.isEmpty || step.expected != nil {
            var parts: [String] = []
            if step.heard.isEmpty {
                parts.append(step.untranscribedSpeech
                    ? "heard speech that wasn't transcribed (listen to the recording)" : "heard nothing")
            } else {
                let text = step.heard.count > 160 ? step.heard.prefix(160) + "…" : Substring(step.heard)
                var speech = "heard \"\(text)\""
                if step.cutOff {
                    if let heard = step.wordsHeard, let expected = step.wordsExpected, heard < expected {
                        speech += ", cut off (\(heard) of \(expected) words)"
                    } else {
                        speech += ", cut off"
                    }
                }
                parts.append(speech)
            }
            if !step.sounds.isEmpty {
                parts.append("sounds: " + Self.collapse(step.sounds.map(\.label)).joined(separator: ", "))
            }
            lines.append("\(step.label): \(parts.joined(separator: "; "))")
        }
        return lines + notes.map { "note: \($0)" }
    }

    /// The recordings, as "speech.wav, sounds.wav" or "nothing recorded".
    public var filesDescription: String {
        var files: [String] = []
        for file in [speechFile, soundsFile].compactMap({ $0 }) where !files.contains(file) { files.append(file) }
        return files.isEmpty ? "nothing recorded" : files.joined(separator: ", ")
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url)
    }

    /// Runs of the same label as one, with a count: "focus moved ×28".
    static func collapse(_ labels: [String]) -> [String] {
        var result: [(label: String, count: Int)] = []
        for label in labels {
            if result.last?.label == label { result[result.count - 1].count += 1 } else { result.append((label, 1)) }
        }
        return result.map { $0.count > 1 ? "\($0.label) ×\($0.count)" : $0.label }
    }
}

@available(macOS 26, *)
public enum AudioAnalysis {
    /// Finds the sounds, transcribes the speech and lines both up with `events`.
    public static func analyze(
        _ recording: AudioRecording, events: [AudioEvent], detector: SoundDetector?, title: String
    ) async -> AudioReport {
        var notes = recording.notes
        var sounds: [HeardSound] = []
        var words: [HeardWord] = []
        if let file = recording.sounds, let detector {
            do { sounds = try detector.detect(in: file) } catch { notes.append("Sound matching failed: \(error)") }
        }
        var audible: [ClosedRange<Double>] = []
        if let file = recording.speech {
            do { words = try await Transcription.words(in: file) } catch { notes.append("Transcription failed: \(error)") }
            audible = (try? SoundDetector.audibleStretches(in: file, excluding: sounds)) ?? []
        }
        let windows = events.map {
            StepWindow(label: $0.label, start: $0.started.timeIntervalSince(recording.started),
                       expected: $0.reportedSpeech, listensOnly: $0.listensOnly)
        }
        let end = recording.stopped.timeIntervalSince(recording.started)
        return AudioReport(
            title: title, started: recording.started, folder: recording.folder.path,
            speechFile: recording.speech?.lastPathComponent, soundsFile: recording.sounds?.lastPathComponent,
            steps: AudioTimeline.steps(windows, words: words, sounds: sounds, audible: audible, end: end),
            words: words, sounds: sounds, notes: notes)
    }
}
