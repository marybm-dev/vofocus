import Foundation
import VOFocusKit

/// What happened to one step.
public struct StepResult: Sendable {
    public enum Outcome: Sendable { case passed, failed, notRun }
    public let step: Step
    public let outcome: Outcome
    /// What VoiceOver said, or why the step failed.
    public let detail: String
    /// What VoiceOver actually said, for record mode: one entry per expectation.
    public let observed: [String]?
    /// When the step started and finished.
    public internal(set) var started: Date?
    public internal(set) var finished: Date?
    /// Everything VoiceOver said while the step ran, when the runner collects it
    /// (activate does). A following `speech` step checks it first.
    public internal(set) var heard: [String]? = nil
}

public struct ScenarioResult: Sendable {
    public let scenario: Scenario
    public let steps: [StepResult]
    public let seconds: Double
    /// Why the scenario was skipped, if it was.
    public let skipped: String?
    /// How many attempts it took (1 unless it was retried).
    public let attempts: Int
    /// When the attempt started (launching the app).
    public let started: Date?

    public init(scenario: Scenario, steps: [StepResult], seconds: Double, skipped: String?, attempts: Int,
                started: Date? = nil) {
        self.started = started
        self.scenario = scenario
        self.steps = steps
        self.seconds = seconds
        self.skipped = skipped
        self.attempts = attempts
    }

    /// A result for a scenario whose app couldn't be launched.
    public static func launchFailed(_ scenario: Scenario, _ reason: String, seconds: Double = 0,
                                    started: Date? = nil) -> ScenarioResult {
        ScenarioResult(
            scenario: scenario,
            steps: [StepResult(step: .wait(0), outcome: .failed, detail: "launch failed: \(reason)", observed: nil)],
            seconds: seconds, skipped: nil, attempts: 1, started: started)
    }

    public var passed: Bool { skipped == nil && steps.allSatisfy { $0.outcome == .passed } }
    public var failure: StepResult? { steps.first { $0.outcome == .failed } }
}

/// Runs scenarios against a runner.
public struct ScenarioRunner: Sendable {
    public let client: RunnerClient

    public init(client: RunnerClient) {
        self.client = client
    }

    /// Runs one attempt. Steps after the first failure aren't run. In `recording`
    /// mode, steps without an expectation still run and report what VoiceOver said.
    public func run(_ scenario: Scenario) async -> ScenarioResult {
        let started = Date()
        var results: [StepResult] = []
        var session: RunnerClient.Session?
        var failed = false

        do {
            session = try await client.launch(
                bundleId: scenario.bundleId, arguments: scenario.arguments, environment: scenario.environment)
        } catch {
            return .launchFailed(scenario, "\(error)", seconds: Date().timeIntervalSince(started), started: started)
        }

        for step in scenario.steps {
            if failed {
                results.append(StepResult(step: step, outcome: .notRun, detail: "", observed: nil))
                continue
            }
            var result: StepResult
            let stepStarted = Date()
            do {
                result = try await run(step, session: session, heardBefore: results.last?.heard ?? [])
            } catch {
                result = StepResult(step: step, outcome: .failed, detail: String(describing: error), observed: nil)
            }
            result.started = stepStarted
            result.finished = Date()
            failed = result.outcome == .failed
            results.append(result)
        }
        return ScenarioResult(scenario: scenario, steps: results, seconds: Date().timeIntervalSince(started),
                              skipped: nil, attempts: 1, started: started)
    }

    private func run(_ step: Step, session: RunnerClient.Session?, heardBefore: [String]) async throws -> StepResult {
        func check(_ expectation: Expectation?, _ speech: String) -> StepResult {
            guard let expectation else {
                return StepResult(step: step, outcome: .passed, detail: speech, observed: [speech])
            }
            return expectation.matches(speech)
                ? StepResult(step: step, outcome: .passed, detail: speech, observed: [speech])
                : StepResult(step: step, outcome: .failed,
                             detail: "expected \(expectation), heard \"\(speech)\"", observed: [speech])
        }

        switch step {
        case .landing(let expectation):
            guard let landing = session?.landing else {
                return StepResult(step: step, outcome: expectation == nil ? .passed : .failed,
                                  detail: session?.note ?? "VoiceOver's landing wasn't reported (iOS 27.0 reports it only for a runner's first launch)",
                                  observed: nil)
            }
            return check(expectation, landing)

        case .walk(let expected):
            let walk = try await client.walk()
            // A loop or a walk that never ends is a bug whatever was expected.
            if let problem = Self.walkProblem(walk) {
                return StepResult(step: step, outcome: .failed, detail: problem, observed: walk.stops)
            }
            guard let expected else {
                return StepResult(step: step, outcome: .passed, detail: walk.stops.joined(separator: " → "),
                                  observed: walk.stops)
            }
            let matches = expected.count == walk.stops.count
                && zip(expected, walk.stops).allSatisfy { $0.matches($1) }
            if matches {
                return StepResult(step: step, outcome: .passed, detail: walk.stops.joined(separator: " → "),
                                  observed: walk.stops)
            }
            return StepResult(step: step, outcome: .failed,
                              detail: Self.orderDifference(expected: expected, actual: walk.stops),
                              observed: walk.stops)

        case .next(let expectation):
            return check(expectation, try await client.move("next").utterance)

        case .previous(let expectation):
            return check(expectation, try await client.move("previous").utterance)

        case .current(let expectation):
            return check(expectation, try await client.currentSpeech().utterance)

        case .focus(let element, let expectation):
            return check(expectation, try await client.focus(element).utterance)

        case .activate(let element):
            var result = StepResult(step: step, outcome: .passed, detail: "", observed: nil)
            result.heard = try await client.activate(element)
            return result

        case .speech(let expectation, let timeout):
            // An announcement made while the previous step ran (activating, double tapping
            // and typing block until the app is idle) is usually replaced by VoiceOver's
            // next speech, such as "selected" or "on", before polling could see it.
            if let match = heardBefore.first(where: expectation.matches) {
                return StepResult(step: step, outcome: .passed, detail: "\(match) (while the previous step ran)",
                                  observed: [match])
            }
            // Poll here rather than in the runner so regular expressions work too.
            let deadline = Date().addingTimeInterval(timeout)
            var last = ""
            repeat {
                if let speech = try? await client.currentSpeech().utterance {
                    last = speech
                    if expectation.matches(speech) {
                        return StepResult(step: step, outcome: .passed, detail: speech, observed: [speech])
                    }
                }
                try await Task.sleep(for: .milliseconds(250))
            } while Date() < deadline
            return StepResult(step: step, outcome: .failed,
                              detail: "VoiceOver didn't say \(expectation) within \(timeout)s; last heard \"\(last)\"",
                              observed: [last])

        case .swipe(let direction, let element, let expectation):
            return check(expectation, try await client.swipe(direction, element: element).utterance ?? "")

        case .tap(let element, let double):
            var result = StepResult(step: step, outcome: .passed, detail: "", observed: nil)
            result.heard = try await client.tap(element, double: double)
            return result

        case .type(let text, let element):
            var result = StepResult(step: step, outcome: .passed, detail: "", observed: nil)
            result.heard = try await client.type(text, into: element)
            return result

        case .wait(let seconds):
            try await Task.sleep(for: .seconds(seconds))
            return StepResult(step: step, outcome: .passed, detail: "", observed: nil)
        }
    }

    /// Describes a focus loop, or a walk that ran out of moves, in words.
    static func walkProblem(_ walk: RunnerClient.Walk) -> String? {
        if let start = walk.loopsBackTo, start < walk.stops.count, let last = walk.stops.last {
            let order = walk.stops.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            return """
                focus loops: after "\(last)", swiping on returns to "\(walk.stops[start])" (stop \(start + 1)), \
                so VoiceOver never reaches the end of the screen.
                \(order)
                """
        }
        if !walk.reachedEnd {
            return "the walk didn't reach the end of the screen within \(walk.stops.count) stops: "
                + walk.stops.suffix(6).joined(separator: " → ")
        }
        return nil
    }

    /// A line-by-line comparison of expected and actual focus order.
    static func orderDifference(expected: [Expectation], actual: [String]) -> String {
        var lines = ["focus order differs (expected \(expected.count) stops, VoiceOver made \(actual.count)):"]
        for index in 0..<max(expected.count, actual.count) {
            let want = index < expected.count ? expected[index].description : "(none)"
            let got = index < actual.count ? "\"\(actual[index])\"" : "(none)"
            let ok = index < expected.count && index < actual.count && expected[index].matches(actual[index])
            lines.append("  \(ok ? " " : "✗") \(index + 1). expected \(want), heard \(got)")
        }
        return lines.joined(separator: "\n")
    }
}
