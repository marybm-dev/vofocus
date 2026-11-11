import Foundation
import VOFocusKit
import Yams

/// One check: launch an app, take some steps, and compare what VoiceOver says with
/// what's expected. Loaded from YAML; see scenarios/README.md for the format.
public struct Scenario: Sendable {
    public var name: String
    public var bundleId: String
    /// An .app to install before launching, relative to the scenario file.
    public var install: String?
    public var arguments: [String]
    public var environment: [String: String]
    /// Skip on the Simulator, where focus and announcement checks are unreliable.
    public var deviceOnly: Bool
    /// How many times to rerun the scenario after a failure.
    public var retries: Int
    public var steps: [Step]
    public var file: URL?
}

public enum Step: Sendable, Equatable {
    /// Where VoiceOver landed when the app launched.
    case landing(Expectation?)
    /// The whole focus order from the first element.
    case walk([Expectation]?)
    /// One swipe right or left.
    case next(Expectation?)
    case previous(Expectation?)
    /// What VoiceOver last said, without moving focus: where focus is after an action.
    case current(Expectation?)
    /// Move VoiceOver focus to an element.
    case focus(ElementQuery, Expectation?)
    /// Activate the focused element (or the given one), as a VoiceOver double tap does.
    case activate(ElementQuery?)
    /// Wait until VoiceOver says something.
    case speech(Expectation, timeout: Double)
    case tap(ElementQuery, double: Bool)
    case type(String, ElementQuery?)
    case wait(Double)

    /// A short label for reports.
    public var summary: String {
        switch self {
        case .landing: "landing"
        case .walk: "walk"
        case .next: "next"
        case .previous: "previous"
        case .current: "current"
        case .focus(let element, _): "focus \(element)"
        case .activate(let element): element.map { "activate \($0)" } ?? "activate"
        case .speech(let expectation, _): "speech \(expectation)"
        case .tap(let element, let double): "\(double ? "double tap" : "tap") \(element)"
        case .type(let text, _): "type \"\(text)\""
        case .wait(let seconds): "wait \(seconds)s"
        }
    }
}

/// Expected speech. Plain text matches speech that contains it; text wrapped in
/// slashes (/…/) is a regular expression.
public struct Expectation: Sendable, Equatable, CustomStringConvertible {
    public let text: String

    public init(_ text: String) { self.text = text }

    public var isRegex: Bool { text.count > 2 && text.hasPrefix("/") && text.hasSuffix("/") }

    public func matches(_ speech: String) -> Bool {
        guard isRegex else { return Self.normalized(speech).contains(Self.normalized(text)) }
        let pattern = String(text.dropFirst().dropLast())
        return speech.range(of: pattern, options: .regularExpression) != nil
    }

    public var description: String { "\"\(text)\"" }

    /// VoiceOver's speech spaces punctuation differently from labels ("Toppings ,
    /// Fresh" for "Toppings, Fresh"), so plain matching drops spaces before punctuation
    /// and collapses whitespace on both sides. The runner does the same.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" ([,.;:!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

public struct ScenarioError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    init(_ message: String) { self.message = message }
}

// MARK: - Loading

extension Scenario {
    /// Loads a scenario file. `${NAME}` is replaced with the environment variable NAME.
    public static func load(from url: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Scenario {
        let text = try String(contentsOf: url, encoding: .utf8)
        do {
            var scenario = try parse(substitute(text, environment), environment: environment)
            scenario.file = url
            return scenario
        } catch let error as ScenarioError {
            throw ScenarioError("\(url.lastPathComponent): \(error.message)")
        }
    }

    /// Loads a scenario file without replacing `${NAME}` placeholders, for writing it
    /// back out with the placeholders intact.
    public static func loadTemplate(from url: URL) throws -> Scenario {
        var scenario = try parse(String(contentsOf: url, encoding: .utf8))
        scenario.file = url
        return scenario
    }

    static func substitute(_ text: String, _ environment: [String: String]) throws -> String {
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: "${") {
            result += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].firstIndex(of: "}") else {
                throw ScenarioError("unclosed ${ in the file")
            }
            let name = String(rest[start.upperBound..<end])
            guard let value = environment[name] else {
                throw ScenarioError("environment variable \(name) is not set")
            }
            result += value
            rest = rest[rest.index(after: end)...]
        }
        return result + rest
    }

    public static func parse(_ yaml: String, environment: [String: String] = [:]) throws -> Scenario {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any] else {
            throw ScenarioError("expected a mapping with name, app and steps")
        }
        guard let name = root["name"] as? String else { throw ScenarioError("missing name") }
        guard let app = root["app"] as? [String: Any], let bundleId = app["bundleId"] as? String else {
            throw ScenarioError("missing app.bundleId")
        }
        guard let rawSteps = root["steps"] as? [Any] else { throw ScenarioError("missing steps") }
        let steps = try rawSteps.enumerated().map { index, raw in
            do {
                return try Step.parse(raw)
            } catch let error as ScenarioError {
                throw ScenarioError("step \(index + 1): \(error.message)")
            }
        }
        return Scenario(
            name: name,
            bundleId: bundleId,
            install: app["install"] as? String,
            arguments: (app["arguments"] as? [Any])?.map { "\($0)" } ?? [],
            environment: ((app["environment"] as? [String: Any]) ?? [:]).mapValues { "\($0)" },
            deviceOnly: root["deviceOnly"] as? Bool ?? false,
            retries: root["retries"] as? Int ?? 0,
            steps: steps,
            file: nil)
    }
}

extension Step {
    static func parse(_ raw: Any) throws -> Step {
        guard let map = raw as? [String: Any], map.count == 1, let (kind, value) = map.first else {
            throw ScenarioError("each step is one key, such as `walk:` or `focus: {identifier: save}`")
        }
        switch kind {
        case "landing": return .landing(try expectation(value))
        case "walk":
            if value is NSNull { return .walk(nil) }
            guard let list = value as? [Any] else { throw ScenarioError("walk takes a list of expected stops") }
            return .walk(list.map { Expectation("\($0)") })
        case "next": return .next(try expectation(value))
        case "previous": return .previous(try expectation(value))
        case "current": return .current(try expectation(value))
        case "focus":
            let (element, map) = try elementQuery(value, kind: kind)
            return .focus(element, (map["expect"]).map { Expectation("\($0)") })
        case "activate":
            if value is NSNull { return .activate(nil) }
            let (element, _) = try elementQuery(value, kind: kind)
            return .activate(element)
        case "speech":
            if let text = value as? String { return .speech(Expectation(text), timeout: 3) }
            guard let map = value as? [String: Any], let text = map["expect"] else {
                throw ScenarioError("speech takes text, or {expect: text, timeout: seconds}")
            }
            return .speech(Expectation("\(text)"), timeout: number(map["timeout"]) ?? 3)
        case "tap":
            let (element, map) = try elementQuery(value, kind: kind)
            return .tap(element, double: map["double"] as? Bool ?? false)
        case "type":
            guard let map = value as? [String: Any], let text = map["text"] else {
                throw ScenarioError("type takes {text: …} and optionally an element")
            }
            let hasElement = map.keys.contains { ["identifier", "label", "type"].contains($0) }
            return .type("\(text)", hasElement ? try elementQuery(map, kind: kind).0 : nil)
        case "wait":
            guard let seconds = number(value) else { throw ScenarioError("wait takes seconds") }
            return .wait(seconds)
        default:
            throw ScenarioError("unknown step \"\(kind)\"")
        }
    }

    private static func expectation(_ value: Any) throws -> Expectation? {
        if value is NSNull { return nil }
        if value is [Any] || value is [String: Any] { throw ScenarioError("expected text") }
        return Expectation("\(value)")
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let int as Int: Double(int)
        case let double as Double: double
        default: nil
        }
    }

    private static func elementQuery(_ value: Any, kind: String) throws -> (ElementQuery, [String: Any]) {
        guard let map = value as? [String: Any] else {
            throw ScenarioError("\(kind) takes an element, such as {identifier: save}")
        }
        let query = ElementQuery(
            identifier: map["identifier"].map { "\($0)" },
            label: map["label"].map { "\($0)" },
            type: map["type"] as? String,
            index: map["index"] as? Int,
            timeout: number(map["timeout"]))
        guard query.identifier != nil || query.label != nil || query.type != nil else {
            throw ScenarioError("\(kind) needs an identifier, label or type")
        }
        return (query, map)
    }
}
