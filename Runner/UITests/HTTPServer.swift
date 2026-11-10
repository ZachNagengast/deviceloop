//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Network

struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: body.isEmpty ? Data("{}".utf8) : body)
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json", body: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
    }
}

/// One request per connection, Content-Length bodies only. Rejects anything that is not the CLI once its headers arrive,
/// before the body: missing token, browser `Origin` headers, non-JSON POST bodies.
final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    let queue = DispatchQueue(label: "deviceloop.runner.http")
    private let listener: NWListener
    private let token: String
    private let handler: Handler
    private let maxBodyBytes = 8 * 1024 * 1024
    /// A connection that has not sent its whole header block within this time is closed.
    private let headerTimeout: DispatchTimeInterval = .seconds(5)

    /// `bind` is the address to listen on (device tunnel address, or `::1` on a simulator).
    init(bind: String?, port: UInt16, token: String, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let bind, !bind.isEmpty {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bind), port: NWEndpoint.Port(rawValue: port) ?? .any)
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        }
        self.token = token
        self.handler = handler
    }

    /// Starts listening and calls `ready` with the bound port once the listener is up.
    func start(ready: @escaping @Sendable (UInt16) -> Void, failed: @escaping @Sendable (Error) -> Void) {
        listener.stateUpdateHandler = { [listener] state in
            switch state {
                case .ready: ready(listener.port?.rawValue ?? 0)
                case .failed(let error): failed(error)
                default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let header = HeaderState()
            connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + self.headerTimeout) { [weak connection] in
                if !header.parsed { connection?.cancel() }
            }
            self.receive(on: connection, buffer: Data(), header: header)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func receive(on connection: NWConnection, buffer: Data, header: HeaderState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            let parsed = Self.parse(buffer, maxBodyBytes: self.maxBodyBytes)
            if !header.parsed, let head = parsed.head {
                header.parsed = true
                if let rejection = self.reject(head) {
                    self.send(rejection, on: connection)
                    return
                }
            }
            switch parsed {
                case .incomplete where !isComplete && error == nil, .headers where !isComplete && error == nil:
                    self.receive(on: connection, buffer: buffer, header: header)
                case .request(let request):
                    let handler = self.handler
                    Task {
                        let response = await handler(request)
                        self.queue.async { self.send(response, on: connection) }
                    }
                case .incomplete, .headers, .invalid:
                    self.send(RunnerError.response(400, "bad_request", "Malformed HTTP request"), on: connection)
            }
        }
    }

    private func reject(_ request: HTTPRequest) -> HTTPResponse? {
        if request.headers["origin"] != nil {
            return RunnerError.response(403, "unauthorized", "Browser requests are not accepted")
        }
        guard let presented = request.headers["authorization"], constantTimeEquals(presented, "Bearer \(token)") else {
            return RunnerError.response(401, "unauthorized", "Missing or invalid runner token")
        }
        if request.method == "POST", !(request.headers["content-type"] ?? "").hasPrefix("application/json") {
            return RunnerError.response(415, "bad_request", "POST bodies must be application/json")
        }
        return nil
    }

    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        var header = "HTTP/1.1 \(response.status) \(response.status < 400 ? "OK" : "Error")\r\n"
        header += "Content-Type: \(response.contentType)\r\n"
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    enum ParseResult {
        case incomplete
        case invalid
        /// The header block has arrived and the body has not. The request's body is empty.
        case headers(HTTPRequest)
        case request(HTTPRequest)

        /// The request line and headers, once the header block has parsed.
        var head: HTTPRequest? {
            switch self {
                case .headers(let request), .request(let request): request
                case .incomplete, .invalid: nil
            }
        }
    }

    static func parse(_ buffer: Data, maxBodyBytes: Int) -> ParseResult {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 * 1024 ? .invalid : .incomplete
        }
        guard let header = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let bodyLength = Int(headers["content-length"] ?? "0") ?? 0
        guard bodyLength >= 0, bodyLength <= maxBodyBytes else { return .invalid }
        var request = HTTPRequest(
            method: String(requestLine[0]),
            path: URLComponents(string: String(requestLine[1]))?.path ?? "/",
            headers: headers,
            body: Data()
        )
        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= bodyLength else { return .headers(request) }
        request.body = Data(buffer[bodyStart ..< (bodyStart + bodyLength)])
        return .request(request)
    }
}

/// Whether a connection's header block has parsed. Read and written only on the server queue.
private final class HeaderState: @unchecked Sendable {
    var parsed = false
}

enum RunnerError {
    static func response(
        _ status: Int, _ code: String, _ message: String, issues: [String] = [], alternatives: [String]? = nil
    ) -> HTTPResponse {
        let error = WireError(code: code, message: message, issues: issues, alternatives: alternatives)
        return .json(WireResponse<WireEmpty>(ok: false, error: error), status: status)
    }
}
