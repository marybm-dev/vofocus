import Synchronization
import XCTest

/// The runner's entry point: one test that serves HTTP until told to stop.
///
/// Start it with `scripts/runner.sh`, or directly:
///
///     TEST_RUNNER_VOFOCUS_PORT=8740 TEST_RUNNER_VOFOCUS_TOKEN=<secret> \
///       xcodebuild test -scheme VOFocusRunner \
///       -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.2'
///
/// Every request must send `Authorization: Bearer <secret>`. Without
/// VOFOCUS_TOKEN it makes up a token and prints it. It prints
/// `VOFOCUS_READY port=<n>` once it's listening. On a device, VOFOCUS_LISTEN_ADDRESS
/// limits it to that address (the CoreDevice tunnel's).
final class RunnerTests: XCTestCase {
    /// While a request is handled, failures go to IssueCollector, so one failed XCUI
    /// call becomes an error response instead of ending the runner.
    override func record(_ issue: XCTIssue) {
        if IssueCollector.shared.take(issue) {
            print("VOFOCUS xcui failure: \(issue.compactDescription)")
            return
        }
        super.record(issue)
    }

    @MainActor
    func testRunServer() throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        let port = environment["VOFOCUS_PORT"].flatMap(UInt16.init) ?? 8740
        let token: String
        if let given = environment["VOFOCUS_TOKEN"], !given.isEmpty {
            token = given
        } else {
            token = UUID().uuidString + UUID().uuidString
            print("VOFOCUS no VOFOCUS_TOKEN set; requests need Authorization: Bearer \(token)")
        }

        let inbox = Inbox()
        // On a device, the CoreDevice tunnel address the Mac connects to (runner.sh
        // passes it), so only the paired Mac can reach the runner.
        let address = environment["VOFOCUS_LISTEN_ADDRESS"].flatMap { $0.isEmpty ? nil : $0 }
        let server = try HTTPServer(port: port, token: token, listenAddress: address) { inbox.push($0) }
        server.start()
        defer { server.stop() }

        let runner = Runner()
        print("VOFOCUS_READY port=\(port)")

        // XCUI and VoiceOver calls must run on the main thread, one at a time, so
        // requests queue up in the inbox and are handled here in order.
        while !runner.shouldStop {
            if let pending = inbox.pop() {
                let started = Date()
                let response = runner.handle(pending.request)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                print("VOFOCUS \(pending.request.method) \(pending.request.path) -> \(response.status) (\(ms) ms)")
                pending.reply(response)
            } else {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
        runner.tearDown()
        print("VOFOCUS_STOPPED")
    }
}

/// Requests from the network thread, waiting for the main thread.
final class Inbox: Sendable {
    private let items = Mutex<[PendingRequest]>([])

    func push(_ request: PendingRequest) {
        items.withLock { $0.append(request) }
    }

    func pop() -> PendingRequest? {
        items.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}
