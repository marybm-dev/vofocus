// Spike: transcribe a recording on-device with SpeechAnalyzer, with word timings.
//   transcribe <file> [locale]
import AVFoundation
import Foundation
import Speech

@main struct Transcribe {
    static func main() async throws {
        let url = URL(filePath: CommandLine.arguments[1])
        let locale = Locale(identifier: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "en-US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            FileHandle.standardError.write("downloading the speech model...\n".data(using: .utf8)!)
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task {
            var out: [(Double, Double, String)] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    out.append((range.start.seconds, range.end.seconds, String(result.text[run.range].characters)))
                }
            }
            return out
        }
        let file = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        for (start, end, text) in try await collect.value {
            print(String(format: "%7.2f %7.2f  %@", start, end, text))
        }
    }
}
