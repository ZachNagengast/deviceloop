//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct SuiteMarkerTests {
    private func withTarget(_ body: (Target) async throws -> Void) async throws {
        let id = "suite-marker-test-\(UUID().uuidString)"
        let target = Target(
            udid: id, identifier: id, name: "Unit test", kind: .simulator, deviceType: "iPhone", platform: "iOS",
            model: "fixture", productType: "fixture", osVersion: "test", connectionState: "connected", bootState: "booted"
        )
        defer { try? FileManager.default.removeItem(at: Paths.session(for: id)) }
        try await body(target)
    }

    private func ownMarker() throws -> SuiteMarker {
        SuiteMarker(job: "test-live", pid: getpid(), processIdentity: try #require(RunnerProcess.identity(of: getpid())))
    }

    private func errorCode(_ body: () async throws -> Void) async -> DeviceLoopError.Code? {
        do {
            try await body()
            return nil
        } catch {
            return (error as? DeviceLoopError)?.code
        }
    }

    @Test func liveMarkerIsKept() async throws {
        try await withTarget { target in
            let marker = try ownMarker()
            try marker.write(for: target.udid)
            #expect(SuiteMarker.live(for: target.udid) == marker)
            #expect(FileManager.default.fileExists(atPath: SuiteMarker.url(for: target.udid).path))
        }
    }

    @Test func markerOfExitedProcessIsRemoved() async throws {
        try await withTarget { target in
            let process = try Process.run(URL(filePath: "/usr/bin/true"), arguments: [])
            process.waitUntilExit()
            let identity = RunnerProcessIdentity(startSeconds: 1, startMicroseconds: 0, userID: getuid())
            try SuiteMarker(job: "test-exited", pid: process.processIdentifier, processIdentity: identity).write(for: target.udid)
            #expect(SuiteMarker.live(for: target.udid) == nil)
            #expect(!FileManager.default.fileExists(atPath: SuiteMarker.url(for: target.udid).path))
        }
    }

    @Test func markerWithReusedPIDIsRemoved() async throws {
        try await withTarget { target in
            var marker = try ownMarker()
            marker.processIdentity.startSeconds -= 1
            try marker.write(for: target.udid)
            #expect(SuiteMarker.live(for: target.udid) == nil)
            #expect(!FileManager.default.fileExists(atPath: SuiteMarker.url(for: target.udid).path))
        }
    }

    @Test func finishedJobRemovesOnlyItsOwnMarker() async throws {
        try await withTarget { target in
            try ownMarker().write(for: target.udid)
            await SuiteMarker.remove(job: "test-other", for: target.udid)
            #expect(SuiteMarker.read(for: target.udid) != nil)
            await SuiteMarker.remove(job: "test-live", for: target.udid)
            #expect(SuiteMarker.read(for: target.udid) == nil)
        }
    }

    @Test func runnerLaunchIsRefusedWhileAMarkerIsLive() async throws {
        try await withTarget { target in
            try ownMarker().write(for: target.udid)
            #expect(await errorCode { _ = try await RunnerSession.connect(target) } == .deviceBusy)
        }
    }

    @Test func testRunIsRefusedWhileAMarkerIsLive() async throws {
        try await withTarget { target in
            try ownMarker().write(for: target.udid)
            let code = await errorCode {
                _ = try await TestCommands.run(target, project: "App.xcodeproj", workspace: nil, scheme: "App")
            }
            #expect(code == .deviceBusy)
        }
    }

    @Test func testRunIsRefusedWhileARunnerIsLive() async throws {
        try await withTarget { target in
            try SessionFile(
                udid: target.udid, host: "::1", port: 1, token: "test-only", pid: getpid(),
                processIdentity: RunnerProcess.identity(of: getpid())
            ).write()
            let code = await errorCode {
                _ = try await TestCommands.run(target, project: "App.xcodeproj", workspace: nil, scheme: "App")
            }
            #expect(code == .deviceBusy)
        }
    }
}
