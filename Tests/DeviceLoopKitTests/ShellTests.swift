//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct ShellTests {
    @Test func timeoutThrowsTimeoutError() async {
        do {
            _ = try await Shell.run(["sleep", "5"], timeout: .milliseconds(300))
            Issue.record("expected a timeout")
        } catch let error as DeviceLoopError {
            #expect(error.code == .timeout)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func cancellationThrowsCancellationError() async {
        let task = Task { try await Shell.run(["sleep", "5"], timeout: .seconds(30)) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    @Test func manyConcurrentRunsStillTimeOut() async {
        let started = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 24 {
                group.addTask { _ = try? await Shell.run(["sleep", "30"], timeout: .milliseconds(500)) }
            }
        }
        #expect(ContinuousClock.now - started < .seconds(15))
    }

    @Test func notifyZeroPostsNoNotification() {
        #expect(!Shell.notify("Unit test", environment: ["DEVICELOOP_NOTIFY": "0"]))
    }

    @Test func detachedProcessDoesNotInheritOpenDescriptors() throws {
        var pipeDescriptors: [Int32] = [0, 0]
        #expect(pipe(&pipeDescriptors) == 0)
        let inheritable = fcntl(pipeDescriptors[1], F_DUPFD, 200)
        defer {
            for descriptor in pipeDescriptors + [inheritable] { close(descriptor) }
        }
        let log = FileManager.default.temporaryDirectory.appending(path: "deviceloop-spawn-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }

        let pid = try Shell.spawnDetached(["ls", "/dev/fd"], log: log)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let descriptors = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        #expect(descriptors.contains("1"))
        #expect(!descriptors.contains { $0 == String(inheritable) })
    }

    @Test func detachedProcessSpawnedInATaskEndsOnSIGTERM() async throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "deviceloop-spawn-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let pid = try Shell.spawnDetached(["sleep", "30"], log: log)
        kill(pid, SIGTERM)
        #expect(try await RunnerProcess.waitForExit(pid, matching: nil, timeout: .seconds(2)))
    }
}
