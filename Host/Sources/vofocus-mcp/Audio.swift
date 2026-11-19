import Foundation
import VOFocusAudio
import VOFocusKit

/// audio_start and audio_report (experimental): listen to what VoiceOver actually
/// says and plays on the Simulator while the agent uses the other tools. Opt-in,
/// because waiting for VoiceOver to finish and transcribing take a few seconds.
///
/// Listening stops on audio_report, runner_stop, when the server exits, or after a
/// time limit, so nothing keeps recording unnoticed. See docs/AUDIO.md.
actor AudioTools {
    private let manager: RunnerManager
    private let buildDirectory: URL
    private var session: Any?  // AudioSession, which needs macOS 26.

    init(manager: RunnerManager, buildDirectory: URL) {
        self.manager = manager
        self.buildDirectory = buildDirectory
    }

    func start(maxMinutes: Double) async throws -> String {
        guard #available(macOS 26, *) else { throw AudioToolError("Listening needs macOS 26 or later.") }
        guard manager.configuration.device == nil else {
            throw AudioToolError("Listening works on the Simulator only for now.")
        }
        if let session = session as? AudioSession, await session.isListening {
            return "Already listening since \(await session.startedDescription). Call audio_report to get what was heard."
        }
        guard let udid = try await Shell.simulatorUDID(named: manager.configuration.simulator) else {
            throw AudioToolError("No iOS 27 Simulator named \"\(manager.configuration.simulator)\".")
        }
        let session = AudioSession(simulator: udid, folder: Self.newFolder(in: buildDirectory))
        try await session.start(limit: maxMinutes * 60)
        self.session = session
        return """
            Listening to VoiceOver's speech and sounds on the Simulator (never the microphone), \
            for up to \(Int(maxMinutes)) minutes. Use the other tools, then call audio_report.
            """
    }

    /// Notes a tool call, so the report can say what was heard after it.
    func log(_ label: String, started: Date, response: String?) async {
        guard #available(macOS 26, *), let session = session as? AudioSession else { return }
        await session.log(AudioEvent(label: label, started: started,
                                     reportedSpeech: response.flatMap { Self.speech(fromResponse: $0) },
                                     listensOnly: label.hasPrefix("vo_speech")))
    }

    func report(wait: Double) async throws -> String {
        guard #available(macOS 26, *), let session = session as? AudioSession else {
            throw AudioToolError("Not listening. Call audio_start first, then the tools whose audio you want.")
        }
        self.session = nil
        let report = await session.report(wait: wait)
        var lines = ["Heard (experimental; transcription can mishear clipped words):"]
        lines += report.lines.isEmpty ? ["nothing"] : report.lines.map { "  \($0)" }
        lines.append("Files in \(report.folder): \(report.filesDescription), report.json")
        return lines.joined(separator: "\n")
    }

    /// Stops recording (keeping what was recorded for audio_report).
    func stop(reason: String) async {
        guard #available(macOS 26, *), let session = session as? AudioSession else { return }
        await session.stop(reason: reason)
    }

    private static func newFolder(in buildDirectory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return buildDirectory.appending(path: "audio/\(formatter.string(from: Date()))")
    }

    /// The speech in a runner reply: `utterance`, or a walk's `stops`.
    static func speech(fromResponse text: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        if let utterance = object["utterance"] as? String { return utterance }
        if let stops = object["stops"] as? [String] { return stops.joined(separator: " ") }
        return nil
    }
}

struct AudioToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@available(macOS 26, *)
private actor AudioSession {
    private let recorder: SimulatorAudioRecorder
    private let simulator: String
    private let started = Date()
    private var events: [AudioEvent] = []
    private var recording: SimulatorAudioRecorder.Recording?
    private var limit: Task<Void, Never>?

    init(simulator: String, folder: URL) {
        self.simulator = simulator
        recorder = SimulatorAudioRecorder(simulator: simulator, directory: folder, name: "session")
    }

    var isListening: Bool { recording == nil }
    var startedDescription: String { started.formatted(date: .omitted, time: .standard) }

    func start(limit seconds: Double) async throws {
        try await recorder.start()
        events.append(AudioEvent(label: "before the first tool call", started: started, reportedSpeech: nil))
        limit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.stop(reason: "Stopped listening after the \(Int(seconds / 60))-minute limit.")
        }
    }

    func log(_ event: AudioEvent) {
        if isListening { events.append(event) }
    }

    func stop(reason: String?) async {
        guard recording == nil else { return }
        limit?.cancel()
        var stopped = await recorder.stop()
        if let reason { stopped = stopped.adding(note: reason) }
        recording = stopped
    }

    func report(wait: Double) async -> AudioReport {
        if recording == nil {
            await recorder.waitUntilQuiet(limit: wait)
            await stop(reason: nil)
        }
        let recording = recording!
        let detector: SoundDetector? = try? SoundDetector(
            soundsFolder: try await SimulatorAudioSource.soundsFolder(simulator: simulator))
        let report = await AudioAnalysis.analyze(recording, events: events, detector: detector, title: "MCP session")
        try? report.write(to: recording.folder.appending(path: "report.json"))
        return report
    }
}
