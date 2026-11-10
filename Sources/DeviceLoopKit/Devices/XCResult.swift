//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// Reads `.xcresult` bundles with `xcrun xcresulttool get`, pinned to one output schema.
public enum XCResult {
    /// The schema every `xcresulttool get` call asks for. Xcode 27.2 defaults to it.
    public static let schemaVersion = "0.5.0"

    public struct Device: Codable, Sendable, Equatable {
        public var deviceId: String
        public var deviceName: String
        /// `iOS Simulator`, `iOS` and so on.
        public var platform: String?
        public var osVersion: String?
        /// For example `24A434`.
        public var osBuildNumber: String?
    }

    public struct DeviceAndConfiguration: Codable, Sendable, Equatable {
        public var device: Device
    }

    public struct TestFailure: Codable, Sendable, Equatable {
        /// `DeliberateFailure/testMismatch()`, without the test target.
        public var testIdentifierString: String
        public var testName: String
        public var targetName: String
        public var failureText: String
    }

    /// `get test-results summary`.
    public struct Summary: Codable, Sendable, Equatable {
        /// `Passed`, `Failed`, `Skipped`, `Expected Failure` or `unknown`.
        public var result: String
        public var totalTestCount: Int
        public var passedTests: Int
        public var failedTests: Int
        public var skippedTests: Int
        public var expectedFailures: Int
        /// Seconds since 1970.
        public var startTime: Double?
        public var finishTime: Double?
        public var devicesAndConfigurations: [DeviceAndConfiguration]
        public var testFailures: [TestFailure]
    }

    /// One `Test Case` node from `get test-results tests`.
    public struct TestCase: Codable, Sendable, Equatable {
        /// Test target, then the node identifier, for example `SuiteFixtureTests/DeliberateFailure/testMismatch()`.
        public var identifier: String
        public var result: String
        public var durationInSeconds: Double?
        /// The `Failure Message` nodes anywhere under the test case.
        public var failureMessages: [String]
    }

    public struct Issue: Codable, Sendable, Equatable {
        public var message: String
        /// `file:///path/File.swift#...StartingLineNumber=30...`, with a zero-based line number.
        public var sourceURL: String?
    }

    /// `get build-results`.
    public struct BuildResults: Codable, Sendable, Equatable {
        /// For example `succeeded`, `failed` or `notRequested`.
        public var status: String?
        public var destination: Device
        public var errors: [Issue]
    }

    /// One metric of one test run, from `get test-results metrics`, with statistics over its measurements.
    public struct Metric: Codable, Sendable, Equatable {
        public var source = "xctest"
        /// `Performance/testClock()`, without the test target.
        public var test: String
        public var device: Device
        /// The test plan configuration name.
        public var configuration: String
        /// For example `com.apple.dt.XCTMetric_Clock.time.monotonic`.
        public var identifier: String?
        public var displayName: String
        public var unitOfMeasurement: String
        public var measurements: [Double]
        public var count: Int
        public var median: Double
        public var mean: Double
        public var min: Double
        public var max: Double
        /// Sample standard deviation, nil with fewer than two measurements.
        public var standardDeviation: Double?
        public var baselineAverage: Double?
        public var maxPercentRegression: Double?
    }

    /// What one bundle holds. `summary` and `tests` are nil when the bundle has no test results, and `metrics` is nil
    /// when it has no metrics.
    public struct Report: Codable, Sendable, Equatable {
        public var bundle: String
        public var build: BuildResults
        public var summary: Summary?
        public var tests: [TestCase]?
        public var metrics: [Metric]?
    }

    struct ContentAvailability: Decodable {
        var hasTestResults: Bool
    }

    struct TestNode: Decodable {
        var nodeType: String
        var name: String
        var nodeIdentifier: String?
        var result: String?
        var durationInSeconds: Double?
        var children: [TestNode]?
    }

    struct Tests: Decodable {
        var testNodes: [TestNode]
    }

    struct TestMetrics: Decodable {
        struct Run: Decodable {
            struct Configuration: Decodable {
                var configurationName: String
            }

            struct Measured: Decodable {
                var identifier: String?
                var displayName: String
                var unitOfMeasurement: String
                var measurements: [Double]
                var baselineAverage: Double?
                var maxPercentRegression: Double?
            }

            var testPlanConfiguration: Configuration
            var device: Device
            var metrics: [Measured]
        }

        var testIdentifier: String
        var testRuns: [Run]
    }

    /// Reads the build results, and the test summary, test cases and metrics when the bundle has test results. Each
    /// metric gets the summary's device of the same ID.
    public static func read(_ bundle: URL) async throws -> Report {
        try await read(bundle) { subcommand in
            let result = try await Shell.run(
                ["xcrun", "xcresulttool", "get"] + subcommand + ["--path", bundle.path, "--schema-version", schemaVersion, "--compact"]
            )
            guard result.succeeded else {
                let selected = try? await Shell.run(["xcode-select", "-p"], timeout: .seconds(10))
                throw failure(result.stderrString, bundle: bundle, developerDir: selected?.stdoutString ?? "")
            }
            return result.stdout
        }
    }

    /// `get` returns the output of `xcresulttool get <subcommand>`.
    static func read(_ bundle: URL, get: ([String]) async throws -> Data) async throws -> Report {
        let decoder = JSONDecoder()
        let availability = try decoder.decode(ContentAvailability.self, from: try await get(["content-availability"]))
        var report = Report(
            bundle: bundle.path,
            build: try decoder.decode(BuildResults.self, from: try await get(["build-results"]))
        )
        if availability.hasTestResults {
            report.summary = try decoder.decode(Summary.self, from: try await get(["test-results", "summary"]))
            report.tests = testCases(try decoder.decode(Tests.self, from: try await get(["test-results", "tests"])).testNodes)
            let devices = report.summary?.devicesAndConfigurations.map(\.device) ?? []
            report.metrics = metrics(try decoder.decode([TestMetrics].self, from: try await get(["test-results", "metrics"])))?
                .map { metric in
                    var metric = metric
                    if let device = devices.first(where: { $0.deviceId == metric.device.deviceId }) { metric.device = device }
                    return metric
                }
        }
        return report
    }

    /// One metric per test, run and metric that has measurements, or nil when there are none.
    static func metrics(_ tests: [TestMetrics]) -> [Metric]? {
        let metrics = tests.flatMap { test in
            test.testRuns.flatMap { run in
                run.metrics.compactMap { measured -> Metric? in
                    let sorted = measured.measurements.sorted()
                    guard let first = sorted.first, let last = sorted.last else { return nil }
                    let count = sorted.count
                    let mean = sorted.reduce(0, +) / Double(count)
                    let variance = sorted.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(count - 1)
                    return Metric(
                        test: test.testIdentifier, device: run.device, configuration: run.testPlanConfiguration.configurationName,
                        identifier: measured.identifier, displayName: measured.displayName,
                        unitOfMeasurement: measured.unitOfMeasurement, measurements: measured.measurements, count: count,
                        median: count % 2 == 1 ? sorted[count / 2] : (sorted[count / 2 - 1] + sorted[count / 2]) / 2,
                        mean: mean, min: first, max: last, standardDeviation: count > 1 ? variance.squareRoot() : nil,
                        // xcresulttool reports a baseline average of 0 for a test without a baseline.
                        baselineAverage: measured.baselineAverage == 0 ? nil : measured.baselineAverage,
                        maxPercentRegression: measured.maxPercentRegression
                    )
                }
            }
        }
        return metrics.isEmpty ? nil : metrics
    }

    static func testCases(_ nodes: [TestNode], target: String? = nil) -> [TestCase] {
        nodes.flatMap { node -> [TestCase] in
            switch node.nodeType {
                case "Test Case":
                    let identifier = node.nodeIdentifier ?? node.name
                    return [
                        TestCase(
                            identifier: target.map { "\($0)/\(identifier)" } ?? identifier,
                            result: node.result ?? "unknown",
                            durationInSeconds: node.durationInSeconds,
                            failureMessages: failureMessages(node.children ?? [])
                        )
                    ]
                case "Unit test bundle", "UI test bundle":
                    return testCases(node.children ?? [], target: node.name)
                default:
                    return testCases(node.children ?? [], target: target)
            }
        }
    }

    private static func failureMessages(_ nodes: [TestNode]) -> [String] {
        nodes.flatMap { $0.nodeType == "Failure Message" ? [$0.name] : failureMessages($0.children ?? []) }
    }

    static func failure(_ stderr: String, bundle: URL, developerDir: String) -> DeviceLoopError {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("Unknown schema version") || message.contains("unable to find utility") {
            let selected = developerDir.trimmingCharacters(in: .whitespacesAndNewlines)
            return DeviceLoopError(
                .xcodeMissing,
                "The selected developer directory has no xcresulttool that reads result schema \(schemaVersion).",
                fix: "Select Xcode 27.2 or later in place of \(selected.isEmpty ? "the current one" : selected): "
                    + "sudo xcode-select -s /Applications/Xcode.app",
                detail: message
            )
        }
        let reason = message.split(separator: "\n").first.map { String($0.trimmingPrefix("Error: ")) } ?? "no output"
        return DeviceLoopError(
            .badArguments,
            "xcresulttool could not read \(bundle.path): \(reason)",
            fix: "Pass a complete .xcresult bundle, for example one from xcodebuild -resultBundlePath.",
            detail: message
        )
    }
}

extension XCResult.Issue {
    /// `/path/File.swift:31`, one-based, or nil without a source URL.
    public var location: String? {
        guard let sourceURL, let url = URL(string: sourceURL), url.isFileURL else { return nil }
        let line = url.fragment?.split(separator: "&").first { $0.hasPrefix("StartingLineNumber=") }
            .flatMap { Int($0.dropFirst("StartingLineNumber=".count)) }
        return url.path + (line.map { ":\($0 + 1)" } ?? "")
    }
}
