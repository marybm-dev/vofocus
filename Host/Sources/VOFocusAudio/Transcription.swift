import AVFoundation
import Foundation
import Speech

/// A word VoiceOver said, with when it said it.
public struct HeardWord: Sendable, Codable, Equatable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Transcribes a recording on this Mac with SpeechAnalyzer. Nothing is sent anywhere;
/// the first use downloads Apple's speech model for the language.
@available(macOS 26, *)
public enum Transcription {
    public static func words(in recording: URL, locale: Locale = Locale(identifier: "en-US")) async throws -> [HeardWord] {
        let file = try AVAudioFile(forReading: recording)
        guard file.length > 0 else { return [] }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SimulatorAudioError("On-device transcription doesn't support \(locale.identifier).")
        }
        let transcriber = SpeechTranscriber(
            locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task {
            var words: [HeardWord] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    words.append(HeardWord(start: range.start.seconds, end: range.end.seconds, text: text))
                }
            }
            return words
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value
    }
}
