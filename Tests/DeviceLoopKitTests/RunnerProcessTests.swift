//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct RunnerProcessTests {
    private func process(seconds: String = "30", _ body: (pid_t) async throws -> Void) async throws {
        let directory = Paths.home.appending(path: "process-tests/\(UUID().uuidString)")
        try Paths.ensureDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pid = try Shell.spawnDetached(["/bin/sleep", seconds], log: directory.appending(path: "process.log"))
        defer {
            // This is our unreaped test child, never a PID loaded from a session file.
            if !RunnerProcess.childHasExited(pid) {
                kill(pid, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
            }
        }
        try await body(pid)
    }

    private func target(tunnel: String? = nil) -> Target {
        let id = "process-test-\(UUID().uuidString)"
        return Target(
            udid: id, identifier: id, name: "Local process fixture", kind: tunnel == nil ? .simulator : .device,
            deviceType: "iPhone", platform: "iOS", model: "fixture", productType: "fixture",
            osVersion: "test", connectionState: "connected", tunnelAddress: tunnel
        )
    }

    @Test func shutdownWaitsForProcessExit() async throws {
        try await process(seconds: "0.3") { pid in
            let identity = try #require(RunnerProcess.identity(of: pid))
            try await RunnerSession.completeShutdown(pid: pid, identity: identity, timeout: .seconds(2), request: {})
            #expect(RunnerProcess.state(of: pid, matching: identity) == .exited)
            #expect(RunnerProcess.childHasExited(pid))
        }
    }

    @Test func failedAcknowledgementCanOnlySucceedAfterObservedProcessExit() async throws {
        try await process(seconds: "0.2") { pid in
            let identity = try #require(RunnerProcess.identity(of: pid))
            try await RunnerSession.completeShutdown(pid: pid, identity: identity, timeout: .seconds(2)) {
                throw URLError(.networkConnectionLost)
            }
            #expect(RunnerProcess.state(of: pid, matching: identity) == .exited)
        }
    }

    @Test func incompleteShutdownIsReportedAndDoesNotKillTheProcess() async throws {
        try await process { pid in
            let identity = try #require(RunnerProcess.identity(of: pid))
            do {
                try await RunnerSession.completeShutdown(pid: pid, identity: identity, timeout: .milliseconds(30), request: {})
                Issue.record("Shutdown reported success before the process exited")
            } catch {
                #expect((error as? DeviceLoopError)?.code == .deviceBusy)
            }
            #expect(RunnerProcess.state(of: pid, matching: identity) == .running)
        }
    }

    @Test func legacySessionWithoutIdentityNeverSignalsALiveProcess() async throws {
        try await process { pid in
            do {
                try await RunnerSession.completeShutdown(pid: pid, identity: nil, timeout: .milliseconds(30), request: {})
                Issue.record("Legacy process was reported stopped while still running")
            } catch {
                #expect((error as? DeviceLoopError)?.code == .deviceBusy)
            }
            #expect(RunnerProcess.state(of: pid, matching: nil) == .running)
        }
    }

    @Test func reusedPIDIsNotConfusedWithTheOriginalRunnerOrSignaled() async throws {
        try await process { pid in
            let current = try #require(RunnerProcess.identity(of: pid))
            var previous = current
            previous.startSeconds -= 1
            try await RunnerSession.completeShutdown(pid: pid, identity: previous, timeout: .zero, request: {})
            #expect(RunnerProcess.state(of: pid, matching: current) == .running)
        }
    }

    @Test func childHasExitedStaysTrueAfterReaping() async throws {
        try await process(seconds: "0.01") { pid in
            let deadline = ContinuousClock.now + .seconds(10)
            var exited = RunnerProcess.childHasExited(pid)
            while !exited, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
                exited = RunnerProcess.childHasExited(pid)
            }
            #expect(exited)
            #expect(RunnerProcess.childHasExited(pid))
        }
    }

    @Test func processOwnedByAnotherUserCountsAsExited() {
        #expect(RunnerProcess.state(of: 1, matching: nil) == .exited)
    }

    @Test func unreachableSessionWithoutIdentityIsDiscarded() async throws {
        try await process { pid in
            let target = target()
            defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
            try SessionFile(udid: target.udid, host: "::1", port: 1, token: "test-only", pid: pid).write()
            #expect(try await RunnerSession.reattach(target) == nil)
            #expect(SessionFile.read(for: target.udid) == nil)
        }
    }

    @Test func explicitStopDiscardsAnUnreachableSessionWithoutIdentity() async throws {
        try await process { pid in
            let target = target()
            defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
            try SessionFile(udid: target.udid, host: "::1", port: 1, token: "test-only", pid: pid).write()
            #expect(try await RunnerSession.stopExisting(target) == false)
            #expect(SessionFile.read(for: target.udid) == nil)
        }
    }

    @Test func pendingTeardownWithoutIdentityIsRetained() async throws {
        try await process { pid in
            let target = target()
            defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
            try SessionFile(udid: target.udid, host: "::1", port: 1, token: "test-only", pid: pid, stopping: true).write()
            do {
                _ = try await RunnerSession.reattach(target)
                Issue.record("A stopping legacy runner was replaced")
            } catch {
                #expect((error as? DeviceLoopError)?.code == .deviceBusy)
            }
            #expect(try await RunnerSession.stopExisting(target, shutdown: { _ in }))
            #expect(SessionFile.read(for: target.udid)?.stopping == true)
        }
    }

    @Test func failedHealthCheckPreservesASessionWhoseProcessIsStillAlive() async throws {
        try await process { pid in
            let target = target()
            defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
            let identity = try #require(RunnerProcess.identity(of: pid))
            let file = SessionFile(udid: target.udid, host: "::1", port: 1, token: "test-only", pid: pid, processIdentity: identity)
            try file.write()
            do {
                _ = try await RunnerSession.reattach(target)
                Issue.record("An unreachable live runner was discarded")
            } catch {
                #expect((error as? DeviceLoopError)?.code == .runnerUnreachable)
            }
            #expect(SessionFile.read(for: target.udid)?.processIdentity == identity)
            #expect(RunnerProcess.state(of: pid, matching: identity) == .running)
        }
    }

    @Test func movedTunnelWithALiveUnreachableRunnerNamesBothAddressesAndKeepsTheSession() async throws {
        try await process { pid in
            let target = target(tunnel: "fd00::2")
            defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
            let identity = try #require(RunnerProcess.identity(of: pid))
            try SessionFile(
                udid: target.udid, host: "fd00::1", port: 1, token: "test-only", pid: pid,
                processIdentity: identity, sessionEpoch: UUID().uuidString
            ).write()
            do {
                _ = try await RunnerSession.reattach(target, probe: { _, _ in nil })
                Issue.record("An unreachable live runner was reused or discarded")
            } catch {
                let failure = try #require(error as? DeviceLoopError)
                #expect(failure.code == .runnerUnreachable)
                #expect(failure.message.contains("fd00::1") && failure.message.contains("fd00::2"))
                #expect(failure.fix != nil)
            }
            #expect(SessionFile.read(for: target.udid)?.host == "fd00::1")
            #expect(RunnerProcess.state(of: pid, matching: identity) == .running)
        }
    }

    /// Runs connect with a live suite marker on `target`, so it fails with device_busy where it would build a new runner.
    private func connectStoppingAtLaunch(_ target: Target) async throws {
        let marker = SuiteMarker(job: "process-test", pid: getpid(), processIdentity: try #require(RunnerProcess.identity(of: getpid())))
        try marker.write(for: target.udid)
        let error = await #expect(throws: DeviceLoopError.self) { _ = try await RunnerSession.connect(target) }
        #expect(error?.code == .deviceBusy)
    }

    @Test func connectTerminatesALiveRunnerThatStoppedAnsweringWhenTheTunnelMoved() async throws {
        try await process { pid in
            let target = target(tunnel: "::1")
            defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
            let identity = try #require(RunnerProcess.identity(of: pid))
            try SessionFile(udid: target.udid, host: "fd00::1", port: 1, token: "test-only", pid: pid, processIdentity: identity).write()
            try await connectStoppingAtLaunch(target)
            #expect(RunnerProcess.childHasExited(pid))
            #expect(SessionFile.read(for: target.udid) == nil)
        }
    }

    @Test func connectDoesNotSignalAReusedPIDWhenTheTunnelMoved() async throws {
        try await process { pid in
            let target = target(tunnel: "::1")
            defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
            let current = try #require(RunnerProcess.identity(of: pid))
            var previous = current
            previous.startSeconds -= 1
            try SessionFile(udid: target.udid, host: "fd00::1", port: 1, token: "test-only", pid: pid, processIdentity: previous).write()
            try await connectStoppingAtLaunch(target)
            #expect(SessionFile.read(for: target.udid) == nil)
            #expect(RunnerProcess.state(of: pid, matching: current) == .running)
        }
    }

    @Test func pendingTeardownBlocksReattachmentUntilTheProcessExits() async throws {
        try await process(seconds: "0.3") { pid in
            let target = target()
            defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
            let identity = try #require(RunnerProcess.identity(of: pid))
            let file = SessionFile(
                udid: target.udid, host: "::1", port: 1, token: "test-only", pid: pid,
                processIdentity: identity, stopping: true
            )
            try file.write()
            do {
                _ = try await RunnerSession.reattach(target)
                Issue.record("A stopping runner was reused")
            } catch {
                #expect((error as? DeviceLoopError)?.code == .deviceBusy)
            }
            #expect(SessionFile.read(for: target.udid)?.stopping == true)
            #expect(try await RunnerProcess.waitForExit(pid, matching: identity, timeout: .seconds(2)))
            #expect(try await RunnerSession.reattach(target) == nil)
            #expect(SessionFile.read(for: target.udid) == nil)
        }
    }

    @Test(arguments: [DeviceLoopError.Code.deviceBusy, .dispatchExpired, .sessionMismatch])
    func rejectedShutdownRestoresTheReadySession(code: DeviceLoopError.Code) async throws {
        try await process { pid in
            let target = target()
            defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
            let identity = try #require(RunnerProcess.identity(of: pid))
            let file = SessionFile(udid: target.udid, host: "::1", port: 1, token: "test-only", pid: pid, processIdentity: identity)
            try file.write()
            let rejection = DeviceLoopError(code, "Rejected before dispatch")
            do {
                try await RunnerSession.finishStop(file, timeout: .milliseconds(30)) { throw rejection }
                Issue.record("Rejected shutdown reported success")
            } catch {
                #expect(error as? DeviceLoopError == rejection)
            }
            let retained = try #require(SessionFile.read(for: target.udid))
            #expect(retained.stopping == nil)
            #expect(retained.processIdentity == identity)
            #expect(RunnerProcess.state(of: pid, matching: identity) == .running)
        }
    }

    @Test func unknownShutdownRetainsThePendingSession() async throws {
        try await process { pid in
            let target = target()
            defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
            let identity = try #require(RunnerProcess.identity(of: pid))
            let file = SessionFile(udid: target.udid, host: "::1", port: 1, token: "test-only", pid: pid, processIdentity: identity)
            try file.write()
            do {
                try await RunnerSession.finishStop(file, timeout: .milliseconds(30)) { throw URLError(.networkConnectionLost) }
                Issue.record("Unknown shutdown reported success")
            } catch {
                #expect((error as? DeviceLoopError)?.code == .deviceBusy)
            }
            #expect(SessionFile.read(for: target.udid)?.stopping == true)
            #expect(RunnerProcess.state(of: pid, matching: identity) == .running)
        }
    }
}
