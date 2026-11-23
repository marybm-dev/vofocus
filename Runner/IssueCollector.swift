import Synchronization
import XCTest

/// Collects the failures XCTest records while the runner handles a request.
///
/// Recorded normally, an XCUI failure such as "Failed to terminate <app>" ends the
/// runner's one test, even with `continueAfterFailure` set, and the runner dies
/// mid-run. RunnerTests sends every failure here instead, so the runner can retry or
/// answer with an error and keep serving.
final class IssueCollector: Sendable {
    static let shared = IssueCollector()

    /// One list per `collect` call in progress; failures go to the innermost.
    private let stack = Mutex<[[String]]>([])

    /// Runs `body` and returns the failures XCTest recorded during it.
    func collect(_ body: () throws -> Void) rethrows -> [String] {
        stack.withLock { $0.append([]) }
        defer { _ = stack.withLock { $0.popLast() } }
        try body()
        return stack.withLock { $0.last ?? [] }
    }

    /// Takes the failure if a `collect` is in progress; false means record it normally.
    func take(_ issue: XCTIssue) -> Bool {
        stack.withLock { stack in
            guard !stack.isEmpty else { return false }
            stack[stack.count - 1].append(issue.compactDescription)
            return true
        }
    }
}
