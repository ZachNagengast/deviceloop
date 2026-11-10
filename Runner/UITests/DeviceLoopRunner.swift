//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import XCTest

/// One long-lived test that serves the runner API until the CLI asks it to stop.
final class DeviceLoopRunner: XCTestCase {
    static let recordedIssues = RecordedIssues()

    override func setUp() {
        continueAfterFailure = true
    }

    /// Records each issue with XCTest's own failure flag for the current request's response.
    override func record(_ issue: XCTIssue) {
        Self.recordedIssues.append(WireIssue(type: issue.type.rawValue, message: issue.compactDescription, isFailure: issue.isFailure))
    }

    @MainActor
    func testServe() throws {
        let environment = ProcessInfo.processInfo.environment
        let router = Router()
        let server = try HTTPServer(
            bind: environment[RunnerWire.Environment.bind],
            port: UInt16(environment[RunnerWire.Environment.port] ?? "") ?? 0,
            token: environment[RunnerWire.Environment.token] ?? "",
            handler: { request in await router.handle(request) }
        )
        server.start(
            ready: { port in print("\(RunnerWire.readyPrefix) port=\(port) v=\(RunnerWire.version)") },
            failed: { error in
                print("DEVICELOOP_FAILED \(error)")
                Task { @MainActor in router.stopped = true }
            }
        )
        while !router.stopped {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 1))
        }
        server.stop()
    }
}

/// XCTest can report issues from callbacks outside the runner's main actor.
final class RecordedIssues: @unchecked Sendable {
    private let lock = NSLock()
    private var issues: [WireIssue] = []

    func reset() {
        lock.withLock { issues.removeAll() }
    }

    func append(_ issue: WireIssue) {
        lock.withLock { issues.append(issue) }
    }

    func snapshot() -> [WireIssue] {
        lock.withLock { issues }
    }
}
