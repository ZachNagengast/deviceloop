//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Synchronization
import Testing

@testable import DeviceLoopKit

/// A runner in the test process that `client` reaches. Each `METHOD /path` gets the next of its `replies`, and the last one
/// repeats. A route with no replies, or a nil reply, drops the connection.
final class FakeRunner: Sendable {
    typealias Reply = (status: Int, body: Data)

    private struct State {
        var replies: [String: [Reply?]]
        var requests: [(route: String, sentAt: ContinuousClock.Instant)] = []
    }

    private static let runners = Mutex<[Int: FakeRunner]>([:])
    private static let lastPort = Atomic(0)

    let client: RunnerClient
    private let state: Mutex<State>

    init(epoch: String, replies: [String: [Reply?]]) {
        let port = Self.lastPort.add(1, ordering: .relaxed).newValue
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Connection.self]
        client = RunnerClient(
            baseURL: .runner(host: "::1", port: UInt16(port)), token: "test", epoch: epoch,
            urlSession: URLSession(configuration: configuration))
        state = Mutex(State(replies: replies))
        Self.runners.withLock { $0[port] = self }
    }

    /// Each request as `METHOD /path`, in the order it arrived.
    var requests: [String] {
        state.withLock { $0.requests.map(\.route) }
    }

    /// The number of `route` requests.
    func sent(_ route: String) -> Int {
        requests.filter { $0 == route }.count
    }

    /// When the last `route` request arrived.
    func sentAt(_ route: String) -> ContinuousClock.Instant? {
        state.withLock { $0.requests.last { $0.route == route }?.sentAt }
    }

    private func reply(to request: URLRequest) -> Reply? {
        let route = "\(request.httpMethod ?? "") \(request.url?.path ?? "")"
        return state.withLock { state in
            state.requests.append((route, .now))
            let queued = state.replies[route] ?? []
            if queued.count > 1 { state.replies[route] = Array(queued.dropFirst()) }
            return queued.first ?? nil
        }
    }

    /// Hands each request to the fake runner on its port.
    private final class Connection: URLProtocol {
        override static func canInit(with request: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let runner = request.url?.port.flatMap { port in FakeRunner.runners.withLock { $0[port] } }
            guard let reply = runner?.reply(to: request), let url = request.url,
                let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}

/// A TCP server on the IPv6 loopback address that queues connections without answering them. With `body`, it answers the first
/// request with that JSON and no other. `stop()` closes it.
final class LoopbackServer: Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let stopping = Mutex(false)
    private let closed = DispatchSemaphore(value: 0)

    init?(answering body: String? = nil) {
        let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_loopback
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let listening = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, length) == 0 && listen(descriptor, 4) == 0 && getsockname(descriptor, $0, &length) == 0
            }
        }
        guard listening else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
        port = UInt16(bigEndian: address.sin6_port)
        Thread.detachNewThread { self.serve(body) }
    }

    var client: RunnerClient {
        RunnerClient(baseURL: .runner(host: "::1", port: port), token: "token")
    }

    /// Stops listening and waits until the socket is closed.
    func stop() {
        stopping.withLock { $0 = true }
        closed.wait()
    }

    private func serve(_ body: String?) {
        var listener = pollfd(fd: descriptor, events: body == nil ? 0 : Int16(POLLIN), revents: 0)
        while !stopping.withLock({ $0 }) {
            guard poll(&listener, 1, 50) > 0, listener.revents & Int16(POLLIN) != 0, let body else { continue }
            listener.events = 0
            answer(accept(descriptor, nil, nil), with: body)
        }
        close(descriptor)
        closed.signal()
    }

    /// Reads a request up to the closing brace of its JSON body, or to the end of the headers for a GET, and answers it
    /// with `body`.
    private func answer(_ connection: Int32, with body: String) {
        guard connection >= 0 else { return }
        defer { close(connection) }
        var request = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let headersEnd = Data("\r\n\r\n".utf8)
        while request.last != UInt8(ascii: "}"), !(request.starts(with: Data("GET ".utf8)) && request.range(of: headersEnd) != nil) {
            let count = read(connection, &chunk, chunk.count)
            guard count > 0 else { return }
            request.append(contentsOf: chunk[..<count])
        }
        let headers = "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close"
        let response = "HTTP/1.1 200 OK\r\n\(headers)\r\n\r\n\(body)"
        _ = response.withCString { write(connection, $0, strlen($0)) }
    }
}

@Suite struct RunnerFakesTests {
    @Test func fakeRunnersRecordOnlyTheirOwnRequests() async {
        let info = "GET \(RunnerWire.Path.info)"
        let first = FakeRunner(epoch: "first", replies: [:])
        let second = FakeRunner(epoch: "second", replies: [:])
        _ = try? await first.client.get(RunnerWire.Path.info, as: InfoResult.self)
        #expect(first.requests == [info])
        #expect(second.requests.isEmpty)
    }

    @Test func stoppedServerThatNoClientReachedRefusesConnections() async throws {
        let server = try #require(LoopbackServer(answering: "{}"))
        server.stop()
        var request = URLRequest(url: .runner(host: "::1", port: server.port))
        request.timeoutInterval = 5
        let error = await #expect(throws: URLError.self) { try await URLSession.shared.data(for: request) }
        #expect(error?.code == .cannotConnectToHost)
    }
}
