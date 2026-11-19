import Foundation
import VOFocusAudio
import VOFocusKit
import VOFocusScenarios

/// `run --audio <folder>` (experimental): records VoiceOver's speech and sounds on the
/// Simulator while each scenario runs, then transcribes the speech, finds the sounds,
/// and lines both up with the steps.
@available(macOS 26, *)
struct AudioCapture {
    let directory: URL
    let simulator: String
    let detector: SoundDetector

    static func prepare(directory path: String, simulatorName: String) async throws -> AudioCapture {
        guard let udid = try await Shell.simulatorUDID(named: simulatorName) else {
            throw RuntimeError("--audio: no iOS 27 Simulator named \"\(simulatorName)\".")
        }
        let detector = try SoundDetector(soundsFolder: try await SimulatorAudioSource.soundsFolder(simulator: udid))
        return AudioCapture(directory: URL(filePath: path).standardizedFileURL, simulator: udid, detector: detector)
    }

    /// Runs `body` while recording, then analyzes the recording.
    func record(_ scenario: Scenario, _ body: () async -> ScenarioResult) async -> (ScenarioResult, AudioReport?) {
        let name = scenario.file?.deletingPathExtension().lastPathComponent ?? "scenario"
        let recorder = SimulatorAudioRecorder(simulator: simulator, directory: directory, name: name)
        do {
            try await recorder.start()
        } catch {
            note("Couldn't record audio: \(error)")
            return (await body(), nil)
        }
        let result = await body()
        // Let the last step's speech finish.
        try? await Task.sleep(for: .seconds(0.5))
        await recorder.waitUntilQuiet()
        let recording = await recorder.stop()
        return (result, await analyze(recording, result: result, name: name))
    }

    private func analyze(_ recording: SimulatorAudioRecorder.Recording, result: ScenarioResult, name: String) async -> AudioReport {
        var notes = recording.notes
        var sounds: [HeardSound] = []
        var words: [HeardWord] = []
        if let file = recording.sounds {
            do { sounds = try detector.detect(in: file) } catch { notes.append("Sound matching failed: \(error)") }
        }
        if let file = recording.speech {
            do { words = try await Transcription.words(in: file) } catch { notes.append("Transcription failed: \(error)") }
        }

        func seconds(_ date: Date?) -> Double { date.map { $0.timeIntervalSince(recording.started) } ?? 0 }
        // Launching speaks where VoiceOver lands, which the landing step reports.
        var steps = result.steps
        var windows: [StepWindow] = []
        let landing = steps.first.flatMap { if case .landing = $0.step { return $0 } else { return nil } }
        if landing != nil { steps.removeFirst() }
        windows.append(StepWindow(label: landing == nil ? "launch" : "landing", start: seconds(result.started),
                                  expected: landing?.observed?.first))
        for step in steps where step.started != nil {
            windows.append(StepWindow(label: step.step.summary, start: seconds(step.started),
                                      expected: Self.reportedSpeech(step)))
        }
        let end = Date().timeIntervalSince(recording.started)
        let report = AudioReport(
            scenario: result.scenario.name, started: recording.started,
            speechFile: recording.speech?.lastPathComponent, soundsFile: recording.sounds?.lastPathComponent,
            steps: AudioTimeline.steps(windows, words: words, sounds: sounds, end: end),
            words: words, sounds: sounds, notes: notes)
        let json = directory.appending(path: "\(name).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do { try encoder.encode(report).write(to: json) } catch { note("Couldn't write \(json.path): \(error)") }
        return report
    }

    /// What the runner reported VoiceOver saying during a step, if anything.
    static func reportedSpeech(_ step: StepResult) -> String? {
        switch step.step {
        case .next, .previous, .current, .focus, .speech: step.observed?.first
        case .walk: step.observed?.joined(separator: " ")
        default: nil
        }
    }
}

struct AudioReport: Codable {
    let scenario: String
    let started: Date
    let speechFile: String?
    let soundsFile: String?
    let steps: [StepAudio]
    let words: [HeardWord]
    let sounds: [HeardSound]
    let notes: [String]

    func print(directory: URL) {
        let files = [speechFile, soundsFile].compactMap { $0 }
        Swift.print("    audio (experimental), in \(directory.path): \(files.isEmpty ? "nothing recorded" : files.joined(separator: ", "))")
        for step in steps where !step.heard.isEmpty || !step.sounds.isEmpty || step.expected != nil {
            var parts: [String] = []
            if step.heard.isEmpty {
                parts.append("heard nothing")
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
            Swift.print("      \(step.label): \(parts.joined(separator: "; "))")
        }
        for note in notes { Swift.print("      note: \(note)") }
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
