//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Testing

@testable import DeviceLoopKit

private let simulator = XCResult.Device(
    deviceId: "00000000-0000-0000-0000-000000000108", deviceName: "iPhone 17 Pro", platform: "iOS Simulator", osVersion: "27.0",
    osBuildNumber: "24A434")

private func launchMetric(_ measurements: [Double], unit: String = "s") -> XCResult.Metric {
    let sorted = measurements.sorted()
    return XCResult.Metric(
        test: "DeviceLoopMeasure/testLaunch()", device: simulator, configuration: "Test Scheme Action",
        identifier: "com.apple.dt.XCTMetric_ApplicationLaunch-AppLaunch.duration", displayName: "Duration (AppLaunch)",
        unitOfMeasurement: unit, measurements: measurements, count: sorted.count, median: sorted[sorted.count / 2],
        mean: sorted.reduce(0, +) / Double(sorted.count), min: sorted[0], max: sorted[sorted.count - 1])
}

private func run(
    _ measurements: [Double], device: XCResult.Device = simulator, unit: String = "s", scenario: String? = "com.argmaxinc.deviceloop.host"
) -> PerfComparison.Side {
    PerfComparison.Side(
        path: "/jobs/summary.json", devices: [device], scenario: scenario, metrics: [launchMetric(measurements, unit: unit)])
}

private func temporaryJobDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "deviceloop-perf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// A `perf run` job in `directory` with its `summary.json` and `perf.json`.
@discardableResult
private func perfJob(in directory: URL) async throws -> CommandResult {
    var job = try await performanceRun()
    job.directory = directory.path
    try JSONEncoder().encode(job).write(to: directory.appending(path: "summary.json"))
    let perf = try PerfCommands.report(
        job, app: try hostApp(), iterations: 5, launchArguments: ["-DeviceLoopLaunchDelayMs", "300"],
        target: Target(
            udid: "UDID", identifier: "UDID", name: "Test iPhone", kind: .simulator, deviceType: "iPhone", platform: "iOS",
            model: "fixture", productType: "fixture", osVersion: "27.0", connectionState: "connected", bootState: "booted"),
        setup: [MeasureStep(text: "tap id=open")], measure: [MeasureStep(text: "swipe up")])
    return try PerfCommands.saved(perf, in: job)
}

private let fast = [2.40, 2.41, 2.42, 2.43, 2.44]
private let slow = [2.70, 2.71, 2.72, 2.73, 2.74]

@Suite struct PerfCompareTests {
    @Test func separateRangesWithFiveMeasurementsAreDifferent() throws {
        let comparison = PerfCommands.comparison(run(fast), run(slow))
        #expect(comparison.verdict == .different)
        let metric = try #require(comparison.metrics.first)
        #expect(metric.verdict == .different)
        #expect(abs((metric.delta ?? 0) - 0.30) < 1e-9)
        #expect(abs((metric.percentDelta ?? 0) - 0.30 / 2.42 * 100) < 1e-9)
    }

    @Test func overlappingRangesAreNoDifferenceDetected() {
        let comparison = PerfCommands.comparison(run(fast), run([2.44, 2.45, 2.46, 2.47, 2.48]))
        #expect(comparison.verdict == .noDifferenceDetected)
        #expect(comparison.metrics.map(\.verdict) == [.noDifferenceDetected])
    }

    @Test func fewerThanFiveMeasurementsAreInconclusive() {
        let comparison = PerfCommands.comparison(run(Array(fast.prefix(4))), run(slow))
        #expect(comparison.verdict == .inconclusive)
        #expect(comparison.metrics.first?.reason == "A run has fewer than 5 measurements.")
    }

    @Test func differentDevicesAreInconclusive() {
        var device = simulator
        device.deviceId = "00008130-0000000000000000"
        device.deviceName = "iPhone 15 Pro Max"
        let comparison = PerfCommands.comparison(run(fast), run(slow, device: device))
        #expect(comparison.verdict == .inconclusive)
        #expect(comparison.metrics.map(\.verdict) == [.inconclusive])
        #expect(comparison.reasons.contains { $0.hasPrefix("The devices differ:") })
    }

    @Test func differentOrUnknownOSBuildsAreInconclusive() {
        var updated = simulator
        updated.osBuildNumber = "24A500"
        var unknown = simulator
        unknown.osBuildNumber = nil
        #expect(PerfCommands.comparison(run(fast), run(slow, device: updated)).verdict == .inconclusive)
        let comparison = PerfCommands.comparison(run(fast, device: unknown), run(slow, device: unknown))
        #expect(comparison.verdict == .inconclusive)
        #expect(comparison.reasons == ["The OS builds differ or are unknown: unknown and unknown."])
    }

    @Test func differentUnitsAreInconclusive() {
        let comparison = PerfCommands.comparison(run(fast), run(slow.map { $0 * 1000 }, unit: "ms"))
        #expect(comparison.verdict == .inconclusive)
        #expect(comparison.metrics.first?.reason == "The units differ: s and ms.")
        #expect(comparison.metrics.first?.delta == nil)
    }

    @Test func differentScenariosAreInconclusive() {
        let comparison = PerfCommands.comparison(run(fast), run(slow, scenario: "com.apple.Preferences"))
        #expect(comparison.verdict == .inconclusive)
        #expect(comparison.reasons == ["The scenarios differ: com.argmaxinc.deviceloop.host and com.apple.Preferences."])
    }

    @Test func aMetricInOneRunIsInconclusive() {
        var candidate = run(slow)
        candidate.metrics[0].identifier = "com.apple.dt.XCTMetric_Clock.time.monotonic"
        let comparison = PerfCommands.comparison(run(fast), candidate)
        #expect(comparison.verdict == .inconclusive)
        #expect(comparison.metrics.compactMap(\.reason) == ["Only in the baseline.", "Only in the candidate."])
    }

    @Test func repeatedEntriesOfOneMetricPairInOrder() {
        var side = run(fast)
        side.metrics.append(launchMetric(slow))
        let comparison = PerfCommands.comparison(side, side)
        #expect(comparison.metrics.map(\.verdict) == [.noDifferenceDetected, .noDifferenceDetected])
        #expect(comparison.metrics.map { $0.baseline?.median } == [2.42, 2.72])
        #expect(comparison.metrics.map { $0.candidate?.median } == [2.42, 2.72])
    }

    @Test func anExtraRepeatedEntryIsOnlyInItsRun() {
        var baseline = run(fast)
        baseline.metrics.append(launchMetric(slow))
        let comparison = PerfCommands.comparison(baseline, run(fast))
        #expect(comparison.metrics.map { $0.candidate?.median } == [2.42, nil])
        #expect(comparison.metrics.compactMap(\.reason) == ["Only in the baseline."])
    }

    @Test func textHasMediansDeltaRangesAndCounts() {
        let lines = PerfCommands.text(PerfCommands.comparison(run(fast), run(slow))).split(separator: "\n")
        #expect(lines.first == "different, 1 metric")
        #expect(
            String(lines.last ?? "")
                == "DIFFERENT DeviceLoopMeasure/testLaunch() Duration (AppLaunch): median 2.42 s and 2.72 s, delta 0.3 s (+12.4%), "
                + "range 2.4 to 2.44 s and 2.7 to 2.74 s, n 5 and 5")
    }

    @Test func aJobDirectoryReadsTheScenarioFromPerfJSON() async throws {
        let directory = try temporaryJobDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await perfJob(in: directory)
        let recorded = try await performanceRun().result?.metrics

        let side = try await PerfCommands.side(directory)
        #expect(side.scenario == "com.argmaxinc.deviceloop.host, setup tap id=open, measure swipe up")
        #expect(side.launchArguments == ["-DeviceLoopLaunchDelayMs", "300"])
        #expect(side.devices.map(\.osBuildNumber) == ["24A434"])
        #expect(side.metrics == recorded)
    }

    @Test func aPerfJobListsItsPerfJSON() async throws {
        let directory = try temporaryJobDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await perfJob(in: directory)
        let file = directory.appending(path: "perf.json")
        #expect(result.text.split(separator: "\n").last.map(String.init) == "perf \(file.path)")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
