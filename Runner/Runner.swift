import XCTest

/// Turns HTTP requests into XCUI and VoiceOver calls. Runs on the main thread only.
///
/// What the spike taught (see SpikeUITests):
/// - With VoiceOver on, a single tap only moves VoiceOver focus; a double tap activates.
/// - VoiceOver needs a moment after it first speaks, or it pulls focus back.
/// - `currentSpeech()` is the last thing VoiceOver said, not a fresh description.
@MainActor
final class Runner {
    private(set) var shouldStop = false
    private var app: XCUIApplication?
    private var bundleId: String?
    private var vo: XCUIVoiceOverService { XCUIDevice.shared.voiceOverService }

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        do {
            return try route(request)
        } catch let error as RunnerError {
            return error.response
        } catch let error as XCUIVoiceOverService.Error {
            return .error(error.codeName, error.localizedDescription, status: 409)
        } catch let error as DecodingError {
            return .error("badRequest", "invalid JSON body: \(error)", status: 400)
        } catch {
            return .error("internal", String(describing: error), status: 500)
        }
    }

    func tearDown() {
        try? disableVoiceOver()
    }

    private func route(_ request: HTTPRequest) throws -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/status"):
            return .json(Status(bundleId: bundleId, voiceOver: vo.isEnabled))

        case ("POST", "/session"):
            return .json(try startSession(decode(SessionRequest.self, from: request)))

        case ("POST", "/vo/enable"):
            try enableVoiceOver()
            return .json(Speech(utterance: try waitForNewSpeech(after: nil, timeout: 20)))

        case ("POST", "/vo/disable"):
            try disableVoiceOver()
            return .json(OK())

        case ("GET", "/vo/current"):
            return .json(try currentSpeech(
                containing: request.query["contains"],
                timeout: request.query["timeout"].flatMap(Double.init) ?? 3))

        case ("POST", "/vo/next"):
            return .json(Speech(utterance: try vo.moveForward().utterance))

        case ("POST", "/vo/previous"):
            return .json(Speech(utterance: try vo.moveBackward().utterance))

        case ("POST", "/vo/in"):
            return .json(Speech(utterance: try vo.moveIn().utterance))

        case ("POST", "/vo/out"):
            return .json(Speech(utterance: try vo.moveOut().utterance))

        case ("POST", "/vo/walk"):
            return .json(try walk(decode(WalkRequest.self, from: request)))

        case ("POST", "/vo/focus"):
            // With VoiceOver on, a single tap on an element moves VoiceOver focus to it.
            let query = try decode(QueryRequest.self, from: request).element
            let element = try ElementLookup.resolve(query, in: requireApp())
            return .json(Speech(utterance: try moveFocus(to: element, query: query)))

        case ("POST", "/vo/activate"):
            // XCUI can't send a real VoiceOver double tap: doubleTap() and
            // tap(withNumberOfTaps:) activate the element under the tap and ignore
            // VoiceOver focus. So activate the element VoiceOver is on, and when an
            // element is given, move VoiceOver focus to it first, as a user would.
            let app = try requireApp()
            let target: XCUIElement
            if let query = try decode(OptionalQueryRequest.self, from: request).element {
                target = try ElementLookup.resolve(query, in: app)
                if vo.isEnabled {
                    _ = try moveFocus(to: target, query: query)
                }
                try requireHittable(target, query)
            } else {
                target = try focusedElement(in: app)
                try requireHittable(target, ElementQuery(label: target.label))
            }
            target.doubleTap()
            return .json(OK())

        case ("POST", "/tap"):
            let query = try decode(QueryRequest.self, from: request).element
            let element = try ElementLookup.resolve(query, in: requireApp())
            try requireHittable(element, query)
            element.tap()
            guard vo.isEnabled else { return .json(OK()) }
            return .json(Noted(note: "VoiceOver is on, so this tap only moved VoiceOver focus to the element; it didn't activate it. Use /vo/activate to activate."))

        case ("POST", "/doubleTap"):
            let query = try decode(QueryRequest.self, from: request).element
            let element = try ElementLookup.resolve(query, in: requireApp())
            try requireHittable(element, query)
            element.doubleTap()
            return .json(OK())

        case ("POST", "/type"):
            let body = try decode(TypeRequest.self, from: request)
            let app = try requireApp()
            if let query = body.element {
                let element = try ElementLookup.resolve(query, in: app)
                try requireHittable(element, query)
                element.typeText(body.text)
            } else {
                app.typeText(body.text)
            }
            return .json(OK())

        case ("GET", "/tree"):
            return .json(try ElementLookup.tree(of: requireApp()))

        case ("POST", "/shutdown"):
            shouldStop = true
            return .json(OK())

        default:
            throw RunnerError.notFound("\(request.method) \(request.path)")
        }
    }

    // MARK: - Session

    /// Launches (or relaunches) the app.
    ///
    /// VoiceOver is turned on once per runner and then left on. Turning it off and on
    /// again within one runner breaks it: `isEnabled` stays true, but speech stops
    /// and every move fails with "Failed to send navigation command", whatever the
    /// gap between toggles. Only a Simulator restart recovers it.
    ///
    /// The cost: when the app relaunches with VoiceOver already on, VoiceOver says
    /// nothing on landing, so `utterance` is only reported for the first session.
    private func startSession(_ request: SessionRequest) throws -> SessionInfo {
        let wantsVoiceOver = request.voiceOver ?? true
        // iOS 27.2 fixed the toggle bug, so there each session turns VoiceOver off and
        // on around the launch, and every session reports where VoiceOver landed.
        if !wantsVoiceOver || Self.toggleIsReliable {
            try disableVoiceOver()
        }

        let app = XCUIApplication(bundleIdentifier: request.bundleId)
        app.launchArguments = request.arguments ?? []
        app.launchEnvironment = request.environment ?? [:]
        app.launch()
        self.app = app
        bundleId = request.bundleId

        guard wantsVoiceOver else {
            return SessionInfo(bundleId: request.bundleId, voiceOver: false, readyAfter: nil, utterance: nil)
        }

        let start = Date()
        var utterance: String?
        var note: String?
        if vo.isEnabled {
            // Relaunch with VoiceOver on: VoiceOver lands on the first element but
            // doesn't speak it, and currentSpeech() still returns older speech (often
            // the status bar clock). So wait for the app, give VoiceOver time to land,
            // and report no utterance rather than a stale one.
            _ = app.wait(for: .runningForeground, timeout: 10)
            settle(2.0)
        } else {
            try enableVoiceOver()
            // On landing in the app, VoiceOver says the app's name first. Waiting for
            // that skips stray speech such as the status bar clock.
            let appName = app.label
            do {
                utterance = try waitForNewSpeech(after: nil, timeout: 20) {
                    appName.isEmpty || $0.hasPrefix(appName)
                }
            } catch let error as XCUIVoiceOverService.Error where error.code == .noSpeech {
                // The app can launch fine without VoiceOver announcing it, for example
                // right after the app was killed. That's no reason to fail the session.
                note = "VoiceOver didn't announce \(appName.isEmpty ? "the app" : appName) within 20 s, so where it landed is unknown. Use /vo/current or /vo/walk to find out."
            }
            // VoiceOver can still pull focus back to its first landing for a moment.
            settle(1.5)
        }
        guard app.state == .runningForeground else {
            throw RunnerError.appNotRunning(request.bundleId)
        }
        let readyAfter = Date().timeIntervalSince(start)
        return SessionInfo(bundleId: request.bundleId, voiceOver: true,
                           readyAfter: (readyAfter * 10).rounded() / 10, utterance: utterance,
                           appName: app.label.isEmpty ? nil : app.label, note: note)
    }

    /// Turning VoiceOver off and on again within one test process breaks it on iOS 27.0
    /// but works on iOS 27.2 (tested on the 27.2 Simulator: four cycles, all clean).
    static let toggleIsReliable = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0))

    /// When VoiceOver was last turned off; enabling again too soon breaks it.
    private var disabledAt: Date?
    private static let toggleCooldown: TimeInterval = 3

    private func enableVoiceOver() throws {
        guard !vo.isEnabled else { return }
        if let disabledAt {
            let wait = Self.toggleCooldown - Date().timeIntervalSince(disabledAt)
            if wait > 0 { settle(wait) }
        }
        try vo.enable()
    }

    private func disableVoiceOver() throws {
        guard vo.isEnabled else { return }
        try vo.disable()
        disabledAt = Date()
    }

    /// VoiceOver's own announcements, which never describe an element.
    private static let systemAnnouncements: Set<String> = ["VoiceOver on", "VoiceOver off"]

    /// Waits until VoiceOver says something new: not a system announcement, not
    /// `previous`, and accepted by `isWanted`. If nothing new comes (for example a
    /// relaunch of the same screen says exactly what it said before), returns the
    /// last acceptable speech once the timeout passes.
    private func waitForNewSpeech(
        after previous: String?, timeout: TimeInterval,
        where isWanted: (String) -> Bool = { _ in true }
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last: String?
        repeat {
            do {
                let speech = try vo.currentSpeech().utterance
                if !Self.systemAnnouncements.contains(speech), isWanted(speech) {
                    if speech != previous { return speech }
                    last = speech
                }
            } catch let error as XCUIVoiceOverService.Error where error.code == .noSpeech {
                // Not speaking yet.
            }
            settle(0.25)
        } while Date() < deadline
        if let last { return last }
        throw XCUIVoiceOverService.Error(.noSpeech)
    }

    // MARK: - Speech

    /// Returns what VoiceOver last said. With `containing`, keeps polling until the
    /// speech contains that text, which is how to observe focus the app moves itself.
    private func currentSpeech(containing expected: String?, timeout: TimeInterval) throws -> Speech {
        guard let expected else {
            return Speech(utterance: try vo.currentSpeech().utterance)
        }
        let deadline = Date().addingTimeInterval(timeout)
        var last: String?
        repeat {
            do {
                let utterance = try vo.currentSpeech().utterance
                if Self.speech(utterance, contains: expected) {
                    return Speech(utterance: utterance)
                }
                last = utterance
            } catch let error as XCUIVoiceOverService.Error where error.code == .noSpeech {
                // Keep waiting.
            }
            settle(0.25)
        } while Date() < deadline
        throw RunnerError.speechTimeout(expected: expected, last: last)
    }

    private func walk(_ request: WalkRequest) throws -> WalkResult {
        let backward: Bool
        switch request.direction ?? "next" {
        case "next": backward = false
        case "previous": backward = true
        case let other: throw RunnerError.badRequest("direction must be next or previous, not \(other)")
        }

        let limit = request.max ?? 50
        let forward = { try (backward ? self.vo.moveBackward() : self.vo.moveForward()).utterance }
        let rewind = { try (backward ? self.vo.moveForward() : self.vo.moveBackward()).utterance }

        /// Moves once. A repeat normally means the edge of the screen, but VoiceOver
        /// occasionally swallows a move (it did right after a session started on the
        /// iOS 27.2 Simulator), so a repeat gets one retry after a pause.
        func step(_ move: () throws -> String, from previous: String) throws -> (String, atEdge: Bool) {
            let utterance = try move()
            guard Self.isSameElement(previous, utterance) else { return (utterance, false) }
            settle(0.5)
            let retry = try move()
            return Self.isSameElement(previous, retry) ? (retry, true) : (retry, false)
        }

        var stops: [String]
        switch request.from ?? "start" {
        case "start":
            // Rewind to the first (or last) element, so the result doesn't depend on
            // currentSpeech(), which can be stale.
            // If focus loops there's no first element; the forward walk reports the loop.
            var rewound = [try rewind()]
            for _ in 0..<limit {
                let (next, atEdge) = try step(rewind, from: rewound.last!)
                if atEdge { break }
                rewound.append(next)
                if Self.loopStart(in: rewound) != nil { break }
            }
            stops = [rewound.last!]
        case "current":
            stops = [try vo.currentSpeech().utterance]
        case let other:
            throw RunnerError.badRequest("from must be start or current, not \(other)")
        }

        for _ in 0..<limit {
            // At the first or last element VoiceOver stays put and repeats it.
            let (utterance, atEdge) = try step(forward, from: stops.last ?? "")
            if atEdge {
                return WalkResult(stops: stops, reachedEnd: true)
            }
            stops.append(utterance)
            if let start = Self.loopStart(in: stops) {
                // Drop the repeated run: moving on from the last kept stop returns to stops[start].
                return WalkResult(stops: Array(stops.dropLast(Self.loopWindow)), reachedEnd: false,
                                  loopsBackTo: start)
            }
        }
        return WalkResult(stops: stops, reachedEnd: false)
    }

    /// How many stops in a row must repeat before a walk counts as a loop. Four keeps
    /// legitimately repeated content (rows with identical buttons) from looking like a
    /// loop, while still catching short cycles such as A, B, A, B.
    static let loopWindow = 4

    /// If the last `loopWindow` stops repeat an earlier run of stops, returns where that
    /// earlier run starts.
    static func loopStart(in stops: [String]) -> Int? {
        let count = stops.count
        guard count > loopWindow else { return nil }
        let tail = stops[(count - loopWindow)...]
        for start in 0..<(count - loopWindow) {
            let run = stops[start..<(start + loopWindow)]
            if zip(run, tail).allSatisfy({ isSameElement($0, $1) }) { return start }
        }
        return nil
    }

    static func isSameElement(_ a: String, _ b: String) -> Bool {
        let a = normalized(a), b = normalized(b)
        return a == b || a.hasPrefix(b + " ") || b.hasPrefix(a + " ")
    }

    /// VoiceOver's speech spaces punctuation differently from the label it reads
    /// ("Toppings , Fresh" for the label "Toppings, Fresh"), so comparisons drop
    /// spaces before punctuation and collapse runs of whitespace on both sides.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" ([,.;:!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func speech(_ speech: String, contains text: String) -> Bool {
        normalized(speech).contains(normalized(text))
    }

    // MARK: - Helpers

    /// Tapping an element XCUI can't hit (such as one laid out off screen) records an
    /// XCTest failure that ends the runner's test, and so does asking `isHittable`. So
    /// decide from the frame instead: tappable if its center is on screen.
    private func canTap(_ element: XCUIElement) -> Bool {
        let frame = element.frame
        guard !frame.isNull, !frame.isEmpty, let app else { return false }
        return app.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    private func requireHittable(_ element: XCUIElement, _ query: ElementQuery) throws {
        guard canTap(element) else {
            throw RunnerError.notHittable(query, frame: element.frame)
        }
    }

    /// Moves VoiceOver focus to an element: with a tap when the element can be tapped
    /// (a single tap with VoiceOver on moves focus), otherwise by swiping through the
    /// screen as a VoiceOver user would, until VoiceOver says the element's label.
    private func moveFocus(to element: XCUIElement, query: ElementQuery) throws -> String {
        if canTap(element) {
            let before = try? vo.currentSpeech().utterance
            element.tap()
            return try waitForNewSpeech(after: before, timeout: 3)
        }
        let label = element.label
        guard !label.isEmpty else { throw RunnerError.notHittable(query, frame: element.frame) }
        var last = try vo.moveBackward().utterance
        for _ in 0..<80 {
            let speech = try vo.moveBackward().utterance
            if Self.isSameElement(last, speech) { break }
            last = speech
        }
        if Self.speech(last, contains: label) { return last }
        for _ in 0..<80 {
            let speech = try vo.moveForward().utterance
            if Self.speech(speech, contains: label) { return speech }
            if Self.isSameElement(last, speech) { break }
            last = speech
        }
        throw RunnerError.notReachable(query)
    }

    /// Finds the element VoiceOver is on by matching its last speech against labels
    /// in the UI tree. XCUI has no "VoiceOver-focused element" query, and only an
    /// element's own doubleTap() activates while VoiceOver is on (app- or
    /// coordinate-level double taps don't).
    private func focusedElement(in app: XCUIApplication) throws -> XCUIElement {
        let speech = try vo.currentSpeech().utterance
        let appPrefix = app.label + " "
        let spoken = Self.normalized(speech.hasPrefix(appPrefix) ? String(speech.dropFirst(appPrefix.count)) : speech)

        // The longest label that the speech starts with, followed by nothing or a
        // space (the trait, e.g. "One Button").
        var best: (label: String, type: XCUIElement.ElementType)?
        func visit(_ node: any XCUIElementSnapshot) {
            let label = Self.normalized(node.label)
            if !label.isEmpty, node.elementType != .application,
               spoken == label || spoken.hasPrefix(label + " "),
               label.count > (best.map { Self.normalized($0.label).count } ?? 0) {
                // Keep the real label: the query below matches it exactly.
                best = (node.label, node.elementType)
            }
            node.children.forEach(visit)
        }
        visit(try app.snapshot())

        guard let best else {
            throw RunnerError.focusUnresolved(speech)
        }
        return app.descendants(matching: best.type)
            .matching(NSPredicate(format: "label == %@", best.label)).firstMatch
    }

    private func requireApp() throws -> XCUIApplication {
        guard let app else { throw RunnerError.noSession }
        return app
    }

    private func decode<T: Decodable>(_ type: T.Type, from request: HTTPRequest) throws -> T {
        let body = request.body.isEmpty ? Data("{}".utf8) : request.body
        return try JSONDecoder().decode(type, from: body)
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }
}
