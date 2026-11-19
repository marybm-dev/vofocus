import Foundation

/// Finds one element in the app, as the runner's element queries do.
public struct ElementQuery: Codable, Sendable, Equatable, CustomStringConvertible {
    public var identifier: String?
    public var label: String?
    public var type: String?
    public var index: Int?
    public var timeout: Double?

    public init(identifier: String? = nil, label: String? = nil, type: String? = nil,
                index: Int? = nil, timeout: Double? = nil) {
        self.identifier = identifier
        self.label = label
        self.type = type
        self.index = index
        self.timeout = timeout
    }

    public var description: String {
        [identifier.map { "#\($0)" }, label.map { "\"\($0)\"" }, type, index.map { "[\($0)]" }]
            .compactMap { $0 }.joined(separator: " ")
    }
}

/// An error the runner returned, such as elementNotFound or speechTimeout.
public struct RunnerFailure: Error, CustomStringConvertible, Sendable {
    public let status: Int
    public let code: String
    public let message: String

    public var description: String { "\(code): \(message)" }
}

/// Typed calls to the runner's HTTP API.
extension RunnerClient {
    public struct Session: Decodable, Sendable {
        public let readyAfter: Double?
        /// Where VoiceOver landed, including the app name; nil when not reported.
        public let utterance: String?
        public let appName: String?
        /// Set when the launch worked but something is worth knowing, such as an
        /// unknown landing.
        public let note: String?

        /// The landing without the app name VoiceOver says first.
        public var landing: String? {
            guard let utterance else { return nil }
            if let appName, utterance.hasPrefix(appName + " ") {
                return String(utterance.dropFirst(appName.count + 1))
            }
            return utterance
        }
    }

    public struct Speech: Decodable, Sendable {
        public let utterance: String
    }

    public struct Walk: Decodable, Sendable {
        public let stops: [String]
        public let reachedEnd: Bool
        /// Set when focus loops: moving on from the last stop returns to stops[loopsBackTo].
        public let loopsBackTo: Int?
    }

    public func launch(bundleId: String, arguments: [String] = [], environment: [String: String] = [:]) async throws -> Session {
        struct Body: Encodable { let bundleId: String; let arguments: [String]; let environment: [String: String] }
        return try await call("POST", "/session", body: Body(bundleId: bundleId, arguments: arguments, environment: environment))
    }

    /// The whole focus order, from the first element.
    public func walk(max: Int = 50) async throws -> Walk {
        struct Body: Encodable { let from = "start"; let max: Int }
        return try await call("POST", "/vo/walk", body: Body(max: max))
    }

    /// One VoiceOver move: "next", "previous", "in" or "out".
    public func move(_ direction: String) async throws -> Speech {
        try await call("POST", "/vo/\(direction)", body: Optional<Int>.none)
    }

    /// What VoiceOver last said.
    public func currentSpeech() async throws -> Speech {
        try await call("GET", "/vo/current", body: Optional<Int>.none)
    }

    public func focus(_ element: ElementQuery) async throws -> Speech {
        struct Body: Encodable { let element: ElementQuery }
        return try await call("POST", "/vo/focus", body: Body(element: element))
    }

    /// Returns each new thing VoiceOver said while activating, in order (empty from
    /// a runner older than this, or with VoiceOver off).
    @discardableResult
    public func activate(_ element: ElementQuery?) async throws -> [String] {
        struct Body: Encodable { let element: ElementQuery? }
        let result: Heard = try await call("POST", "/vo/activate", body: Body(element: element))
        return result.heard ?? []
    }

    public struct SwipeResult: Decodable, Sendable {
        /// What VoiceOver said after the swipe: an adjustable element's new value, or
        /// the next custom action.
        public let utterance: String?
        /// The element's accessibility value afterwards, when an element was given.
        public let value: String?
    }

    /// A one-finger swipe up or down, which VoiceOver interprets: increment or
    /// decrement an adjustable element, or read the next custom action.
    public func swipe(_ direction: String, element: ElementQuery?) async throws -> SwipeResult {
        struct Body: Encodable { let direction: String; let element: ElementQuery? }
        return try await call("POST", "/swipe", body: Body(direction: direction, element: element))
    }

    /// Returns what VoiceOver said during a double tap, as activate does.
    @discardableResult
    public func tap(_ element: ElementQuery, double: Bool = false) async throws -> [String] {
        struct Body: Encodable { let element: ElementQuery }
        let result: Heard = try await call("POST", double ? "/doubleTap" : "/tap", body: Body(element: element))
        return result.heard ?? []
    }

    /// Returns what VoiceOver said while typing, as activate does.
    @discardableResult
    public func type(_ text: String, into element: ElementQuery?) async throws -> [String] {
        struct Body: Encodable { let text: String; let element: ElementQuery? }
        let result: Heard = try await call("POST", "/type", body: Body(text: text, element: element))
        return result.heard ?? []
    }

    /// Speech the runner collected during a call (missing from older runners).
    private struct Heard: Decodable { let heard: [String]? }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let code: String; let message: String }
        let error: Detail
    }

    private func call<Body: Encodable, Result: Decodable>(
        _ method: String, _ path: String, body: Body?
    ) async throws -> Result {
        let data = try body.map { try JSONEncoder().encode($0) }
        let response = try await send(method, path, body: data)
        guard response.ok else {
            let detail = try? JSONDecoder().decode(ErrorBody.self, from: response.body).error
            throw RunnerFailure(status: response.status, code: detail?.code ?? "http\(response.status)",
                                message: detail?.message ?? response.text)
        }
        return try JSONDecoder().decode(Result.self, from: response.body)
    }
}
