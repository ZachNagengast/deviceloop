//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct LogCommandsTests {
    private func handle(udid: String = "unit-test", bundleID: String = "com.example.app") throws -> LogHandle {
        LogHandle(
            id: String(UUID().uuidString.prefix(8)).lowercased(), udid: udid, summary: "Unit test (simulator, iOS 27.0)",
            bundleID: bundleID, pid: getpid(), identity: try #require(RunnerProcess.identity(of: getpid())),
            log: "/tmp/log-com.example.app.log", startedAt: "2026-11-08T21:00:00.000Z")
    }

    @Test func handleRoundTripsThroughItsFile() throws {
        let saved = try handle()
        try LogCommands.save(saved)
        defer { LogCommands.remove(saved) }
        #expect(try LogCommands.load(saved.id) == saved)
    }

    @Test func reusedPidWithADifferentStartTimeIsNotRunning() throws {
        var reused = try handle()
        #expect(LogCommands.isRunning(reused))
        reused.identity?.startMicroseconds += 1
        #expect(!LogCommands.isRunning(reused))
    }

    @Test func secondCaptureOfTheSameAppIsBusy() throws {
        let running = try handle(udid: UUID().uuidString)
        try LogCommands.save(running)
        defer { LogCommands.remove(running) }
        let target = Target(
            udid: running.udid, identifier: running.udid, name: "Unit test", kind: .simulator, deviceType: "iPhone", platform: "iOS",
            model: "fixture", productType: "fixture", osVersion: "27.0", connectionState: "connected")
        let error = #expect(throws: DeviceLoopError.self) { try LogCommands.checkIdle(target, bundleID: running.bundleID) }
        #expect(error?.code == .deviceBusy)
        try LogCommands.checkIdle(target, bundleID: "com.example.other")
    }

    @Test func stopOfAnEndedCaptureReportsTheExitAndForgetsTheHandle() async throws {
        var ended = try handle()
        ended.identity?.startMicroseconds += 1
        try LogCommands.save(ended)
        defer { LogCommands.remove(ended) }
        let devicectl = #"{"result":{"process":{"processIdentifier":75839},"terminationResult":{"terminatingSignal":9}}}"#
        try Data(devicectl.utf8).write(to: LogCommands.resultFile(ended.id))
        let result = try await LogCommands.stop(handle: ended.id)
        #expect(result.text.contains("com.example.app (pid 75839) exited: terminatingSignal=9"))
        #expect(throws: DeviceLoopError.self) { try LogCommands.load(ended.id) }
    }

    /// A capture whose devicectl exited after the app ended with SIGTRAP.
    private func trappedLaunch() throws -> LogHandle {
        var exited = try handle()
        exited.identity?.startMicroseconds += 1
        try LogCommands.save(exited)
        let devicectl =
            #"{"info":{"outcome":"success"},"result":{"process":{"processIdentifier":75839},"terminationResult":{"terminatingSignal":5}}}"#
        try Data(devicectl.utf8).write(to: LogCommands.resultFile(exited.id))
        return exited
    }

    private let simulator = Target(
        udid: "unit-test", identifier: "unit-test", name: "Unit test", kind: .simulator, deviceType: "iPhone", platform: "iOS",
        model: "fixture", productType: "fixture", osVersion: "27.0", connectionState: "connected", bootState: "booted")

    @Test func launchThatExitsWithACrashReportIsAppCrashed() async throws {
        let exited = try trappedLaunch()
        defer { LogCommands.remove(exited) }
        let error = await #expect(throws: DeviceLoopError.self) {
            try await LogCommands.waitForLaunch(exited, bundleID: "com.example.app", command: [], target: simulator) { result in
                #expect(result.value(at: "terminationResult.terminatingSignal") == 5)
                throw DeviceLoopError(.appCrashed, "com.example.app (pid 75839) crashed with signal 5, report Sample.ips.")
            }
        }
        #expect(error?.code == .appCrashed)
    }

    @Test func launchThatExitsWithoutACrashReportAddsTheCrashNoteToTheDetail() async throws {
        let exited = try trappedLaunch()
        defer { LogCommands.remove(exited) }
        let error = await #expect(throws: DeviceLoopError.self) {
            try await LogCommands.waitForLaunch(exited, bundleID: "com.example.app", command: [], target: simulator) { _ in
                "no crash report for Sample within 45 s"
            }
        }
        #expect(error?.code == .appNotRunning)
        #expect(error?.detail == "com.example.app (pid 75839) exited: terminatingSignal=5\nno crash report for Sample within 45 s")
    }

    @Test func launchThatFailsOnALockedDeviceIsDeviceLocked() async throws {
        var exited = try handle()
        exited.identity?.startMicroseconds += 1
        try LogCommands.save(exited)
        defer { LogCommands.remove(exited) }
        let devicectl =
            #"{"info":{"outcome":"failed"},"error":{"domain":"com.apple.dt.CoreDeviceError","code":1,"userInfo":{}}}"#
        try Data(devicectl.utf8).write(to: LogCommands.resultFile(exited.id))
        let device = Target(
            udid: "unit-test", identifier: "unit-test", name: "Unit test", kind: .device, deviceType: "iPhone", platform: "iOS",
            model: "fixture", productType: "fixture", osVersion: "27.0", connectionState: "connected")
        let error = await #expect(throws: DeviceLoopError.self) {
            try await LogCommands.waitForLaunch(
                exited, bundleID: "com.example.app", command: [], target: device,
                requireUnlocked: { target in throw DeviceLoopError(.deviceLocked, "\(target.name) is locked.") })
        }
        #expect(error?.code == .deviceLocked)
    }

    @Test func loadRejectsAHandleThatIsNotHex() {
        let error = #expect(throws: DeviceLoopError.self) { try LogCommands.load("../sessions") }
        #expect(error?.code == .badArguments)
    }

    @Test func grepKeepsLinesThatContainTheText() {
        #expect(
            LogCommands.select(["[fixture] M1", "objc", "[fixture] M2"], tail: nil, grep: "[fixture]") == ["[fixture] M1", "[fixture] M2"])
    }

    @Test func tailKeepsTheLastMatchingLines() {
        #expect(LogCommands.select(["a1", "b", "a2", "a3"], tail: 2, grep: "a") == ["a2", "a3"])
    }

    @Test func systemCaptureOnADeviceIsUnsupported() async {
        let device = Target(
            udid: UUID().uuidString, identifier: "fixture", name: "Unit test", kind: .device, deviceType: "iPhone", platform: "iOS",
            model: "fixture", productType: "fixture", osVersion: "27.0", connectionState: "connected")
        let error = await #expect(throws: DeviceLoopError.self) { try await LogCommands.startSystem(device, predicate: nil) }
        #expect(error?.code == .unsupportedOnTarget)
    }

    @Test func streamCommandPassesThePredicateToLogStream() {
        #expect(
            LogCommands.streamCommand("SIM", predicate: #"process == "Sample""#) == [
                "xcrun", "simctl", "spawn", "SIM", "log", "stream", "--style", "ndjson", "--predicate", #"process == "Sample""#,
            ])
    }

    @Test func streamThatExitsRightAwayFailsWithItsLastLine() async throws {
        var stream = try handle()
        let log = FileManager.default.temporaryDirectory.appending(path: "deviceloop-stream-\(UUID().uuidString).ndjson")
        defer { try? FileManager.default.removeItem(at: log) }
        stream.pid = try Shell.spawnDetached(["sh", "-c", "echo 'log: Bad predicate'; exit 64"], log: log)
        stream.identity = RunnerProcess.identity(of: stream.pid)
        stream.log = log.path
        let error = await #expect(throws: DeviceLoopError.self) { try await LogCommands.waitForStream(stream) }
        #expect(error?.code == .badArguments)
        #expect(error?.message.hasSuffix("exited: log: Bad predicate") == true)
    }

    @Test func stopEndsASystemCaptureWithSIGTERM() async throws {
        var stream = try handle()
        let log = FileManager.default.temporaryDirectory.appending(path: "deviceloop-stream-\(UUID().uuidString).ndjson")
        defer { try? FileManager.default.removeItem(at: log) }
        stream.bundleID = nil
        let script = "trap 'echo terminated; kill $!; exit 0' TERM; sleep 30 & echo '{}'; wait"
        stream.pid = try Shell.spawnDetached(["sh", "-c", script], log: log)
        stream.identity = try #require(RunnerProcess.identity(of: stream.pid))
        stream.log = log.path
        try LogCommands.save(stream)
        defer { LogCommands.remove(stream) }
        try await LogCommands.waitForStream(stream)
        let result = try await LogCommands.stop(handle: stream.id)
        #expect(try String(contentsOf: log, encoding: .utf8) == "{}\nterminated\n")
        #expect(result.json["bundleID"] == .null)
        #expect(result.json["total"] == 2)
        #expect(throws: DeviceLoopError.self) { try LogCommands.load(stream.id) }
    }

    @Test func stopReportsTheLineCountAsTotal() async throws {
        var ended = try handle()
        ended.identity?.startMicroseconds += 1
        let log = FileManager.default.temporaryDirectory.appending(path: "deviceloop-log-\(UUID().uuidString).log")
        try Data("M1\nM2\n".utf8).write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }
        ended.log = log.path
        try LogCommands.save(ended)
        defer { LogCommands.remove(ended) }
        let result = try await LogCommands.stop(handle: ended.id)
        #expect(result.json["total"] == 2)
        #expect(result.json["lines"] == nil)
    }

    @Test func readSplitsTheLogFileIntoLines() async throws {
        var saved = try handle()
        let log = FileManager.default.temporaryDirectory.appending(path: "deviceloop-log-\(UUID().uuidString).log")
        try Data("M1\r\n2026-11-08 12:59:20.412182-0800 DeviceLoopHost[1:2] [fixture] M1\r\npartial".utf8).write(to: log)
        defer { try? FileManager.default.removeItem(at: log) }
        saved.log = log.path
        try LogCommands.save(saved)
        defer { LogCommands.remove(saved) }
        let result = try await LogCommands.read(handle: saved.id, tail: nil, grep: nil)
        #expect(result.json["lines"] == ["M1", "2026-11-08 12:59:20.412182-0800 DeviceLoopHost[1:2] [fixture] M1", "partial"])
        #expect(result.json["running"] == true)
    }
}
