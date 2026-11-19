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
        #expect(AudioTimeline.similar("notificator", "notifications"))
        #expect(!AudioTimeline.similar("profile", "professional"))
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

    @Test func speechAlreadyUnderWayWhenAStepStartsIsNotThatStepsSpeech() {
        // The launch's speech is still going when the first move is made.
        let windows = [StepWindow(label: "before", start: 0, expected: nil),
                       StepWindow(label: "previous", start: 1.44, expected: "Traits Heading")]
        let steps = AudioTimeline.steps(windows, words: words([(1.4, 2.2, "Traits,"), (2.28, 2.9, "heading.")]),
                                        sounds: [], end: 4)
        #expect(steps.map(\.heard) == ["Traits, heading.", ""])
    }

    @Test func speechGoesToTheMostRecentStepThatReportedIt() {
        // A walk and a later focus both reported "Save Button".
        let windows = [StepWindow(label: "walk", start: 0, expected: "Edit Profile Heading Save Button Cancel Button"),
                       StepWindow(label: "focus #save", start: 5, expected: "Save Button"),
                       StepWindow(label: "activate", start: 6, expected: nil),
                       StepWindow(label: "speech", start: 6.2, expected: "Saved successfully", listensOnly: true)]
        let heard = words([(0.3, 0.6, "Edit"), (0.6, 0.9, "profile,"), (0.9, 1.2, "heading,"), (1.2, 1.5, "save,"),
                           (1.6, 1.9, "cancel,"), (1.9, 2.3, "button."),
                           (5.3, 5.6, "Save,"), (5.6, 5.9, "button."),
                           (6.15, 6.6, "Saved"), (6.6, 7.2, "successfully.")])
        let steps = AudioTimeline.steps(windows, words: heard, sounds: [], end: 8)
        #expect(steps.map(\.heard) == ["Edit profile, heading, save, cancel, button.", "Save, button.", "",
                                       "Saved successfully."])
    }

    @Test func speechStillGoingWhenAStepStartsStaysWithTheStepThatStartedIt() {
        // On a device: VoiceOver is still saying where it landed when the next move is
        // made, and both steps reported the same words.
        let windows = [StepWindow(label: "landing", start: 0.5, expected: "Traits Heading"),
                       StepWindow(label: "previous", start: 11.13, expected: "Traits Heading")]
        let heard = words([(9.84, 10.3, "VoiceOver"), (10.32, 10.6, "on."), (10.62, 11.0, "Demo"),
                           (11.2, 11.6, "traits,"), (11.6, 12.1, "heading.")])
        let steps = AudioTimeline.steps(windows, words: heard, sounds: [], end: 14)
        #expect(steps.map(\.heard) == ["VoiceOver on. Demo traits, heading.", ""])
        #expect(steps[0].wordsHeard == 2)
    }

    @Test func audibleSpeechWithoutWordsIsReportedAsUntranscribed() {
        let windows = [StepWindow(label: "focus", start: 0, expected: "Done Button"),
                       StepWindow(label: "swipe down", start: 5, expected: "Undo"),
                       StepWindow(label: "wait", start: 9, expected: nil)]
        let steps = AudioTimeline.steps(windows, words: words([(0.3, 0.6, "Done,"), (0.6, 1.0, "button.")]),
                                        sounds: [], audible: [0.3...1.0, 5.6...6.0], end: 10)
        #expect(!steps[0].untranscribedSpeech)
        #expect(steps[1].heard.isEmpty && steps[1].untranscribedSpeech)
        #expect(!steps[2].untranscribedSpeech)
    }
}
