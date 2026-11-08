import Foundation
import XCTest

// MARK: - Requests

struct SessionRequest: Decodable {
    let bundleId: String
    var arguments: [String]?
    var environment: [String: String]?
    /// Turn VoiceOver on for this session (default true).
    var voiceOver: Bool?
}

struct QueryRequest: Decodable {
    let element: ElementQuery
}

struct OptionalQueryRequest: Decodable {
    var element: ElementQuery?
}

struct TypeRequest: Decodable {
    let text: String
    var element: ElementQuery?
}

struct WalkRequest: Decodable {
    /// "next" (default) or "previous".
    var direction: String?
    /// Maximum moves before giving up (default 50).
    var max: Int?
    /// "start" (default): rewind to the first element, then walk the whole screen.
    /// "current": walk on from wherever focus is; the first stop is VoiceOver's last
    /// speech, which can be stale right after a relaunch.
    var from: String?
}

/// Finds one element in the app. Every field is optional, but give at least one of
/// identifier or label. `type` is an XCUIElement.ElementType name such as "button".
struct ElementQuery: Decodable, CustomStringConvertible {
    var identifier: String?
    var label: String?
    var type: String?
    var index: Int?
    /// Seconds to wait for the element to exist (default 3).
    var timeout: Double?

    var description: String {
        [identifier.map { "identifier=\($0)" }, label.map { "label=\($0)" },
         type.map { "type=\($0)" }, index.map { "index=\($0)" }]
            .compactMap { $0 }.joined(separator: " ")
    }
}

// MARK: - Responses

struct Speech: Encodable {
    let utterance: String
}

struct SessionInfo: Encodable {
    let bundleId: String
    let voiceOver: Bool
    /// Seconds VoiceOver took to start speaking in the app.
    let readyAfter: Double?
    /// The first thing VoiceOver said, usually the app name and the first element.
    let utterance: String?
}

struct Status: Encodable {
    let ready = true
    let bundleId: String?
    let voiceOver: Bool
}

struct WalkResult: Encodable {
    /// Every stop in order, starting with where focus was.
    let stops: [String]
    /// True if VoiceOver stopped moving (the last element repeated); false if `max` ran out.
    let reachedEnd: Bool
}

struct OK: Encodable {
    let ok = true
}

struct ErrorBody: Encodable {
    struct Detail: Encodable {
        let code: String
        let message: String
    }
    let error: Detail
}

// MARK: - Errors

enum RunnerError: Error {
    case badRequest(String)
    case notFound(String)
    case noSession
    case elementNotFound(ElementQuery)
    case speechTimeout(expected: String, last: String?)
    case focusUnresolved(String)

    var response: HTTPResponse {
        switch self {
        case .badRequest(let message):
            .error("badRequest", message, status: 400)
        case .notFound(let route):
            .error("notFound", "no route for \(route)", status: 404)
        case .noSession:
            .error("noSession", "start a session first: POST /session", status: 409)
        case .elementNotFound(let query):
            .error("elementNotFound", "no element matching \(query)", status: 409)
        case .speechTimeout(let expected, let last):
            .error("speechTimeout", "VoiceOver never said \"\(expected)\"; last heard \"\(last ?? "nothing")\"",
                   status: 409)
        case .focusUnresolved(let speech):
            .error("focusUnresolved",
                   "couldn't match VoiceOver's speech \"\(speech)\" to an element; pass {\"element\": …}",
                   status: 409)
        }
    }
}

extension HTTPResponse {
    static func error(_ code: String, _ message: String, status: Int) -> HTTPResponse {
        .json(ErrorBody(error: .init(code: code, message: message)), status: status)
    }
}

extension XCUIVoiceOverService.Error {
    var codeName: String {
        switch code {
        case .failedToStart: "voiceOverFailedToStart"
        case .notRunning: "voiceOverNotRunning"
        case .noSpeech: "noSpeech"
        case .failedToStop: "voiceOverFailedToStop"
        @unknown default: "voiceOverError"
        }
    }
}
