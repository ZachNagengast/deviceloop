//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation

/// One `perf launch` or `perf run` job.
struct PerfJob: Codable, Sendable {
    var job: String
    /// `passed`, `failed` or `cancelled`, as in `test run`.
    var status: String
    var cancelReason: String?
    /// The app as the installed-apps listing reports it.
    var app: InstalledApp
    var iterations: Int
    var launchArguments: [String]
    /// `perf run` steps, with `<text>` in place of typed text.
    var setup: [String]?
    var measure: [String]?
    /// `perf run` metrics without measurements, and why.
    var unavailable: [UnavailableMetric]?
    /// The destination from the result bundle, with its OS build.
    var device: XCResult.Device?
    var metrics: [XCResult.Metric]
    /// Set on a simulator.
    var note: String?
    var directory: String
    /// The job's `test run` summary.
    var summary: String
}

/// A requested metric the run has no measurements for.
struct UnavailableMetric: Codable, Sendable, Equatable {
    var metric: MeasureMetric
    var reason: String
}

/// `perf compare`: the verdict over two runs' metrics, why it is inconclusive, and each metric of both runs.
struct PerfComparison: Codable, Sendable {
    enum Verdict: String, Codable, Sendable {
        case different
        case noDifferenceDetected = "no_difference_detected"
        case inconclusive
    }

    /// One run as read from a `summary.json` or result bundle.
    struct Side: Codable, Sendable {
        /// The `summary.json` or result bundle read.
        var path: String
        /// Each destination of the run once.
        var devices: [XCResult.Device]
        /// From the job's `perf.json`, nil for other runs.
        var app: InstalledApp?
        var launchArguments: [String]?
        /// The perf job's app and steps, nil for other runs.
        var scenario: String?
        var metrics: [XCResult.Metric] = []

        private enum CodingKeys: String, CodingKey {
            case path, devices, app, launchArguments, scenario
        }
    }

    /// One metric of both runs, matched by test, configuration and identifier.
    struct Metric: Codable, Sendable {
        var test: String
        var configuration: String
        var identifier: String?
        var displayName: String
        var verdict: Verdict
        var reason: String?
        var baseline: XCResult.Metric?
        var candidate: XCResult.Metric?
        /// Candidate median minus baseline median, when the units match.
        var delta: Double?
        var percentDelta: Double?
    }

    var verdict: Verdict
    var baseline: Side
    var candidate: Side
    /// Why every metric is inconclusive.
    var reasons: [String]
    var metrics: [Metric]
}

public enum PerfCommands {
    static let simulatorNote = "Simulator timings come from this Mac, not from iPhone or iPad hardware."
    static let simulatorProcessNote = "Simulator CPU and memory metrics report the app process, not the measured steps."
    private static let metricFix = "Pass --metric with hitch, cpu, memory, clock, scroll or signpost:<subsystem>/<category>/<name>."

    /// Launches `bundleID` under XCTApplicationLaunchMetric in a `test run` job of the cached runner build that runs
    /// only `DeviceLoopMeasure/testLaunch`.
    public static func launch(
        _ target: Target, bundleID: String, iterations: Int = 5, launchArguments: [String] = [],
        timeout: Duration = .seconds(600), stopRunner: Bool = false
    ) async throws -> CommandResult {
        guard iterations > 0 else { throw DeviceLoopError.usage("--iterations must be at least 1.") }
        let (run, app) = try await measureJob(
            target, test: "testLaunch",
            scenario: MeasureScenario(bundleID: bundleID, iterations: iterations, launchArguments: launchArguments),
            timeout: timeout, stopRunner: stopRunner
        )
        return try saved(report(run, app: app, iterations: iterations, launchArguments: launchArguments, target: target), in: run)
    }

    /// Measures the `measure` steps in `bundleID` with `metrics` in a `test run` job of the cached runner build that runs
    /// only `DeviceLoopMeasure/testScenario`. Each iteration relaunches the app and runs `setup` outside the measured interval.
    public static func run(
        _ target: Target, bundleID: String, setup: [String] = [], measure: [String], metrics: [MeasureMetric] = MeasureMetric.defaults,
        iterations: Int = 5, launchArguments: [String] = [], timeout: Duration = .seconds(600), stopRunner: Bool = false
    ) async throws -> CommandResult {
        let (scenario, unavailable) = try self.scenario(
            target, bundleID: bundleID, setup: setup, measure: measure, metrics: metrics, iterations: iterations,
            launchArguments: launchArguments)
        let (run, app) = try await measureJob(target, test: "testScenario", scenario: scenario, timeout: timeout, stopRunner: stopRunner)
        let result = try report(
            run, app: app, iterations: iterations, launchArguments: launchArguments, target: target, setup: scenario.setup,
            measure: scenario.measure, metrics: scenario.metrics, unavailable: unavailable + missing(scenario.metrics, in: run))
        return try saved(result, in: run)
    }

    /// Parses a comma-separated metric list such as `hitch,cpu,memory,clock` or `clock,signpost:com.example/Feed/Load`.
    public static func metrics(_ list: String) throws -> [MeasureMetric] {
        var metrics: [MeasureMetric] = []
        for name in list.split(separator: ",") {
            guard let metric = MeasureMetric(rawValue: String(name)) else {
                throw DeviceLoopError(.badArguments, "Unknown metric \"\(name)\".", fix: metricFix)
            }
            if !metrics.contains(metric) { metrics.append(metric) }
        }
        return metrics
    }

    /// The `testScenario` scenario, and the requested metrics the target's OS cannot measure.
    static func scenario(
        _ target: Target, bundleID: String, setup: [String], measure: [String], metrics: [MeasureMetric], iterations: Int,
        launchArguments: [String]
    ) throws -> (scenario: MeasureScenario, unavailable: [UnavailableMetric]) {
        guard iterations > 0 else { throw DeviceLoopError.usage("--iterations must be at least 1.") }
        guard !measure.isEmpty else {
            throw DeviceLoopError(
                .badArguments, "Nothing to measure.", fix: "Pass at least one --measure step, for example --measure 'swipe up'.")
        }
        guard !metrics.isEmpty else { throw DeviceLoopError(.badArguments, "No metric requested.", fix: metricFix) }
        for (index, metric) in metrics.enumerated() {
            if let earlier = metrics[..<index].first(where: { identifierPrefix($0) == identifierPrefix(metric) }) {
                throw DeviceLoopError(
                    .badArguments, "\(earlier.rawValue) and \(metric.rawValue) are recorded under the same XCTest name.",
                    fix: "Request each signpost interval name once. XCTest names signpost measurements after the interval name only.")
            }
        }
        var unavailable: [UnavailableMetric] = []
        if metrics.contains(.hitch), let major = Int(target.osVersion.prefix { $0 != "." }), major < 26 {
            let reason = "XCTHitchMetric needs iOS 26 or later. \(target.name) runs iOS \(target.osVersion)."
            unavailable.append(UnavailableMetric(metric: .hitch, reason: reason))
        }
        let measured = metrics.filter { metric in !unavailable.contains { $0.metric == metric } }
        guard !measured.isEmpty else {
            throw DeviceLoopError(
                .unsupportedOnTarget, "No requested metric can be measured on \(target.summary).",
                fix: "Pass --metric with cpu, memory or clock.", detail: unavailable.map(\.reason).joined(separator: " "),
                device: target.name)
        }
        let scenario = MeasureScenario(
            bundleID: bundleID, iterations: iterations, launchArguments: launchArguments,
            setup: try setup.map { try step($0, app: bundleID) }, measure: try measure.map { try step($0, app: bundleID) },
            metrics: measured)
        return (scenario, unavailable)
    }

    /// One step in the `ui` step grammar as the runner request the CLI sends for it.
    static func step(_ text: String, app: String) throws -> MeasureStep {
        let step = try UIStep.parse(text)
        var measureStep = MeasureStep(text: text)
        let target: ElementTarget?
        switch step {
            case .tap(let element, _, _): target = element
            case .swipe(_, let on, _): target = on
            case .type(_, let into, _):
                target = into
                measureStep.text = (["type", "<text>"] + UIStep.tokenize(text).dropFirst(2)).joined(separator: " ")
            case .sleep(let ms):
                target = nil
                measureStep.sleepMs = ms
            default: target = nil
        }
        if target?.ref != nil {
            throw DeviceLoopError(
                .badArguments, "Step \"\(measureStep.text)\" uses a ref, and a perf run takes no tree.",
                fix: "Use a label, id= or a point.")
        }
        if let request = UICommands.request(for: step, app: app) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            measureStep.path = request.path
            measureStep.body = String(decoding: try encoder.encode(request.body), as: UTF8.self)
        }
        return measureStep
    }

    /// The metrics `run` has no measurements for.
    static func missing(_ metrics: [MeasureMetric], in run: TestRun) -> [UnavailableMetric] {
        let identifiers = (run.result?.metrics ?? []).compactMap(\.identifier)
        return metrics.filter { metric in !identifiers.contains { $0.hasPrefix(identifierPrefix(metric)) } }.map {
            UnavailableMetric(metric: $0, reason: "The result bundle has no \($0.rawValue) measurements.")
        }
    }

    private static func identifierPrefix(_ metric: MeasureMetric) -> String {
        switch metric {
            case .hitch: return "com.apple.dt.XCTMetric_Hitch"
            case .cpu: return "com.apple.dt.XCTMetric_CPU"
            case .memory: return "com.apple.dt.XCTMetric_Memory"
            case .clock: return "com.apple.dt.XCTMetric_Clock"
            case .scroll: return "com.apple.dt.XCTMetric_OSSignpost-Scroll_DraggingAndDeceleration."
            case .signpost(_, _, let name): return "com.apple.dt.XCTMetric_OSSignpost-\(name)."
        }
    }

    /// Runs `DeviceLoopMeasure/<test>` with `scenario` as a `test run` job of the cached runner build.
    private static func measureJob(
        _ target: Target, test: String, scenario: MeasureScenario, timeout: Duration, stopRunner: Bool
    ) async throws -> (run: TestRun, app: InstalledApp) {
        try DeviceQueries.requireReady(target)
        try Recorder.checkIdle(target)
        guard let app = try await DeviceQueries.installedApp(target, bundleID: scenario.bundleID) else {
            throw DeviceQueries.appNotInstalled(scenario.bundleID, on: target)
        }
        let products = try await RunnerBuild.products(for: target) { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        let xctestrun = try RunnerBuild.writeMeasureXctestrun(from: products, test: test, scenario: scenario)
        defer { try? FileManager.default.removeItem(at: xctestrun) }
        let job = try await TestCommands.start(
            target, project: nil, workspace: nil, xctestrun: xctestrun.path, scheme: nil, stopRunner: stopRunner)
        let run = try JSONDecoder().decode(TestRun.self, from: try await TestCommands.finish(job, timeout: timeout).json.data())
        return (run, app)
    }

    /// Writes the perf job as `perf.json` next to the job's `summary.json` and adds its path to the text.
    static func saved(_ result: CommandResult, in run: TestRun) throws -> CommandResult {
        let file = URL(filePath: run.directory).appending(path: "perf.json")
        try result.json.data(pretty: true).write(to: file)
        var result = result
        result.text += "\nperf \(file.path)"
        result.files.append(file)
        return result
    }

    /// The target with its OS build, the app and its version, unavailable metrics, the simulator notes, then the
    /// `test run` text.
    static func report(
        _ run: TestRun, app: InstalledApp, iterations: Int, launchArguments: [String], target: Target, setup: [MeasureStep]? = nil,
        measure: [MeasureStep]? = nil, metrics: [MeasureMetric] = [], unavailable: [UnavailableMetric]? = nil
    ) throws -> CommandResult {
        let summary = URL(filePath: run.directory).appending(path: "summary.json")
        var notes = target.isSimulator ? [simulatorNote] : []
        if target.isSimulator && (metrics.contains(.cpu) || metrics.contains(.memory)) { notes.append(simulatorProcessNote) }
        let perf = PerfJob(
            job: run.job, status: run.status, cancelReason: run.cancelReason, app: app, iterations: iterations,
            launchArguments: launchArguments, setup: setup?.map(\.text), measure: measure?.map(\.text), unavailable: unavailable,
            device: run.result?.summary?.devicesAndConfigurations.first?.device,
            metrics: run.result?.metrics ?? [], note: notes.isEmpty ? nil : notes.joined(separator: " "), directory: run.directory,
            summary: summary.path
        )
        let version = [app.version, app.build.map { "(\($0))" }].compactMap { $0 }
        let header =
            [
                target.summary + (perf.device?.osBuildNumber.map { ", OS build \($0)" } ?? ""),
                (["app", app.bundleID] + version).joined(separator: " ") + ", \(iterations) \(measure == nil ? "launches" : "iterations")"
                    + (launchArguments.isEmpty ? "" : " with arguments \(launchArguments.joined(separator: " "))"),
            ] + (unavailable ?? []).map { "UNAVAILABLE \($0.metric.rawValue): \($0.reason)" } + notes
        return try CommandResult(
            text: TestCommands.text(run, header: header.joined(separator: "\n"), summary: summary), payload: perf,
            files: [URL(filePath: run.bundle), URL(filePath: run.log), summary]
        )
    }

    /// Compares the metrics of two perf or test run jobs, each given as its directory, `summary.json` or result bundle.
    public static func compare(_ baseline: URL, _ candidate: URL) async throws -> CommandResult {
        let comparison = comparison(try await side(baseline), try await side(candidate))
        return try CommandResult(text: text(comparison), payload: comparison)
    }

    /// The run at `path`, with the app, launch arguments and scenario from a `perf.json` in the same directory.
    static func side(_ path: URL) async throws -> PerfComparison.Side {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            throw DeviceLoopError(
                .badArguments, "Nothing at \(path.path).",
                fix: "Pass a perf or test run job directory, its summary.json, or an .xcresult bundle.")
        }
        var file = path
        let report: XCResult.Report?
        if path.pathExtension == "xcresult" {
            report = try await XCResult.read(path)
        } else {
            if isDirectory.boolValue { file = path.appending(path: "summary.json") }
            guard let run = try? JSONDecoder().decode(TestRun.self, from: Data(contentsOf: file)) else {
                throw DeviceLoopError(
                    .badArguments, "\(file.path) is not a test run summary.json.",
                    fix: "Pass a perf or test run job directory, its summary.json, or an .xcresult bundle.")
            }
            report = run.result
        }
        let perf = try? JSONDecoder().decode(
            PerfJob.self, from: Data(contentsOf: file.deletingLastPathComponent().appending(path: "perf.json")))
        var devices: [XCResult.Device] = []
        for device in report?.summary?.devicesAndConfigurations.map(\.device) ?? [] {
            if !devices.contains(where: { $0.deviceId == device.deviceId }) { devices.append(device) }
        }
        return PerfComparison.Side(
            path: file.path, devices: devices, app: perf?.app, launchArguments: perf?.launchArguments,
            scenario: perf.map { perf in
                ([perf.app.bundleID] + (perf.setup ?? []).map { "setup \($0)" } + (perf.measure ?? []).map { "measure \($0)" })
                    .joined(separator: ", ")
            },
            metrics: report?.metrics ?? [])
    }

    /// Matches metrics by test, configuration and identifier, the n-th entry of one key in a run with the n-th of the other.
    /// The comparison is inconclusive when either run has other than one destination, or the devices, OS builds or perf
    /// scenarios differ.
    static func comparison(_ baseline: PerfComparison.Side, _ candidate: PerfComparison.Side) -> PerfComparison {
        var reasons: [String] = []
        for (name, side) in [("baseline", baseline), ("candidate", candidate)] where side.devices.count != 1 {
            reasons.append("The \(name) ran on \(side.devices.count) destinations.")
        }
        if let baselineDevice = baseline.devices.first, let candidateDevice = candidate.devices.first {
            if baselineDevice.deviceId != candidateDevice.deviceId {
                reasons.append(
                    "The devices differ: \(baselineDevice.deviceName) (\(baselineDevice.deviceId)) and "
                        + "\(candidateDevice.deviceName) (\(candidateDevice.deviceId)).")
            }
            if baselineDevice.osBuildNumber == nil || baselineDevice.osBuildNumber != candidateDevice.osBuildNumber {
                reasons.append(
                    "The OS builds differ or are unknown: \(baselineDevice.osBuildNumber ?? "unknown") and "
                        + "\(candidateDevice.osBuildNumber ?? "unknown").")
            }
        }
        if baseline.scenario != candidate.scenario {
            reasons.append("The scenarios differ: \(baseline.scenario ?? "none") and \(candidate.scenario ?? "none").")
        }
        func keys(_ metrics: [XCResult.Metric]) -> [[String]] {
            var occurrences: [[String]: Int] = [:]
            return metrics.map { metric in
                let key = [metric.test, metric.configuration, metric.identifier ?? metric.displayName]
                occurrences[key, default: 0] += 1
                return key + [String(occurrences[key]!)]
            }
        }
        let baselineKeys = keys(baseline.metrics)
        let candidateKeys = keys(candidate.metrics)
        var metrics = zip(baseline.metrics, baselineKeys).map { metric, key in
            comparison(
                metric, baseline: metric, candidate: candidateKeys.firstIndex(of: key).map { candidate.metrics[$0] },
                comparable: reasons.isEmpty)
        }
        metrics += zip(candidate.metrics, candidateKeys).filter { _, key in !baselineKeys.contains(key) }.map { metric, _ in
            comparison(metric, baseline: nil, candidate: metric, comparable: reasons.isEmpty)
        }
        if metrics.isEmpty { reasons.append("Neither run has metrics.") }
        let verdict: PerfComparison.Verdict =
            if metrics.contains(where: { $0.verdict == .different }) {
                .different
            } else if !metrics.isEmpty && metrics.allSatisfy({ $0.verdict == .noDifferenceDetected }) {
                .noDifferenceDetected
            } else {
                .inconclusive
            }
        return PerfComparison(verdict: verdict, baseline: baseline, candidate: candidate, reasons: reasons, metrics: metrics)
    }

    /// `metric` of both runs. Different only when both sides have at least 5 measurements and their ranges do not overlap.
    static func comparison(
        _ metric: XCResult.Metric, baseline: XCResult.Metric?, candidate: XCResult.Metric?, comparable: Bool
    ) -> PerfComparison.Metric {
        var comparison = PerfComparison.Metric(
            test: metric.test, configuration: metric.configuration, identifier: metric.identifier, displayName: metric.displayName,
            verdict: .inconclusive, baseline: baseline, candidate: candidate)
        guard let baseline, let candidate else {
            comparison.reason = baseline == nil ? "Only in the candidate." : "Only in the baseline."
            return comparison
        }
        guard baseline.unitOfMeasurement == candidate.unitOfMeasurement else {
            comparison.reason = "The units differ: \(baseline.unitOfMeasurement) and \(candidate.unitOfMeasurement)."
            return comparison
        }
        let delta = candidate.median - baseline.median
        comparison.delta = delta
        comparison.percentDelta = baseline.median == 0 ? nil : delta / baseline.median * 100
        guard comparable else { return comparison }
        guard min(baseline.count, candidate.count) >= 5 else {
            comparison.reason = "A run has fewer than 5 measurements."
            return comparison
        }
        comparison.verdict = baseline.max < candidate.min || candidate.max < baseline.min ? .different : .noDifferenceDetected
        return comparison
    }

    /// The verdict, each run, the reasons, then one line per metric.
    static func text(_ comparison: PerfComparison) -> String {
        var lines = ["\(comparison.verdict.rawValue), \(comparison.metrics.count) metric\(comparison.metrics.count == 1 ? "" : "s")"]
        for (name, side) in [("baseline", comparison.baseline), ("candidate", comparison.candidate)] {
            let devices = side.devices.map { device in
                "\(device.deviceName) (\(device.deviceId))" + (device.osBuildNumber.map { ", OS build \($0)" } ?? "")
            }
            let app = side.app.map { app in
                (["app", app.bundleID, app.version, app.build.map { "(\($0))" }].compactMap { $0 }).joined(separator: " ")
            }
            let arguments = side.launchArguments.flatMap { $0.isEmpty ? nil : "arguments \($0.joined(separator: " "))" }
            lines.append("\(name) \(side.path): " + (devices + [app, arguments].compactMap { $0 }).joined(separator: ", "))
        }
        lines += comparison.reasons.map { "INCONCLUSIVE \($0)" }
        lines += comparison.metrics.map { metric in
            var parts = [metric.reason].compactMap { $0 }
            if let baseline = metric.baseline, let candidate = metric.candidate {
                func value(_ value: Double, _ metric: XCResult.Metric) -> String {
                    String(format: "%g", value) + " " + metric.unitOfMeasurement
                }
                parts.append("median \(value(baseline.median, baseline)) and \(value(candidate.median, candidate))")
                if let delta = metric.delta {
                    parts.append("delta \(value(delta, candidate))" + (metric.percentDelta.map { String(format: " (%+.1f%%)", $0) } ?? ""))
                }
                parts.append(
                    "range \(String(format: "%g", baseline.min)) to \(value(baseline.max, baseline)) and "
                        + "\(String(format: "%g", candidate.min)) to \(value(candidate.max, candidate))")
                if let baselineDeviation = baseline.standardDeviation, let candidateDeviation = candidate.standardDeviation {
                    parts.append("sd \(value(baselineDeviation, baseline)) and \(value(candidateDeviation, candidate))")
                }
                parts.append("n \(baseline.count) and \(candidate.count)")
            }
            return "\(metric.verdict.rawValue.uppercased()) \(metric.test) \(metric.displayName): " + parts.joined(separator: ", ")
        }
        return lines.joined(separator: "\n")
    }
}
