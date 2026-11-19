import Accelerate
import AVFoundation
import Foundation

/// A VoiceOver sound found in a recording.
public struct HeardSound: Sendable, Codable, Equatable {
    /// Seconds from the start of the recording.
    public let time: Double
    /// The sound file's name, such as "WrapBoundary".
    public let name: String
    /// How closely the recording matched the file, 0–1.
    public let score: Float

    public init(time: Double, name: String, score: Float) {
        self.time = time
        self.name = name
        self.score = score
    }

    /// What the sound means, in words, when it's a sound people often hear. These are
    /// inferred from Apple's file names and behavior; Apple doesn't document them.
    public var meaning: String? { Self.meanings[name] }

    /// The meaning if known, else the file name.
    public var label: String { meaning ?? name }

    static let meanings: [String: String] = [
        "WrapBoundary": "boundary (nothing further)",
        "WrapBoundary-Alternate": "boundary (nothing further)",
        // Heard on ordinary moves, not only when focus wraps.
        "WrapForward": "focus moved",
        "WrapForward-Louder": "focus moved",
        "WrapBack": "focus moved",
        "WrapBack-Louder": "focus moved",
        "ActionsAvailable": "actions available",
        "ScreenChange": "screen changed",
        "ScrollPage": "scrolled a page",
        "EmptySpace": "nothing under the finger",
        "Select": "activated",
        "PopupAppeared": "popup appeared",
        "KeyboardUp": "keyboard appeared",
        "KeyboardDown": "keyboard dismissed",
        "LinkBegin": "link",
        "MoreContentAvailable": "more content available",
        "Edge": "screen edge",
        "Focus": "focus",
        "Alert": "alert",
        "NotFound": "not found",
        "UnsupportedCommandError": "unsupported command",
        "Interactable": "interactable",
        "ContainerTouch": "container",
        "InteractIn": "entered a container",
        "InteractOut": "left a container",
        "DidSwitchApp": "switched apps",
        "WebPageLoaded": "page loaded",
        "WebPageLoadingInProgress": "page loading",
        "Reorder": "reordered",
    ]
}

/// Finds VoiceOver's sounds in a recording of the sound server by matching it against
/// VoiceOver's own sound files (normalized cross-correlation). On a recording with
/// only the sound server in it, real sounds match at 0.95 or more.
public struct SoundDetector: Sendable {
    static let sampleRate = 11025.0
    /// Seconds of each sound matched: enough to tell sounds apart, short enough to
    /// keep matching fast.
    static let window = 0.3

    struct Reference: Sendable {
        let name: String
        let samples: [Float]
        let norm: Float
    }

    let references: [Reference]
    public let threshold: Float

    /// Loads the sound files in `folder` (VoiceOverTouch.app/Sounds), skipping the
    /// "-mono" duplicates.
    public init(soundsFolder folder: URL, threshold: Float = 0.9) throws {
        self.threshold = threshold
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".aiff") && !$0.contains("-mono") }
            .sorted()
        references = try names.compactMap { file in
            var samples = try Self.load(folder.appending(path: file))
            if let start = samples.firstIndex(where: { abs($0) > 0.01 }) { samples.removeFirst(start) }
            samples = Array(samples.prefix(Int(Self.window * Self.sampleRate)))
            let norm = sqrt(vDSP.sumOfSquares(samples))
            guard samples.count > 64, norm > 0 else { return nil }
            return Reference(name: String(file.dropLast(5)), samples: samples, norm: norm)
        }
    }

    public func detect(in recording: URL) throws -> [HeardSound] {
        try detect(in: Self.load(recording))
    }

    func detect(in signal: [Float]) -> [HeardSound] {
        // Running energy, to normalize each stretch of the recording.
        var energy = [Double](repeating: 0, count: signal.count + 1)
        for index in signal.indices { energy[index + 1] = energy[index] + Double(signal[index] * signal[index]) }

        var hits: [HeardSound] = []
        let rate = Self.sampleRate
        for reference in references {
            let length = reference.samples.count
            guard signal.count > length else { continue }
            let count = signal.count - length + 1
            var correlation = [Float](repeating: 0, count: count)
            vDSP_conv(signal, 1, reference.samples, 1, &correlation, 1, vDSP_Length(count), vDSP_Length(length))
            var best: (index: Int, score: Float)?
            for index in 0..<count {
                let localEnergy = energy[index + length] - energy[index]
                guard localEnergy > 1e-6 else { continue }
                let score = correlation[index] / (reference.norm * Float(localEnergy.squareRoot()))
                guard score >= threshold else { continue }
                if let current = best, index - current.index > Int(0.2 * rate) {
                    hits.append(HeardSound(time: Double(current.index) / rate, name: reference.name, score: current.score))
                    best = nil
                }
                if best == nil || score > best!.score { best = (index, score) }
            }
            if let best {
                hits.append(HeardSound(time: Double(best.index) / rate, name: reference.name, score: best.score))
            }
        }
        // Where several files match the same moment, keep the closest match.
        var kept: [HeardSound] = []
        for hit in hits.sorted(by: { $0.time < $1.time }) {
            if let last = kept.last, abs(last.time - hit.time) < 0.1 {
                if hit.score > last.score { kept[kept.count - 1] = hit }
            } else {
                kept.append(hit)
            }
        }
        return kept
    }

    /// Stretches of the recording loud enough to be speech, leaving out the detected
    /// sounds: what was audible, whether or not it was transcribed.
    public static func audibleStretches(in recording: URL, excluding sounds: [HeardSound]) throws -> [ClosedRange<Double>] {
        let samples = try load(recording)
        let frame = Int(sampleRate * 0.05)
        var stretches: [ClosedRange<Double>] = []
        var index = 0
        while index + frame <= samples.count {
            let rms = sqrt(vDSP.meanSquare(samples[index..<index + frame]))
            let time = Double(index) / sampleRate
            index += frame
            guard rms > 0.02, !sounds.contains(where: { time >= $0.time - 0.05 && time <= $0.time + 0.35 }) else { continue }
            if let last = stretches.last, time - last.upperBound <= 0.3 {
                stretches[stretches.count - 1] = last.lowerBound...(time + 0.05)
            } else {
                stretches.append(time...(time + 0.05))
            }
        }
        // Clicks and blips aren't speech.
        return stretches.filter { $0.upperBound - $0.lowerBound >= 0.15 }
    }

    /// Reads an audio file as mono samples at `sampleRate`.
    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { return [] }
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw SimulatorAudioError("Can't convert \(url.lastPathComponent)") }
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(file.length) * sampleRate / file.processingFormat.sampleRate) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
