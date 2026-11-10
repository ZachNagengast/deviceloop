//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct SessionLockTests {
    private func fixture(_ body: (URL) async throws -> Void) async throws {
        let root = Paths.home.appending(path: "lock-tests/\(UUID().uuidString)")
        try Paths.ensureDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root.appending(path: "session.lock"))
    }

    /// A simulator target with its own session directory, removed afterwards.
    private func flowTarget(_ body: (Target) async throws -> Void) async throws {
        let id = "flow-lock-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: Paths.session(for: id)) }
        try await body(
            Target(
                udid: id, identifier: id, name: "Flow lock fixture", kind: .simulator, deviceType: "iPhone", platform: "iOS",
                model: "fixture", productType: "fixture", osVersion: "test", connectionState: "connected"))
    }

    @Test func flowLockMakesASecondFlowAndUIConnectionsDeviceBusyNamingTheRun() async throws {
        try await flowTarget { target in
            try await SessionLock.withFlowLock("flow-20261108-131927-3f9a2c", on: target) {
                let started = ContinuousClock.now
                let second = await #expect(throws: DeviceLoopError.self) {
                    try await SessionLock.withFlowLock("flow-other", on: target) {}
                }
                let waited = started.duration(to: .now)
                #expect(waited >= .seconds(2) && waited < .seconds(10))
                #expect(second?.code == .deviceBusy)
                #expect(second?.message == "Flow flow-20261108-131927-3f9a2c is running on \(target.summary).")
                let connect = await #expect(throws: DeviceLoopError.self) { try await UICommands.connect(target) }
                #expect(connect?.code == .deviceBusy)
            }
        }
    }

    @Test func flowLockIsReleasedAfterPassFailureAndCancellation() async throws {
        try await flowTarget { target in
            let flow = try Flow([
                "schema": "deviceloop.flow/1", "name": "fake", "app": ["bundleID": "com.example.app"],
                "steps": [["sleep": ["ms": 1]], ["sleep": ["ms": 2]]],
            ])
            let passed = try await SessionLock.withFlowLock("flow-pass", on: target) { await FlowEngine.run(flow) { _ in } }
            #expect(passed.status == .passed)
            try await SessionLock.checkNoFlow(on: target)
            let lockFile = Paths.session(for: target.udid).appending(path: "flow.lock")
            #expect(try String(contentsOf: lockFile, encoding: .utf8) == "")

            await #expect(throws: DeviceLoopError.self) {
                try await SessionLock.withFlowLock("flow-fail", on: target) { throw DeviceLoopError(.runnerUnreachable, "No runner.") }
            }
            try await SessionLock.checkNoFlow(on: target)

            let (started, signal) = AsyncStream<Void>.makeStream()
            let run = Task {
                try await SessionLock.withFlowLock("flow-cancel", on: target) {
                    await FlowEngine.run(flow) { _ in
                        signal.yield()
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
            }
            for await _ in started { break }
            run.cancel()
            #expect(try await run.value.status == .cancelled)
            try await SessionLock.checkNoFlow(on: target)
        }
    }

    @Test func flowLockWaitsForASharedProbeToRelease() async throws {
        try await flowTarget { target in
            let flowLock = Paths.session(for: target.udid).appending(path: "flow.lock")
            let probe = try await SessionLock.acquire(at: flowLock, timeout: .zero, exclusive: false)
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 0.1)
                probe.release()
            }
            #expect(try await SessionLock.withFlowLock("flow-after-probe", on: target) { true })
        }
    }

    @Test func competingDescriptorsWaitAndTimeOutWithoutReplacingTheInode() async throws {
        try await fixture { url in
            let first = try await SessionLock.acquire(at: url)
            defer { first.release() }
            let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
            let clock = ContinuousClock()
            let started = clock.now
            do {
                let unexpected = try await SessionLock.acquire(at: url, timeout: .milliseconds(80))
                unexpected.release()
                Issue.record("A competing descriptor acquired an owned lock")
            } catch {
                #expect((error as? DeviceLoopError)?.code == .deviceBusy)
            }
            #expect(started.duration(to: clock.now) >= .milliseconds(80))
            first.release()
            let second = try await SessionLock.acquire(at: url, timeout: .milliseconds(80))
            defer { second.release() }
            let after = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
            #expect(inode == after)
        }
    }

    @Test func sharedLocksCoexistAndExcludeAnExclusiveOne() async throws {
        try await fixture { url in
            let first = try await SessionLock.acquire(at: url, timeout: .zero, exclusive: false)
            defer { first.release() }
            let second = try await SessionLock.acquire(at: url, timeout: .zero, exclusive: false)
            second.release()
            await #expect(throws: DeviceLoopError.self) { try await SessionLock.acquire(at: url, timeout: .zero) }
        }
    }

    @Test func cancelledWaiterDoesNotReleaseTheOwnersLock() async throws {
        try await fixture { url in
            let first = try await SessionLock.acquire(at: url)
            defer { first.release() }
            let waiter = Task {
                let lock = try await SessionLock.acquire(at: url, timeout: .seconds(60))
                lock.release()
            }
            try await Task.sleep(for: .milliseconds(100))
            waiter.cancel()
            do {
                try await waiter.value
                Issue.record("Cancelled lock acquisition succeeded")
            } catch {
                #expect(error is CancellationError)
            }
            do {
                let unexpected = try await SessionLock.acquire(at: url, timeout: .zero)
                unexpected.release()
                Issue.record("Cancellation released another descriptor's lock")
            } catch {
                #expect((error as? DeviceLoopError)?.code == .deviceBusy)
            }
        }
    }

    @Test func releasingAnOwnerWakesAWaitingDescriptor() async throws {
        try await fixture { url in
            let first = try await SessionLock.acquire(at: url)
            defer { first.release() }
            let waiter = Task { try await SessionLock.acquire(at: url, timeout: .seconds(60)) }
            try await Task.sleep(for: .milliseconds(100))
            first.release()
            let second = try await waiter.value
            second.release()
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func ownerDeinitializationReleasesTheLock() async throws {
        try await fixture { url in
            var owner: SessionLock? = try await SessionLock.acquire(at: url)
            weak let reference = owner
            owner = nil
            #expect(reference == nil)
            let next = try await SessionLock.acquire(at: url, timeout: .zero)
            next.release()
        }
    }

    @Test func lockFileIsOwnerOnlyEvenWhenAnExistingFileWasPermissive() async throws {
        try await fixture { url in
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o644])
            let lock = try await SessionLock.acquire(at: url)
            defer { lock.release() }
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
        }
    }

    @Test func lockFileSymlinksAreRejected() async throws {
        try await fixture { url in
            let target = url.deletingLastPathComponent().appending(path: "untouched")
            try Data("original".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            do {
                let unexpected = try await SessionLock.acquire(at: url)
                unexpected.release()
                Issue.record("A symlink was accepted as a lock file")
            } catch {
                #expect(error is DeviceLoopError)
            }
            #expect(try String(contentsOf: target, encoding: .utf8) == "original")
        }
    }
}
