//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Testing

@testable import DeviceLoopKit

private func target(_ kind: Target.Kind, udid: String = "UDID") -> Target {
    Target(
        udid: udid, identifier: udid, name: "Test iPhone", kind: kind, deviceType: "iPhone", platform: "iOS",
        model: "fixture", productType: "fixture", osVersion: "27.0", connectionState: "connected", bootState: "booted"
    )
}

func hostApp() throws -> InstalledApp {
    try #require(
        InstalledApp(devicectl: [
            "bundleIdentifier": "com.argmaxinc.deviceloop.host", "name": "DeviceLoop", "version": "1.0", "bundleVersion": "1",
        ]))
}

/// A finished job whose result bundle is the recorded SuiteFixture performance run.
func performanceRun() async throws -> TestRun {
    TestRun(
        job: "test-1", device: "UDID", status: "passed", arguments: [], exitStatus: 0, startTime: 0, endTime: 1,
        directory: "/jobs/test-1", bundle: "/jobs/test-1/result.xcresult", log: "/jobs/test-1/xcodebuild.log", xcodebuildErrors: [],
        result: try await recordedReport("perf")
    )
}

@Suite struct PerfCommandsTests {
    @Test func liveRecordingOfTheTargetIsRefused() async throws {
        let udid = "PERF-\(UUID().uuidString)"
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let handle = RecordingHandle(
            id: id, udid: udid, summary: "test", simulator: true, pid: getpid(), pidStart: Recorder.processStart(getpid()),
            video: "/tmp/test.mp4", startedAt: 0)
        let file = try Paths.ensureDirectory(Recorder.directory).appending(path: "\(id).json")
        try JSONEncoder().encode(handle).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let error = await #expect(throws: DeviceLoopError.self) {
            try await PerfCommands.launch(target(.simulator, udid: udid), bundleID: "com.argmaxinc.deviceloop.host")
        }
        #expect(error?.code == .recorderBusy)
    }

    @Test func iterationsBelowOneAreRefused() async throws {
        let error = await #expect(throws: DeviceLoopError.self) {
            try await PerfCommands.launch(target(.simulator), bundleID: "com.argmaxinc.deviceloop.host", iterations: 0)
        }
        #expect(error?.code == .badArguments)
    }

    @Test func reportHasTheOSBuildAppVersionAndMeasurements() async throws {
        let result = try PerfCommands.report(
            try await performanceRun(), app: try hostApp(), iterations: 5, launchArguments: [], target: target(.device))
        let lines = result.text.split(separator: "\n")
        #expect(lines.first == "Test iPhone (device, iOS 27.0), OS build 24A434")
        #expect(lines.dropFirst().first == "app com.argmaxinc.deviceloop.host 1.0 (1), 5 launches")
        #expect(result.json["device"]?["osBuildNumber"]?.string == "24A434")
        #expect(result.json["app"]?["version"]?.string == "1.0")
        let launch = try #require(result.json["metrics"]?.array?.first { $0["test"]?.string == "Performance/testLaunch()" })
        #expect(launch["measurements"]?.array?.count == 5)
        #expect(launch["unitOfMeasurement"]?.string == "s")
    }

    @Test func onlyASimulatorReportSaysTimingsComeFromTheMac() async throws {
        let run = try await performanceRun()
        let simulator = try PerfCommands.report(run, app: try hostApp(), iterations: 5, launchArguments: [], target: target(.simulator))
        let device = try PerfCommands.report(run, app: try hostApp(), iterations: 5, launchArguments: [], target: target(.device))
        #expect(simulator.text.split(separator: "\n").contains { $0 == PerfCommands.simulatorNote })
        #expect(simulator.json["note"]?.string == PerfCommands.simulatorNote)
        #expect(!device.text.contains(PerfCommands.simulatorNote))
        #expect(device.json["note"] == nil)
    }

    @Test func simulatorCPUAndMemoryReportTheAppProcess() async throws {
        let run = try await performanceRun()
        func report(_ kind: Target.Kind, metrics: [MeasureMetric]) throws -> CommandResult {
            try PerfCommands.report(
                run, app: try hostApp(), iterations: 5, launchArguments: [], target: target(kind), measure: [MeasureStep(text: "swipe up")],
                metrics: metrics)
        }
        let simulator = try report(.simulator, metrics: [.cpu, .clock])
        #expect(simulator.text.split(separator: "\n").contains { $0 == PerfCommands.simulatorProcessNote })
        #expect(simulator.json["note"]?.string == "\(PerfCommands.simulatorNote) \(PerfCommands.simulatorProcessNote)")
        #expect(!(try report(.simulator, metrics: [.clock])).text.contains(PerfCommands.simulatorProcessNote))
        #expect(!(try report(.device, metrics: [.memory])).text.contains(PerfCommands.simulatorProcessNote))
    }
}
