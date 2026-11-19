import Foundation
import VOFocusAudio
import VOFocusKit
import VOFocusScenarios

/// `run --audio <folder>` (experimental): records VoiceOver's speech and sounds on the
/// Simulator while each scenario runs, then transcribes the speech, finds the sounds,
/// and lines both up with the steps. See docs/AUDIO.md.
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

    /// Runs `body` while recording, then analyzes the recording and saves the report.
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
        let report = await AudioAnalysis.analyze(
            recording, events: Self.events(result), detector: detector, title: scenario.name)
        let json = directory.appending(path: "\(name).json")
        do { try report.write(to: json) } catch { note("Couldn't write \(json.path): \(error)") }
        return (result, report)
    }

    /// The launch, then each step. Launching speaks where VoiceOver lands, which the
    /// landing step reports.
    static func events(_ result: ScenarioResult) -> [AudioEvent] {
        var steps = result.steps
        let landing = steps.first.flatMap { if case .landing = $0.step { return $0 } else { return nil } }
        if landing != nil { steps.removeFirst() }
        var events = [AudioEvent(label: landing == nil ? "launch" : "landing", started: result.started ?? Date(),
                                 reportedSpeech: landing?.observed?.first)]
        for step in steps {
            guard let started = step.started else { continue }
            let listensOnly = switch step.step { case .speech, .current: true; default: false }
            events.append(AudioEvent(label: step.step.summary, started: started, reportedSpeech: reportedSpeech(step),
                                     listensOnly: listensOnly))
        }
        return events
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

extension AudioReport {
    func print() {
        Swift.print("    audio (experimental), in \(folder): \(filesDescription)")
        for line in lines { Swift.print("      \(line)") }
    }
}
