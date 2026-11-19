import Testing
@testable import VOFocusAudio

struct AudioTimelineTests {
    func words(_ list: [(Double, Double, String)]) -> [HeardWord] {
        list.map { HeardWord(start: $0.0, end: $0.1, text: $0.2) }
    }

    @Test func speechStillGoingWhenTheNextStepStartsIsCutOff() {
        let windows = [
            StepWindow(label: "next", start: 1.0, expected: "Done Button Swipe up or down to select a custom action"),
            StepWindow(label: "next", start: 2.0, expected: "Share Button"),
        ]
        let heard = words([(1.3, 1.6, "Done,"), (1.6, 1.9, "button."), (1.9, 2.2, "Swipe"),
                           (2.3, 2.6, "Share,"), (2.6, 3.0, "button.")])
        let steps = AudioTimeline.steps(windows, words: heard, sounds: [], end: 5)
        #expect(steps[0].heard == "Done, button. Swipe")
        #expect(steps[0].cutOff)
        #expect(steps[0].wordsHeard == 3)
        #expect(steps[0].wordsExpected == 11)
        #expect(steps[1].heard == "Share, button.")
        #expect(!steps[1].cutOff)
        #expect(steps[1].wordsHeard == 2)
    }

    @Test func speechThatFinishesBeforeTheNextStepIsNotCutOff() {
        let windows = [StepWindow(label: "next", start: 0, expected: "One"),
                       StepWindow(label: "next", start: 2, expected: "Two")]
        let steps = AudioTimeline.steps(windows, words: words([(0.3, 0.6, "One."), (2.3, 2.6, "Two.")]), sounds: [], end: 3)
        #expect(!steps[0].cutOff)
        #expect(steps.map(\.heard) == ["One.", "Two."])
    }

    @Test func soundsGoToTheStepTheyFollow() {
        let windows = [StepWindow(label: "a", start: 0, expected: nil), StepWindow(label: "b", start: 2, expected: nil)]
        let sounds = [HeardSound(time: 0.5, name: "WrapBoundary", score: 1), HeardSound(time: 2.4, name: "ScreenChange", score: 1)]
        let steps = AudioTimeline.steps(windows, words: [], sounds: sounds, end: 3)
        #expect(steps[0].sounds.map(\.name) == ["WrapBoundary"])
        #expect(steps[1].sounds.map(\.name) == ["ScreenChange"])
        #expect(steps[0].sounds[0].label == "boundary (nothing further)")
    }

    @Test func speechSaidOnceGoesToTheFirstStepThatReportedIt() {
        // Moving back from the first element bonks without repeating it.
        let windows = [StepWindow(label: "landing", start: 0, expected: "Traits Heading"),
                       StepWindow(label: "previous", start: 1.0, expected: "Traits Heading")]
        let steps = AudioTimeline.steps(windows, words: words([(0.8, 1.1, "Traits,"), (1.1, 1.5, "heading.")]),
                                        sounds: [], end: 3)
        #expect(steps.map(\.heard) == ["Traits, heading.", ""])
    }

    @Test func numbersAreComparedAsSpokenWords() {
        #expect(AudioTimeline.normalizedWords("Toppings, Fresh Basil, and 2 more") ==
                ["toppings", "fresh", "basil", "and", "two", "more"])
        #expect(AudioTimeline.commonSubsequenceLength(["a", "b", "c", "d"], ["a", "c", "x", "d"]) == 3)
        #expect(AudioTimeline.normalizedWords("W1W2W3.") == ["w1", "w2", "w3"])
        #expect(AudioTimeline.similar("notification", "notifications"))
        #expect(AudioTimeline.similar("basil", "bazil"))
        #expect(!AudioTimeline.similar("one", "ones"))
    }

    @Test func lateSpeechIsMatchedToItsStepByContent() {
        // The runner finishes each step before VoiceOver's audio is heard.
        let windows = [
            StepWindow(label: "launch", start: 0, expected: nil),
            StepWindow(label: "focus #save", start: 0.5, expected: "Save Button"),
            StepWindow(label: "activate", start: 1.0, expected: nil),
            StepWindow(label: "speech", start: 1.2, expected: "Profile saved"),
        ]
        let heard = words([(0.9, 1.2, "VOFocus"), (1.2, 1.5, "demo,"), (1.5, 1.9, "heading."),
                           (2.6, 2.9, "Save,"), (2.9, 3.2, "button."),
                           (4.0, 4.4, "Profile"), (4.4, 4.8, "saved.")])
        let steps = AudioTimeline.steps(windows, words: heard, sounds: [], end: 6)
        #expect(steps.map(\.heard) == ["VOFocus demo, heading.", "Save, button.", "", "Profile saved."])
        #expect(steps.allSatisfy { !$0.cutOff })
        #expect(steps[1].wordsHeard == 2)
        #expect(steps[3].wordsHeard == 2)
    }
}
