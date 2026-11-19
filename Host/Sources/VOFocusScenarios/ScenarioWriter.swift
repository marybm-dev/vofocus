import Foundation
import VOFocusKit

/// Writes a scenario back out as YAML, with expectations filled in from a recorded
/// run. Comments in the original file aren't kept.
public enum ScenarioWriter {
    public static func yaml(for scenario: Scenario, recordedFrom result: ScenarioResult? = nil) -> String {
        var lines = ["name: \(quote(scenario.name))", "app:", "  bundleId: \(quote(scenario.bundleId))"]
        if let install = scenario.install { lines.append("  install: \(quote(install))") }
        if !scenario.arguments.isEmpty {
            lines.append("  arguments: [\(scenario.arguments.map(quote).joined(separator: ", "))]")
        }
        if !scenario.environment.isEmpty {
            lines.append("  environment:")
            for (key, value) in scenario.environment.sorted(by: { $0.key < $1.key }) {
                lines.append("    \(key): \(quote(value))")
            }
        }
        if scenario.deviceOnly { lines.append("deviceOnly: true") }
        if scenario.retries > 0 { lines.append("retries: \(scenario.retries)") }
        lines.append("steps:")
        for (index, step) in scenario.steps.enumerated() {
            let observed = result.flatMap { index < $0.steps.count ? $0.steps[index].observed : nil }
            lines.append(contentsOf: yaml(for: step, observed: observed))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func yaml(for step: Step, observed: [String]?) -> [String] {
        func text(_ expectation: Expectation?) -> String {
            if let first = observed?.first { return " " + quote(first) }
            return expectation.map { " " + quote($0.text) } ?? ""
        }
        switch step {
        case .landing(let expectation): return ["  - landing:\(text(expectation))"]
        case .walk(let expected):
            let stops = observed ?? expected?.map(\.text)
            guard let stops else { return ["  - walk:"] }
            return ["  - walk:"] + stops.map { "      - \(quote($0))" }
        case .next(let expectation): return ["  - next:\(text(expectation))"]
        case .previous(let expectation): return ["  - previous:\(text(expectation))"]
        case .current(let expectation): return ["  - current:\(text(expectation))"]
        case .focus(let element, let expectation):
            var fields = elementFields(element)
            if let expect = observed?.first ?? expectation?.text { fields.append("expect: \(quote(expect))") }
            return ["  - focus: {\(fields.joined(separator: ", "))}"]
        case .activate(let element):
            return [element.map { "  - activate: {\(elementFields($0).joined(separator: ", "))}" } ?? "  - activate:"]
        case .speech(let expectation, let timeout):
            return timeout == 3
                ? ["  - speech: \(quote(expectation.text))"]
                : ["  - speech: {expect: \(quote(expectation.text)), timeout: \(format(timeout))}"]
        case .swipe(let direction, let element, let expectation):
            let expect = observed?.first ?? expectation?.text
            guard element != nil || expect != nil else { return ["  - swipe: \(direction)"] }
            var fields = ["direction: \(direction)"] + (element.map(elementFields) ?? [])
            if let expect { fields.append("expect: \(quote(expect))") }
            return ["  - swipe: {\(fields.joined(separator: ", "))}"]
        case .tap(let element, let double):
            var fields = elementFields(element)
            if double { fields.append("double: true") }
            return ["  - tap: {\(fields.joined(separator: ", "))}"]
        case .type(let text, let element):
            let fields = ["text: \(quote(text))"] + (element.map(elementFields) ?? [])
            return ["  - type: {\(fields.joined(separator: ", "))}"]
        case .wait(let seconds): return ["  - wait: \(format(seconds))"]
        }
    }

    static func elementFields(_ element: ElementQuery) -> [String] {
        var fields: [String] = []
        if let identifier = element.identifier { fields.append("identifier: \(quote(identifier))") }
        if let label = element.label { fields.append("label: \(quote(label))") }
        if let type = element.type { fields.append("type: \(type)") }
        if let index = element.index { fields.append("index: \(index)") }
        if let timeout = element.timeout { fields.append("timeout: \(format(timeout))") }
        return fields
    }

    /// Double-quoted YAML string (JSON string syntax is valid YAML).
    static func quote(_ string: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = try? encoder.encode(string)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\(string)\""
    }

    static func format(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }
}
