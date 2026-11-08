import Foundation
import Network

struct HTTPRequest: Sendable {
    let method: String
    /// Path without the query string, e.g. "/vo/current".
    let path: String
    let query: [String: String]
    let body: Data
}

struct HTTPResponse: Sendable {
    var status: Int
    var body: Data

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        do {
            return HTTPResponse(status: status, body: try encoder.encode(value))
        } catch {
            return HTTPResponse(status: 500, body: Data(#"{"error":{"code":"encodingFailed"}}"#.utf8))
        }
    }
}

/// A request that has arrived, plus the way to answer it.
struct PendingRequest: Sendable {
    let request: HTTPRequest
    let reply: @Sendable (HTTPResponse) -> Void
}

/// A deliberately small HTTP/1.1 server: one request per connection, JSON bodies,
/// Content-Length only. It never calls XCUI itself; it hands each request to
/// `onRequest`, and the main thread answers it later.
final class HTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.vofocus.http")
    private let onRequest: @Sendable (PendingRequest) -> Void
    private static let maxRequestSize = 1 << 20

    init(port: UInt16, onRequest: @escaping @Sendable (PendingRequest) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw RunnerError.badRequest("invalid port \(port)")
        }
        listener = try NWListener(using: parameters, on: nwPort)
        self.onRequest = onRequest
    }

    func start() {
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("VOFOCUS listener failed: \(error)")
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = Self.parse(buffer) {
                self.onRequest(PendingRequest(request: request) { response in
                    Self.send(response, on: connection)
                })
            } else if isComplete || error != nil || buffer.count > Self.maxRequestSize {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    /// Returns a request once the headers and the whole Content-Length body are in.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8)
        else { return nil }

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = data[headerEnd.upperBound...]
        guard body.count >= contentLength else { return nil }

        let target = URLComponents(string: String(requestLine[1]))
        var query: [String: String] = [:]
        for item in target?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: target?.path ?? String(requestLine[1]),
            query: query,
            body: Data(body.prefix(contentLength)))
    }

    private static func send(_ response: HTTPResponse, on connection: NWConnection) {
        let reason = switch response.status {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 409: "Conflict"
        default: "Internal Server Error"
        }
        let head = "HTTP/1.1 \(response.status) \(reason)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(response.body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var output = Data(head.utf8)
        output.append(response.body)
        connection.send(content: output, completion: .contentProcessed { _ in connection.cancel() })
    }
}
