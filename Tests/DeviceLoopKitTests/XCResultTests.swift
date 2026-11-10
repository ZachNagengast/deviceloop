//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

func recorded(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Resources/xcresulttool/\(name)", withExtension: "json"))
    return try Data(contentsOf: url)
}

/// Reads a SuiteFixture bundle from `xcresulttool get` output recorded with Xcode 27.2.
func recordedReport(_ scenario: String) async throws -> XCResult.Report {
    try await XCResult.read(URL(filePath: "/results/\(scenario).xcresult")) { subcommand in
        if subcommand == ["content-availability"], scenario != "build-only" {
            return try recorded("content-availability")
        }
        return try recorded("\(subcommand.last ?? "")-\(scenario)")
    }
}

private let simulatorUDID = "00000000-0000-0000-0000-000000000108"
private let mismatch = #"XCTAssertEqual failed: ("2") is not equal to ("3")"#

@Suite struct XCResultTests {
    @Test func passingSummaryDecodesResultCountsAndDevice() async throws {
        let summary = try #require(try await recordedReport("pass").summary)
        #expect(summary.result == "Passed")
        let counts: [Int] = [summary.totalTestCount, summary.passedTests, summary.failedTests, summary.skippedTests]
        #expect(counts == [2, 2, 0, 0])
        #expect(summary.devicesAndConfigurations.map(\.device.deviceId) == [simulatorUDID])
        #expect(summary.testFailures.isEmpty)
    }

    @Test func failingSummaryNamesTheTestAndMessage() async throws {
        let summary = try #require(try await recordedReport("failure").summary)
        #expect(summary.result == "Failed")
        #expect(
            summary.testFailures == [
                XCResult.TestFailure(
                    testIdentifierString: "DeliberateFailure/testMismatch()",
                    testName: "testMismatch()",
                    targetName: "SuiteFixtureTests",
                    failureText: mismatch
                )
            ]
        )
    }

    @Test func testCasesCarryTargetAndFailureMessages() async throws {
        let tests = try #require(try await recordedReport("failure").tests)
        #expect(tests.map(\.identifier) == ["SuiteFixtureTests/DeliberateFailure/testMismatch()"])
        #expect(tests.first?.result == "Failed")
        #expect(tests.first?.failureMessages == [mismatch])
    }

    @Test func swiftTestingCaseListsBesideUITest() async throws {
        let tests = try #require(try await recordedReport("swift-testing").tests)
        #expect(tests.map(\.identifier) == ["SuiteFixtureTests/swiftTestingPasses()", "SuiteFixtureUITests/TapUITests/testTapCounts()"])
        #expect(tests.allSatisfy { $0.result == "Passed" && $0.failureMessages.isEmpty })
    }

    @Test func buildErrorHasOneBasedSourceLocation() async throws {
        let build = try await recordedReport("build-error").build
        #expect(build.status == "failed")
        #expect(build.errors.map(\.location) == [nil, "/Users/dev/deviceloop/Examples/SuiteFixture/SuiteFixture/SuiteFixtureApp.swift:31"])
    }

    @Test func bundleWithoutTestResultsLeavesTestsAbsent() async throws {
        let report = try await recordedReport("build-only")
        #expect(report.summary == nil)
        #expect(report.tests == nil)
    }

    @Test func unknownSchemaVersionNamesSelectedXcode() {
        let error = XCResult.failure(
            "Error: Unknown schema version provided: 0.5.0.\n",
            bundle: URL(filePath: "/results/old.xcresult"),
            developerDir: "/Applications/Xcode-27.1.app/Contents/Developer\n"
        )
        #expect(error.code == .xcodeMissing)
        #expect(error.fix?.contains("/Applications/Xcode-27.1.app/Contents/Developer") == true)
    }

    @Test func commandLineToolsWithoutXcresulttoolIsXcodeMissing() {
        let error = XCResult.failure(
            #"xcrun: error: unable to find utility "xcresulttool", not a developer tool or in PATH"#,
            bundle: URL(filePath: "/results/pass.xcresult"),
            developerDir: "/Library/Developer/CommandLineTools"
        )
        #expect(error.code == .xcodeMissing)
    }

    @Test func failureTextStartsWithDestinationAndEndsWithBundle() async throws {
        let lines = TestCommands.text(try await recordedReport("failure")).split(separator: "\n")
        #expect(lines.first == "iPhone 15 Pro Max (iOS Simulator 27.0, \(simulatorUDID))")
        #expect(lines.contains("FAIL SuiteFixtureTests/DeliberateFailure/testMismatch(): \(mismatch)"))
        #expect(lines.last == "/results/failure.xcresult")
    }

    @Test func destinationComesFromBuildWhenNoTestsRan() async throws {
        let text = TestCommands.text(try await recordedReport("build-error"))
        #expect(text.hasPrefix("iPhone 15 Pro Max (iOS Simulator 27.0, \(simulatorUDID))\n"))
    }

    @Test func performanceMetricsDecodeWithUnitsAndEveryMeasurement() async throws {
        let metrics = try #require(try await recordedReport("perf").metrics)
        #expect(metrics.map(\.test) == ["Performance/testClock()", "Performance/testLaunch()"])
        #expect(
            metrics.map(\.identifier) == [
                "com.apple.dt.XCTMetric_Clock.time.monotonic", "com.apple.dt.XCTMetric_ApplicationLaunch-AppLaunch.duration",
            ])
        #expect(metrics.allSatisfy { $0.source == "xctest" && $0.unitOfMeasurement == "s" })
        #expect(metrics.map(\.device.deviceId) == [simulatorUDID, simulatorUDID])
        #expect(metrics.map(\.configuration) == ["Test Scheme Action", "Test Scheme Action"])
        #expect(metrics[1].measurements == [2.60815625, 2.636487208, 2.538586083, 2.454572084, 2.582291833])
    }

    @Test func metricDeviceComesFromTheSummary() async throws {
        let report = try await recordedReport("perf")
        let metrics = try #require(report.metrics)
        let device = try #require(report.summary?.devicesAndConfigurations.first?.device)
        #expect(device.platform == "iOS Simulator")
        #expect(device.osBuildNumber == "24A434")
        #expect(metrics.allSatisfy { $0.device == device })
    }

    @Test func metricStatisticsMatchHandComputedValues() async throws {
        let clock = try #require(try await recordedReport("perf").metrics?.first)
        #expect(clock.count == 5)
        #expect(clock.median == 0.027501570000000003)
        #expect(clock.min == 0.021398597000000002)
        #expect(clock.max == 0.05313682)
        #expect(abs(clock.mean - 0.0311989418) < 1e-12)
        #expect(abs((clock.standardDeviation ?? 0) - 0.012536880280471521) < 1e-12)
    }

    @Test func zeroBaselineAverageIsAbsent() async throws {
        let clock = try #require(try await recordedReport("perf").metrics?.first)
        #expect(clock.baselineAverage == nil)
        #expect(clock.maxPercentRegression == 10)
    }

    @Test func evenCountMedianAveragesTheMiddleTwo() throws {
        let tests = try JSONDecoder().decode(
            [XCResult.TestMetrics].self,
            from: Data(
                """
                [{"testIdentifier": "Performance/testClock()", "testRuns": [{
                    "testPlanConfiguration": {"configurationId": "1", "configurationName": "Test Scheme Action"},
                    "device": {"deviceId": "UDID", "deviceName": "iPhone"},
                    "metrics": [{"displayName": "Clock Monotonic Time", "unitOfMeasurement": "s", "measurements": [4, 1, 3, 2]}]
                }]}]
                """.utf8)
        )
        #expect(XCResult.metrics(tests)?.first?.median == 2.5)
    }

    @Test func emptyMetricsAreUnavailable() async throws {
        #expect(try await recordedReport("pass").metrics == nil)
    }

    @Test func metricTextNamesTestUnitAndStatistics() async throws {
        let lines = TestCommands.text(try await recordedReport("perf")).split(separator: "\n")
        #expect(
            lines.contains(
                "METRIC Performance/testClock() Clock Monotonic Time: median 0.0275016 s, mean 0.0311989 s, sd 0.0125369 s, "
                    + "min 0.0213986 s, max 0.0531368 s, n 5"))
    }

    @Test func buildErrorTextListsEachError() async throws {
        let lines = TestCommands.text(try await recordedReport("build-error")).split(separator: "\n")
        #expect(lines.contains("No test results"))
        #expect(!lines.contains { $0.hasPrefix("Tests unknown") })
        #expect(lines.contains("Build failed: 2 errors"))
        let path = "/Users/dev/deviceloop/Examples/SuiteFixture/SuiteFixture/SuiteFixtureApp.swift"
        #expect(lines.contains("ERROR \(path):31: Cannot convert value of type 'String' to specified type 'Int'"))
    }
}
