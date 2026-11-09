import Foundation
import VOFocusScenarios

/// Human-readable output on stdout, plus JUnit XML for CI.
enum Report {
    static func print(_ result: ScenarioResult) {
        let file = result.scenario.file?.lastPathComponent ?? ""
        if let skipped = result.skipped {
            Swift.print("SKIP  \(result.scenario.name) (\(file)): \(skipped)")
            return
        }
        let retried = result.attempts > 1 ? ", \(result.attempts) attempts" : ""
        Swift.print("\(result.passed ? "PASS" : "FAIL")  \(result.scenario.name) (\(file), \(String(format: "%.0f", result.seconds)) s\(retried))")
        for step in result.steps {
            switch step.outcome {
            case .passed:
                let detail = step.detail.isEmpty ? "" : ": \(step.detail)"
                Swift.print("    ✓ \(step.step.summary)\(detail)")
            case .failed:
                Swift.print("    ✗ \(step.step.summary)")
                for line in step.detail.split(separator: "\n") {
                    Swift.print("        \(line)")
                }
            case .notRun:
                Swift.print("    - \(step.step.summary) (not run)")
            }
        }
    }

    static func printSummary(_ results: [ScenarioResult]) {
        let passed = results.filter(\.passed).count
        let skipped = results.filter { $0.skipped != nil }.count
        let failed = results.count - passed - skipped
        Swift.print("\n\(passed) passed, \(failed) failed, \(skipped) skipped")
    }

    static func junit(_ results: [ScenarioResult], target: String) -> String {
        let failures = results.filter { $0.skipped == nil && !$0.passed }.count
        let skipped = results.filter { $0.skipped != nil }.count
        let total = results.reduce(0) { $0 + $1.seconds }
        var xml = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<testsuite name="vofocus (\#(escape(target)))" tests="\#(results.count)" failures="\#(failures)" skipped="\#(skipped)" time="\#(String(format: "%.1f", total))">"#,
        ]
        for result in results {
            let classname = escape(result.scenario.file?.lastPathComponent ?? "scenario")
            let open = #"  <testcase classname="\#(classname)" name="\#(escape(result.scenario.name))" time="\#(String(format: "%.1f", result.seconds))""#
            if let skip = result.skipped {
                xml.append(open + ">")
                xml.append(#"    <skipped message="\#(escape(skip))"/>"#)
                xml.append("  </testcase>")
            } else if let failure = result.failure {
                xml.append(open + ">")
                xml.append(#"    <failure message="\#(escape(failure.step.summary))">\#(escape(failure.detail))</failure>"#)
                xml.append("  </testcase>")
            } else {
                xml.append(open + "/>")
            }
        }
        xml.append("</testsuite>")
        return xml.joined(separator: "\n") + "\n"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
