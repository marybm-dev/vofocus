import Foundation
import Testing
import VOFocusKit
@testable import VOFocusScenarios

@Suite struct ScenarioParsingTests {
    let yaml = """
        name: Save moves focus to the banner
        app:
          bundleId: com.example.App
          install: build/App.app
          arguments: [-VOScenario, uikit-banner]
          environment: {MODE: test}
        deviceOnly: true
        retries: 2
        steps:
          - landing: Edit Profile Heading
          - walk: [Edit Profile Heading, Save Button, /Cancel( Button)?/]
          - next:
          - current: Save
          - focus: {identifier: save, expect: Save Button}
          - activate:
          - activate: {label: Save}
          - speech: Saved successfully
          - speech: {expect: Done, timeout: 5}
          - tap: {identifier: menu, double: true}
          - type: {text: Ada, identifier: name}
          - wait: 0.5
        """

    @Test func parsesEveryField() throws {
        let scenario = try Scenario.parse(yaml)
        #expect(scenario.name == "Save moves focus to the banner")
        #expect(scenario.bundleId == "com.example.App")
        #expect(scenario.install == "build/App.app")
        #expect(scenario.arguments == ["-VOScenario", "uikit-banner"])
        #expect(scenario.environment == ["MODE": "test"])
        #expect(scenario.deviceOnly)
        #expect(scenario.retries == 2)
        #expect(scenario.steps == [
            .landing(Expectation("Edit Profile Heading")),
            .walk([Expectation("Edit Profile Heading"), Expectation("Save Button"), Expectation("/Cancel( Button)?/")]),
            .next(nil),
            .current(Expectation("Save")),
            .focus(ElementQuery(identifier: "save"), Expectation("Save Button")),
            .activate(nil),
            .activate(ElementQuery(label: "Save")),
            .speech(Expectation("Saved successfully"), timeout: 3),
            .speech(Expectation("Done"), timeout: 5),
            .tap(ElementQuery(identifier: "menu"), double: true),
            .type("Ada", ElementQuery(identifier: "name")),
            .wait(0.5),
        ])
    }

    @Test func reportsWhichStepIsWrong() {
        let bad = """
            name: x
            app: {bundleId: a}
            steps:
              - walk: [One]
              - focus: Save
            """
        #expect(throws: ScenarioError.self) { try Scenario.parse(bad) }
        do {
            _ = try Scenario.parse(bad)
        } catch {
            #expect("\(error)".contains("step 2"))
        }
    }

    @Test func rejectsUnknownSteps() {
        #expect(throws: ScenarioError.self) {
            try Scenario.parse("name: x\napp: {bundleId: a}\nsteps:\n  - swipe: left\n")
        }
    }

    @Test func substitutesEnvironmentVariables() throws {
        let text = try Scenario.substitute("bundleId: ${ID}.App", ["ID": "com.example"])
        #expect(text == "bundleId: com.example.App")
        #expect(throws: ScenarioError.self) { try Scenario.substitute("${MISSING}", [:]) }
    }
}

@Suite struct ExpectationTests {
    @Test func plainTextMatchesWhenContained() {
        #expect(Expectation("Save").matches("Save Button"))
        #expect(!Expectation("Save").matches("Cancel Button"))
    }

    @Test func slashesMakeARegularExpression() {
        let expectation = Expectation("/^Count: [0-9]+$/")
        #expect(expectation.isRegex)
        #expect(expectation.matches("Count: 42"))
        #expect(!expectation.matches("Count: many"))
    }

    @Test func orderDifferenceMarksTheMismatch() {
        let report = ScenarioRunner.orderDifference(
            expected: [Expectation("One"), Expectation("Two")],
            actual: ["One Button", "Three Button", "Two Button"])
        #expect(report.contains("expected 2 stops, VoiceOver made 3"))
        #expect(report.contains("✗ 2. expected \"Two\", heard \"Three Button\""))
        #expect(report.contains("  1. expected \"One\""))
    }
}

@Suite struct ScenarioWriterTests {
    @Test func roundTripsAScenario() throws {
        let original = try Scenario.parse("""
            name: Round trip
            app:
              bundleId: ${BUNDLE}
              arguments: [-A, b]
            retries: 1
            steps:
              - landing: Heading
              - walk: [One, Two]
              - focus: {identifier: save, expect: /Save/}
              - activate:
              - speech: {expect: Saved, timeout: 5}
            """)
        let written = ScenarioWriter.yaml(for: original)
        let reparsed = try Scenario.parse(written)
        #expect(reparsed.steps == original.steps)
        #expect(reparsed.bundleId == "${BUNDLE}")
        #expect(reparsed.arguments == ["-A", "b"])
        #expect(reparsed.retries == 1)
        #expect(written.contains(#"expect: "/Save/""#))
    }

    @Test func fillsInRecordedSpeech() throws {
        let scenario = try Scenario.parse("""
            name: Record
            app: {bundleId: a}
            steps:
              - landing:
              - walk:
              - focus: {identifier: save}
              - activate:
            """)
        let result = ScenarioResult(scenario: scenario, steps: [
            StepResult(step: scenario.steps[0], outcome: .passed, detail: "", observed: ["Heading"]),
            StepResult(step: scenario.steps[1], outcome: .passed, detail: "", observed: ["Heading", "Save Button"]),
            StepResult(step: scenario.steps[2], outcome: .passed, detail: "", observed: ["Save Button"]),
            StepResult(step: scenario.steps[3], outcome: .passed, detail: "", observed: nil),
        ], seconds: 1, skipped: nil, attempts: 1)
        let recorded = try Scenario.parse(ScenarioWriter.yaml(for: scenario, recordedFrom: result))
        #expect(recorded.steps == [
            .landing(Expectation("Heading")),
            .walk([Expectation("Heading"), Expectation("Save Button")]),
            .focus(ElementQuery(identifier: "save"), Expectation("Save Button")),
            .activate(nil),
        ])
    }
}

@Suite struct WalkProblemTests {
    private func walk(_ stops: [String], reachedEnd: Bool, loopsBackTo: Int?) throws -> RunnerClient.Walk {
        var json: [String: Any] = ["stops": stops, "reachedEnd": reachedEnd]
        if let loopsBackTo { json["loopsBackTo"] = loopsBackTo }
        return try JSONDecoder().decode(RunnerClient.Walk.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func describesALoop() throws {
        let problem = ScenarioRunner.walkProblem(try walk(
            ["PAUSED", "RESUME Button", "RETRY Button", "QUIT Button", "0"], reachedEnd: false, loopsBackTo: 0))
        #expect(problem?.contains(#"after "0", swiping on returns to "PAUSED" (stop 1)"#) == true)
    }

    @Test func flagsAWalkThatNeverEnds() throws {
        let problem = ScenarioRunner.walkProblem(try walk(["A", "B"], reachedEnd: false, loopsBackTo: nil))
        #expect(problem?.contains("didn't reach the end") == true)
    }

    @Test func acceptsANormalWalk() throws {
        #expect(ScenarioRunner.walkProblem(try walk(["A", "B"], reachedEnd: true, loopsBackTo: nil)) == nil)
    }
}

@Suite struct ExpectationMatchingTests {
    @Test func ignoresVoiceOverSpacingBeforePunctuation() {
        let speech = "Toppings , Fresh Basil , and 2 more Button"
        #expect(Expectation("Toppings, Fresh Basil, and 2 more").matches(speech))
        #expect(Expectation("Toppings , Fresh").matches("Toppings, Fresh Button"))
    }

    @Test func stillRejectsDifferentText() {
        #expect(!Expectation("Toppings, Olive").matches("Toppings , Fresh Basil"))
    }

    @Test func leavesRegularExpressionsAlone() {
        #expect(!Expectation("/^Toppings, Fresh/").matches("Toppings , Fresh"))
    }
}
