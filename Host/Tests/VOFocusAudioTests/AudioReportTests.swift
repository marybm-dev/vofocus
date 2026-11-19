import Foundation
import Testing
@testable import VOFocusAudio

struct AudioReportTests {
    func step(_ label: String, _ start: Double, _ end: Double) -> StepAudio {
        StepAudio(label: label, start: start, end: end, expected: nil, heard: "", cutOff: false,
                  untranscribedSpeech: false, wordsHeard: nil, wordsExpected: nil, sounds: [])
    }

    func report(_ words: [(Double, String)]) -> AudioReport {
        AudioReport(title: "t", started: Date(), folder: "/", speechFile: nil, soundsFile: nil,
                    steps: [step("launch", 0, 10), step("double tap switch", 10, 17), step("speech", 17, 23)],
                    words: words.map { HeardWord(start: $0.0, end: $0.0 + 0.4, text: $0.1) },
                    sounds: [], notes: [])
    }

    // From a real recording: the app's announcement and the switch's "on" were queued
    // together, so the runner only ever saw "on".
    @Test func findsAnAnnouncementSpokenDuringThePreviousStep() {
        let heard = report([(20.1, "$35"), (20.5, "each,"), (20.9, "$105"), (21.5, "total,"), (22, "on.")])
        #expect(heard.heard("$35.00 each, $105.00 total", aroundStep: 2))
        #expect(!heard.heard("$36.00 each, $108.00 total", aroundStep: 2))
    }

    @Test func ignoresSpeechBeforeThePreviousStep() {
        let heard = report([(5, "$35"), (5.4, "each,"), (5.8, "$105"), (6.2, "total,"), (22, "on.")])
        #expect(!heard.heard("$35.00 each, $105.00 total", aroundStep: 2))
    }

    @Test func dropsOnlyZeroCents() {
        #expect(AudioReport.droppingZeroCents("$35.00 each, $1.50 tip, 2.005") == "$35 each, $1.50 tip, 2.005")
    }
}
