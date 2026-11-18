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

    /// The token scripts/runner.sh saved for the runner on `port`, if any.
    public static func savedToken(buildDirectory: URL, port: Int) -> String? {
        let url = buildDirectory.appending(path: "runner-\(port).token")
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
        (try? await send("GET", "/status", timeout: 2))?.ok ?? false
    }
}
