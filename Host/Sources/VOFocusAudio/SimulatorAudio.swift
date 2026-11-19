import CoreAudio
import Foundation
import VOFocusKit

/// The two Simulator processes whose audio VOFocus records, found through the
/// Simulator's own launchd so only the chosen Simulator is recorded, even when several
/// are booted.
public enum SimulatorAudioSource: String, CaseIterable, Sendable, Codable {
    /// VoiceOver itself (`vot`), which speaks.
    case speech = "com.apple.VoiceOverTouch"
    /// The system sound server, which plays VoiceOver's sounds.
    case sounds = "com.apple.audio.systemsoundserver-simd"

    /// Each source's process ID in the Simulator, for those that are running.
    static func processIDs(simulator udid: String) async throws -> [SimulatorAudioSource: pid_t] {
        let output = try await Shell.run(["xcrun", "simctl", "spawn", udid, "launchctl", "list"])
        guard output.status == 0 else {
            throw SimulatorAudioError("Couldn't list the Simulator's processes: \(output.text)")
        }
        var result: [SimulatorAudioSource: pid_t] = [:]
        for line in output.text.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count == 3, let pid = pid_t(fields[0]),
                  let source = SimulatorAudioSource(rawValue: String(fields[2])) else { continue }
            result[source] = pid
        }
        return result
    }

    /// `VoiceOverTouch.app/Sounds` in the Simulator's runtime: the sound files VoiceOver
    /// plays, which the sound detector matches against. Read in place, never copied.
    public static func soundsFolder(simulator udid: String) async throws -> URL {
        struct Devices: Decodable {
            struct Device: Decodable { let udid: String }
            let devices: [String: [Device]]
        }
        struct Runtimes: Decodable {
            struct Runtime: Decodable { let identifier: String; let runtimeRoot: String? }
            let runtimes: [Runtime]
        }
        let devices = try await Shell.run(["xcrun", "simctl", "list", "devices", "-j"])
        let runtimes = try await Shell.run(["xcrun", "simctl", "list", "runtimes", "-j"])
        let runtime = try JSONDecoder().decode(Devices.self, from: Data(devices.text.utf8)).devices
            .first { $0.value.contains { $0.udid == udid } }?.key
        guard let runtime,
              let root = try JSONDecoder().decode(Runtimes.self, from: Data(runtimes.text.utf8)).runtimes
                .first(where: { $0.identifier == runtime })?.runtimeRoot
        else { throw SimulatorAudioError("Couldn't find the runtime of Simulator \(udid).") }
        return URL(filePath: root).appending(path: "System/Library/CoreServices/VoiceOverTouch.app/Sounds")
    }
}

public struct SimulatorAudioError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Records a Simulator's VoiceOver speech and VoiceOver sounds into two WAV files, with
/// a process tap on each source. Nothing is recorded from the microphone or from any
/// other app. macOS asks once for permission to record system audio.
///
/// VoiceOver's process changes when VoiceOver restarts, and a process can only be
/// tapped once it has played something, so the recorder re-checks the processes
/// whenever Core Audio's process list changes.
@available(macOS 14.2, *)
public actor SimulatorAudioRecorder {
    public struct Recording: Sendable {
        /// When time 0 in both files was.
        public let started: Date
        /// Nil when VoiceOver said nothing.
        public let speech: URL?
        /// Nil when the sound server played nothing.
        public let sounds: URL?
        /// Problems while recording (such as a source that never played anything).
        public let notes: [String]
    }

    private let udid: String
    private let started: Date
    private let streams: [SimulatorAudioSource: ProcessTapStream]
    private var listener: AudioObjectPropertyListenerBlock?
    private var notes: [String] = []
    private var refreshing = false
    private var refreshAgain = false

    /// Files are `<directory>/<name>-speech.wav` and `<name>-sounds.wav`.
    public init(simulator udid: String, directory: URL, name: String) {
        self.udid = udid
        let origin = CoreAudioProperty.nowNanos
        started = Date()
        streams = Dictionary(uniqueKeysWithValues: SimulatorAudioSource.allCases.map { source in
            let suffix = source == .speech ? "speech" : "sounds"
            return (source, ProcessTapStream(url: directory.appending(path: "\(name)-\(suffix).wav"), origin: origin))
        })
    }

    public func start() async throws {
        try FileManager.default.createDirectory(
            at: streams[.speech]!.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { await self.refresh() }
        }
        var address = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, listener)
        self.listener = listener
        await refresh()
    }

    /// Waits until VoiceOver has been quiet for `quiet` seconds, at most `limit`
    /// seconds, so the last step's speech is recorded in full.
    public func waitUntilQuiet(quiet: Double = 1.0, limit: Double = 15) async {
        let deadline = Date().addingTimeInterval(limit)
        while Date() < deadline {
            let since = streams.values.compactMap(\.secondsSinceHeard).min()
            if since.map({ $0 >= quiet }) ?? true { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        note("VoiceOver was still playing audio \(Int(limit)) s after the last step; the recording stops there.")
    }

    public func stop() -> Recording {
        if let listener {
            var address = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, listener)
        }
        listener = nil
        var files: [SimulatorAudioSource: URL] = [:]
        for (source, stream) in streams {
            stream.finish()
            if FileManager.default.fileExists(atPath: stream.url.path) { files[source] = stream.url }
        }
        return Recording(started: started, speech: files[.speech], sounds: files[.sounds], notes: notes)
    }

    /// Points each tap at its source's current process.
    private func refresh() async {
        if refreshing { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            guard listener != nil else { return }
            let pids: [SimulatorAudioSource: pid_t]
            do {
                pids = try await SimulatorAudioSource.processIDs(simulator: udid)
            } catch {
                note("\(error)")
                return
            }
            for (source, stream) in streams {
                // Keep the current tap until the new process has played something.
                guard let pid = pids[source], let object = CoreAudioProperty.processObject(pid: pid) else { continue }
                do {
                    try stream.retarget([object])
                } catch {
                    note("\(source): \(error)")
                }
            }
        } while refreshAgain
    }

    private func note(_ message: String) {
        if !notes.contains(message) { notes.append(message) }
    }
}
