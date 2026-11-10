//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct DeviceCallsTests {
    private func sleeper(_ seconds: String) -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = [seconds]
        return process
    }

    @Test func attachTerminatesProcessWhenInterruptHandlerFails() async throws {
        let interrupt = InterruptFlag()
        defer { interrupt.remove() }
        interrupt.raise()
        let started = ContinuousClock.now
        let terminated = try await Devicectl.attach(
            sleeper("30"), interrupt: interrupt, grace: .milliseconds(100), lines: { _ in },
            interrupted: { throw DeviceLoopError(.appNotRunning, "com.example.app is not running.") })
        #expect(terminated)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func attachTerminatesProcessOnSecondInterrupt() async throws {
        let interrupt = InterruptFlag()
        let second = InterruptFlag()
        defer {
            interrupt.remove()
            second.remove()
        }
        interrupt.raise()
        let started = ContinuousClock.now
        let terminated = try await Devicectl.attach(
            sleeper("30"), interrupt: interrupt, again: { second }, lines: { _ in },
            interrupted: {
                second.raise()
                try await Task.sleep(for: .seconds(30))
            })
        #expect(terminated)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func attachLetsProcessExitOnItsOwnAfterInterrupt() async throws {
        let interrupt = InterruptFlag()
        defer { interrupt.remove() }
        interrupt.raise()
        let terminated = try await Devicectl.attach(
            sleeper("0.3"), interrupt: interrupt, grace: .seconds(10), lines: { _ in }, interrupted: {})
        #expect(!terminated)
    }
}
