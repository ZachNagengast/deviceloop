//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Testing

@testable import DeviceLoopKit

private func target(osVersion: String) -> Target {
    Target(
        udid: "UDID", identifier: "UDID", name: "Test iPhone", kind: .device, deviceType: "iPhone", platform: "iOS",
        model: "fixture", productType: "fixture", osVersion: osVersion, connectionState: "connected", bootState: "booted"
    )
}

private func scenario(
    _ target: Target, setup: [String] = [], measure: [String] = ["swipe up"], metrics: [MeasureMetric] = MeasureMetric.defaults
) throws -> (scenario: MeasureScenario, unavailable: [UnavailableMetric]) {
    try PerfCommands.scenario(
        target, bundleID: "com.example.app", setup: setup, measure: measure, metrics: metrics, iterations: 3, launchArguments: [])
}

@Suite struct PerfScenarioTests {
    @Test func stepsTravelAsTheRunnerRequestsTheCLISends() throws {
        let sent = try scenario(
            target(osVersion: "27.0"), setup: ["tap id=fixture.navigation.open"], measure: ["swipe up", "sleep 500"]
        ).scenario
        let received = try JSONDecoder().decode(MeasureScenario.self, from: JSONEncoder().encode(sent))
        #expect(received == sent)
        let tap = try #require(received.setup.first)
        #expect(tap.path == RunnerWire.Path.tap)
        let tapBody = try #require(tap.body)
        #expect(
            try JSONDecoder().decode(TapRequest.self, from: Data(tapBody.utf8))
                == TapRequest(app: "com.example.app", target: ElementTarget(query: ElementQuery(id: "fixture.navigation.open")), count: 1))
        let swipe = try #require(received.measure.first)
        #expect(swipe.path == RunnerWire.Path.swipe)
        let swipeBody = try #require(swipe.body)
        #expect(
            try JSONDecoder().decode(SwipeRequest.self, from: Data(swipeBody.utf8))
                == SwipeRequest(app: "com.example.app", direction: "up"))
        #expect(received.measure.last == MeasureStep(text: "sleep 500", sleepMs: 500))
    }

    @Test func hitchBelowIOS26IsUnavailableWithTheReason() throws {
        let old = try scenario(target(osVersion: "18.7.8"))
        #expect(old.scenario.metrics == [.cpu, .memory, .clock])
        #expect(
            old.unavailable == [
                UnavailableMetric(metric: .hitch, reason: "XCTHitchMetric needs iOS 26 or later. Test iPhone runs iOS 18.7.8.")
            ])
        let current = try scenario(target(osVersion: "26.0"))
        #expect(current.scenario.metrics == MeasureMetric.defaults)
        #expect(current.unavailable.isEmpty)
    }

    @Test func aScenarioWithNoMeasurableMetricIsRefused() throws {
        let error = #expect(throws: DeviceLoopError.self) {
            try scenario(target(osVersion: "18.7.8"), metrics: [.hitch])
        }
        #expect(error?.code == .unsupportedOnTarget)
    }

    @Test func aScenarioWithoutMeasuredStepsIsRefused() throws {
        let error = #expect(throws: DeviceLoopError.self) {
            try scenario(target(osVersion: "27.0"), measure: [])
        }
        #expect(error?.code == .badArguments)
    }

    @Test func anEmptyMetricListIsRefused() throws {
        let error = #expect(throws: DeviceLoopError.self) {
            try scenario(target(osVersion: "27.0"), metrics: try PerfCommands.metrics(","))
        }
        #expect(error?.code == .badArguments)
    }

    @Test func aStepWithARefIsRefused() throws {
        let error = #expect(throws: DeviceLoopError.self) {
            try scenario(target(osVersion: "27.0"), measure: ["tap @e5"])
        }
        #expect(error?.code == .badArguments)
    }

    @Test func aTypeStepNameLeavesOutTheTypedText() throws {
        let step = try PerfCommands.step("type hunter2 id=password", app: "com.example.app")
        #expect(step.text == "type <text> id=password")
        #expect(step.body?.contains("hunter2") == true)
    }

    @Test func unknownMetricNamesAreRefused() throws {
        #expect(try PerfCommands.metrics("cpu,clock,cpu") == [.cpu, .clock])
        let error = #expect(throws: DeviceLoopError.self) {
            try PerfCommands.metrics("cpu,fps")
        }
        #expect(error?.code == .badArguments)
    }

    @Test func scrollAndSignpostMetricsTravelAsTheirNames() throws {
        let metrics = try PerfCommands.metrics("scroll,signpost:com.example.app/Feed/Load/More")
        #expect(metrics == [.scroll, .signpost(subsystem: "com.example.app", category: "Feed", name: "Load/More")])
        let sent = try scenario(target(osVersion: "27.0"), metrics: metrics).scenario
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sent)) as? [String: Any]
        #expect(json?["metrics"] as? [String] == ["scroll", "signpost:com.example.app/Feed/Load/More"])
        #expect(try JSONDecoder().decode(MeasureScenario.self, from: JSONEncoder().encode(sent)) == sent)
    }

    @Test func twoSignpostsWithOneIntervalNameAreRefused() throws {
        let error = #expect(throws: DeviceLoopError.self) {
            try scenario(
                target(osVersion: "27.0"),
                metrics: try PerfCommands.metrics("signpost:com.example.app/Feed/Load,signpost:com.example.kit/Net/Load"))
        }
        #expect(error?.code == .badArguments)
        #expect(
            error?.message
                == "signpost:com.example.app/Feed/Load and signpost:com.example.kit/Net/Load are recorded under the same XCTest name.")
    }

    @Test func aSignpostNamedLikeTheScrollIntervalIsRefusedWithScroll() throws {
        let error = #expect(throws: DeviceLoopError.self) {
            try scenario(
                target(osVersion: "27.0"),
                metrics: [.scroll, .signpost(subsystem: "com.example.app", category: "UI", name: "Scroll_DraggingAndDeceleration")])
        }
        #expect(error?.code == .badArguments)
    }

    @Test func aSignpostWithoutSubsystemCategoryAndNameIsRefused() throws {
        let error = #expect(throws: DeviceLoopError.self) {
            try PerfCommands.metrics("signpost:com.example.app/Feed")
        }
        #expect(error?.code == .badArguments)
    }

    @Test func aMetricMissingFromTheBundleIsReportedUnavailable() async throws {
        let run = try await performanceRun()
        #expect(
            PerfCommands.missing([.cpu, .clock], in: run) == [
                UnavailableMetric(metric: .cpu, reason: "The result bundle has no cpu measurements.")
            ])
    }

    @Test func aSignpostIntervalTheAppNeverEmittedIsUnavailable() async throws {
        var run = try await performanceRun()
        let clock = try #require(run.result?.metrics?.first)
        for name in ["OpenDetail", "Scroll_DraggingAndDeceleration"] {
            var signpost = clock
            signpost.identifier = "com.apple.dt.XCTMetric_OSSignpost-\(name).duration"
            signpost.displayName = "Duration (\(name))"
            run.result?.metrics?.append(signpost)
        }
        let misspelled = MeasureMetric.signpost(subsystem: "com.argmaxinc.deviceloop.host", category: "fixture", name: "OpenDetial")
        let metrics = [.scroll, .signpost(subsystem: "com.argmaxinc.deviceloop.host", category: "fixture", name: "OpenDetail"), misspelled]
        #expect(
            PerfCommands.missing(metrics, in: run) == [
                UnavailableMetric(metric: misspelled, reason: "The result bundle has no \(misspelled.rawValue) measurements.")
            ])
    }

    @Test func runReportListsUnavailableMetricsAndSteps() async throws {
        let unavailable = [UnavailableMetric(metric: .hitch, reason: "XCTHitchMetric needs iOS 26 or later. Test iPhone runs iOS 18.7.8.")]
        let result = try PerfCommands.report(
            try await performanceRun(), app: try hostApp(), iterations: 5, launchArguments: [], target: target(osVersion: "18.7.8"),
            setup: [MeasureStep(text: "tap id=open")], measure: [MeasureStep(text: "swipe up")], unavailable: unavailable)
        let lines = result.text.split(separator: "\n")
        #expect(lines.dropFirst().first == "app com.argmaxinc.deviceloop.host 1.0 (1), 5 iterations")
        #expect(lines.contains("UNAVAILABLE hitch: XCTHitchMetric needs iOS 26 or later. Test iPhone runs iOS 18.7.8."))
        #expect(result.json["unavailable"]?.array?.first?["metric"]?.string == "hitch")
        #expect(result.json["measure"]?.array?.first?.string == "swipe up")
    }

    @Test func runReportStepsLeaveOutTypedText() async throws {
        let result = try PerfCommands.report(
            try await performanceRun(), app: try hostApp(), iterations: 5, launchArguments: [], target: target(osVersion: "27.0"),
            measure: [try PerfCommands.step("type hunter2 id=password", app: "com.argmaxinc.deviceloop.host")])
        #expect(result.json["measure"]?.array?.first?.string == "type <text> id=password")
    }
}
