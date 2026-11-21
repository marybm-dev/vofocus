import Foundation

/// Talks to a running VOFocus runner over HTTP.
public struct RunnerClient: Sendable {
    public let baseURL: URL
    /// Sent as `Authorization: Bearer <token>`; the runner refuses requests without it.
    public let token: String?

    /// `host` is an IP address or hostname; IPv6 addresses (such as a device's
    /// CoreDevice tunnel address) are bracketed automatically.
    public init(host: String = "127.0.0.1", port: Int, token: String?) {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        baseURL = URL(string: "http://\(hostPart):\(port)")!
        self.token = token
    }

    /// The file scripts/runner.sh saves the token in: runner-<port>.token for the
    /// Simulator, runner-<port>-<device>.token for a device, so a Simulator runner and
    /// a device runner on the same port don't overwrite each other's token.
    public static func tokenFileName(port: Int, device: String? = nil) -> String {
        "runner-\(port)\(fileSuffix(device: device)).token"
    }

    /// "" for the Simulator, "-<device>" for a device, with each byte that isn't an
    /// ASCII letter, digit or hyphen replaced by "_", exactly as runner.sh's
    /// `tr -c 'A-Za-z0-9-' '_'` does (so "Mary’s" gives "Mary___s" in both).
    public static func fileSuffix(device: String?) -> String {
        guard let device else { return "" }
        let safe = device.utf8.map { byte -> Character in
            let c = Character(Unicode.Scalar(byte))
            return byte < 0x80 && (c.isLetter || c.isNumber || c == "-") ? c : "_"
        }
        return "-" + String(safe)
    }

    /// The token scripts/runner.sh saved for the runner on `port`, if any.
    public static func savedToken(buildDirectory: URL, port: Int, device: String? = nil) -> String? {
        let url = buildDirectory.appending(path: tokenFileName(port: port, device: device))
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Keeps nothing on disk. URLSession.shared would cache replies, which hold what's on
    /// screen, in ~/Library/Caches/<program name>.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    public struct Response: Sendable {
        public let status: Int
        public let body: Data
        public var ok: Bool { status == 200 }
        public var text: String { String(decoding: body, as: UTF8.self) }
    }

    /// Sends one request. The runner handles requests one at a time, and a session
    /// launch can take a while, hence the generous default timeout.
    public func send(
        _ method: String, _ path: String, query: [String: String] = [:],
        body: Data? = nil, timeout: TimeInterval = 120
    ) async throws -> Response {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await Self.session.data(for: request)
        return Response(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    /// True if a runner answers on this port.
    public func isUp() async -> Bool {
        await reachability() == .up
    }

    public enum Reachability: Sendable, Equatable {
        /// Answers with this token.
        case up
        /// A runner answers but refuses this token: someone else started it, or a
        /// runner started since replaced the token file.
        case wrongToken
        /// Something accepts connections but doesn't answer in time, such as a runner
        /// busy with a long request (it handles one at a time).
        case busy
        /// Nothing listens.
        case down
    }

    public func reachability() async -> Reachability {
        do {
            let response = try await send("GET", "/status", timeout: 2)
            if response.ok { return .up }
            return response.status == 401 ? .wrongToken : .down
        } catch let error as URLError where error.code == .timedOut {
            return .busy
        } catch {
            return .down
        }
    }
}
