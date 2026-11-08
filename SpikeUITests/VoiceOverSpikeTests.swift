import XCTest

/// Feasibility spike for XCUIVoiceOverService (iOS 27). Each test answers one question:
///
///   1. Can the service enable VoiceOver and report speech here (Simulator or device)?
///   2. Does moveForward/moveBackward follow the expected order on a static screen?
///   3. With VoiceOver on, does an XCUI tap() still activate a control?
///   4. Does currentSpeech() reflect focus the app moves itself (UIKit .layoutChanged,
///      SwiftUI @AccessibilityFocusState)?
///
/// Every utterance is printed with a `VOSPIKE` prefix and attached as an activity,
/// so results can be read from the xcodebuild log or the .xcresult.
@MainActor
final class VoiceOverSpikeTests: XCTestCase {
    private var vo: XCUIVoiceOverService { XCUIDevice.shared.voiceOverService }

    /// Pause between VoiceOver moves, for readable logs. test2b checks whether moves
    /// with no pause also work.
    private let pace: TimeInterval = 0.75

    // MARK: 1. Service availability

    func test1_enablesAndSpeaks() throws {
        _ = try launch(.static)
        XCTAssertTrue(vo.isEnabled, "VoiceOver should report enabled after enable()")
        let speech = try record("current") { try vo.currentSpeech() }
        XCTAssertFalse(speech.isEmpty)
        print("VOSPIKE debugDescription: \(vo.debugDescription)")
    }

    // MARK: 2. Navigation order

    func test2_moveForwardFollowsKnownOrder() throws {
        _ = try launch(.static)
        var heard = [try record("start") { try vo.currentSpeech() }]
        for step in 1...4 {
            heard.append(try record("forward \(step)") { try vo.moveForward() })
            settle(pace)
        }
        var back = ""
        for step in 1...4 {
            back = try record("backward \(step)") { try vo.moveBackward() }
            settle(pace)
        }
        heard.append(back)

        let expected = ["Static Order", "One", "Two", "Three"]
        let positions = expected.map { word in heard.firstIndex { $0.contains(word) } }
        XCTAssertFalse(positions.contains(nil), "Missing expected element. Heard: \(heard)")
        let found = positions.compactMap { $0 }
        XCTAssertEqual(found, found.sorted(), "Order differs from \(expected). Heard: \(heard)")
        XCTAssertTrue(back.contains("Static Order"), "moveBackward never reached the heading; ended on \"\(back)\"")
    }

    /// Same walk with no pause between moves, to measure whether fast moves get dropped.
    func test2b_unpacedMovesForComparison() throws {
        _ = try launch(.static)
        for step in 1...4 {
            try record("fast forward \(step)") { try vo.moveForward() }
        }
    }

    // MARK: 3. Activation with VoiceOver on

    func test3_tapActivatesWithVoiceOverOn() throws {
        let app = try launch(.counter)
        app.buttons["increment"].tap()
        settle(pace)
        try record("after tap") { try vo.currentSpeech() }
        print("VOSPIKE [\(name)] tap activated: \(app.staticTexts["Count: 1"].exists)")

        app.buttons["increment"].doubleTap()
        let activated = app.staticTexts["Count: 1"].waitForExistence(timeout: 3)
            || app.staticTexts["Count: 2"].exists
        settle(pace)
        try record("after doubleTap") { try vo.currentSpeech() }
        XCTAssertTrue(activated, "doubleTap() did not activate the button while VoiceOver was on")
    }

    // MARK: 4. Programmatic focus

    func test4a_uikitLayoutChangedMovesFocus() throws {
        let app = try launch(.uikitBanner)
        try moveFocus(to: "Save")
        app.buttons["save"].doubleTap()
        XCTAssertTrue(app.staticTexts["banner"].waitForExistence(timeout: 3))
        let landed = try waitForSpeech(containing: "Saved successfully")
        XCTAssertTrue(landed.contains("Saved successfully"),
                      "Expected focus on the banner after .layoutChanged; heard \"\(landed)\"")
    }

    // MARK: 6. Which notification APIs VoiceOver honors

    func test6a_uikitPostLayoutChanged() throws {
        try checkBanner(api: "uikit-layout", expect: "Saved successfully")
    }

    func test6b_uikitPostScreenChanged() throws {
        try checkBanner(api: "uikit-screen", expect: "Saved successfully")
    }

    func test6c_accessibilityNotificationLayoutChanged() throws {
        try checkBanner(api: "notification-layout", expect: "Saved successfully")
    }

    func test6d_accessibilityNotificationScreenChanged() throws {
        try checkBanner(api: "notification-screen", expect: "Saved successfully")
    }

    func test6e_accessibilityNotificationAnnouncement() throws {
        try checkBanner(api: "announcement", expect: "Profile saved")
    }

    /// Opens the banner scenario with the given API, activates Save the way a VoiceOver
    /// user would, and checks VoiceOver says `expect` within 3 seconds.
    private func checkBanner(api: String, expect: String) throws {
        let app = try launch(.uikitBanner, extraArguments: ["-VOFocusAPI", api])
        try moveFocus(to: "Save")
        app.buttons["save"].doubleTap()
        XCTAssertTrue(app.staticTexts["banner"].waitForExistence(timeout: 3))
        let started = Date()
        let heard = try waitForSpeech(containing: expect, timeout: 8)
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        print("VOSPIKE [\(name)] RESULT after \(seconds)s api=\(api) \(heard.contains(expect) ? "HONORED" : "IGNORED"): \(heard)")
        XCTAssertTrue(heard.contains(expect), "\(api): expected \"\(expect)\"; heard \"\(heard)\"")
    }

    func test4b_swiftUIAccessibilityFocusStateMovesFocus() throws {
        let app = try launch(.swiftuiError)
        try moveFocus(to: "Submit")
        app.buttons["submit"].doubleTap()
        XCTAssertTrue(app.staticTexts["error"].waitForExistence(timeout: 3))
        let landed = try waitForSpeech(containing: "Name is required")
        XCTAssertTrue(landed.contains("Name is required"),
                      "Expected focus on the error after @AccessibilityFocusState; heard \"\(landed)\"")
    }

    // MARK: 5. What speech capture includes (measurement, not pass/fail)

    /// Records traits, hints, values, value-change announcements and the length cap
    /// on the `traits` scenario. Every utterance is printed with its length.
    func test5_measureSpeechCapture() throws {
        let app = try launch(.traits)

        for step in 1...6 {
            try measure("forward \(step)") { try vo.moveForward() }
        }

        // The toggle: land on it, change it, move away and come back.
        let toggle = app.switches["toggle"]
        toggle.tap()
        settle(pace)
        try measure("toggle focused") { try vo.currentSpeech() }
        let before = toggle.value as? String ?? "?"
        toggle.doubleTap()
        settle(1.5)
        let after = toggle.value as? String ?? "?"
        print("VOSPIKE [\(name)] toggle value \(before) -> \(after) after doubleTap")
        try measure("after toggle change") { try vo.currentSpeech() }
        try measure("away") { try vo.moveForward() }
        settle(pace)
        try measure("back on toggle") { try vo.moveBackward() }

        // The 690-character label: where does the capture stop?
        app.buttons["long"].tap()
        settle(1.5)
        let long = try measure("long label") { try vo.currentSpeech() }
        XCTAssertFalse(long.isEmpty)
    }

    // MARK: - Helpers

    /// Like record(), but also prints the utterance's length.
    @discardableResult
    private func measure(_ step: String, _ call: () throws -> XCUIVoiceOverService.Output) throws -> String {
        let utterance = try call().utterance
        print("VOSPIKE [\(name)] \(step) (len \(utterance.count)): \(utterance)")
        return utterance
    }

    private enum DemoScenario: String {
        case `static`, counter
        case uikitBanner = "uikit-banner"
        case swiftuiError = "swiftui-error"
        case traits
    }

    private func launch(_ scenario: DemoScenario, extraArguments: [String] = []) throws -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-VOScenario", scenario.rawValue] + extraArguments
        app.launch()
        if !vo.isEnabled {
            try vo.enable()
        }
        addTeardownBlock { @MainActor in
            try? XCUIDevice.shared.voiceOverService.disable()
        }
        try waitUntilVoiceOverSpeaks()
        return app
    }

    /// VoiceOver takes a while to start and land in the app; until then every call
    /// throws `noSpeech`. Retry until it says something, and log how long that took.
    private func waitUntilVoiceOverSpeaks(timeout: TimeInterval = 20) throws {
        let start = Date()
        while true {
            do {
                let speech = try vo.currentSpeech().utterance
                if speech == "VoiceOver on" {
                    throw XCUIVoiceOverService.Error(.noSpeech)
                }
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
                print("VOSPIKE [\(name)] ready after \(elapsed)s: \(speech)")
                // VoiceOver can still pull focus back to its first landing for a moment
                // after it first speaks; moves made then are undone.
                settle(1.5)
                return
            } catch let error as XCUIVoiceOverService.Error where error.code == .noSpeech {
                guard Date().timeIntervalSince(start) < timeout else { throw error }
                settle(0.5)
            }
        }
    }

    /// Runs a VoiceOver call, logs its utterance and returns it.
    @discardableResult
    private func record(_ step: String, _ call: () throws -> XCUIVoiceOverService.Output) throws -> String {
        let utterance = try call().utterance
        print("VOSPIKE [\(name)] \(step): \(utterance)")
        XCTContext.runActivity(named: "\(step): \(utterance)") { _ in }
        return utterance
    }

    /// Steps VoiceOver forward until it's on an element whose speech contains `text`,
    /// the way a user would swipe to a button before activating it.
    private func moveFocus(to text: String, maxSteps: Int = 10) throws {
        if try record("start") { try vo.currentSpeech() }.contains(text) { return }
        for step in 1...maxSteps {
            if try record("seek \(step)") { try vo.moveForward() }.contains(text) { return }
            settle(pace)
        }
        XCTFail("Never reached an element containing \"\(text)\" in \(maxSteps) steps")
    }

    /// Polls currentSpeech() until it contains `text` or the timeout passes, and
    /// returns the last utterance either way.
    private func waitForSpeech(containing text: String, timeout: TimeInterval = 3) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        repeat {
            do {
                last = try record("landed?") { try vo.currentSpeech() }
                if last.contains(text) { return last }
            } catch let error as XCUIVoiceOverService.Error where error.code == .noSpeech {
                print("VOSPIKE [\(name)] landed?: <noSpeech>")
            }
            settle(0.25)
        } while Date() < deadline
        return last
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
