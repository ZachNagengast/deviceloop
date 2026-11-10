//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Darwin
import Foundation

/// One `test run` job, also saved as the job's `summary.json`.
public struct TestRun: Codable, Sendable {
    /// The job directory name, for example `test-20261108-131927-412-3f9a2c`.
    public var job: String
    /// UDID of the target.
    public var device: String
    /// `passed`, `failed` or `cancelled`, read from the result bundle.
    public var status: String
    /// `interrupt`, `timeout` or `passcode` when the job was cancelled.
    public var cancelReason: String?
    /// The exact argv xcodebuild ran with.
    public var arguments: [String]
    /// xcodebuild's exit status, or nil when a signal ended it.
    public var exitStatus: Int32?
    public var signal: Int32?
    /// Seconds since 1970.
    public var startTime: Double
    public var endTime: Double
    public var directory: String
    public var bundle: String
    public var log: String
    /// `xcodebuild: error:` lines from the log.
    public var xcodebuildErrors: [String]
    /// What the result bundle holds, or nil when it could not be read.
    public var result: XCResult.Report?
    /// Why the result bundle could not be read.
    public var resultError: String?
}

/// A `test run` job whose xcodebuild has started.
struct TestJob: Sendable {
    var target: Target
    var directory: URL
    var arguments: [String]
    var pid: pid_t
    /// Seconds since 1970.
    var startTime: Double
    /// Raised by Ctrl-C, SIGTERM or `test_cancel`.
    var interrupt: InterruptFlag

    var name: String { directory.lastPathComponent }
    var bundle: URL { directory.appending(path: "result.xcresult") }
    var log: URL { directory.appending(path: "xcodebuild.log") }
    var summary: URL { directory.appending(path: "summary.json") }
}

public enum TestCommands {
    /// Runs `xcodebuild test`, or `test-without-building` for an xctestrun, on `target` as a job with its own
    /// directory, and reports from the result bundle.
    public static func run(
        _ target: Target,
        project: String?,
        workspace: String?,
        xctestrun: String? = nil,
        scheme: String?,
        testPlan: String? = nil,
        onlyTesting: [String] = [],
        skipTesting: [String] = [],
        configuration: String? = nil,
        allowProvisioningUpdates: Bool = false,
        diagnostics: Bool = false,
        extraArguments: [String] = [],
        timeout: Duration = .seconds(3600),
        stopRunner: Bool = false
    ) async throws -> CommandResult {
        let job = try await start(
            target, project: project, workspace: workspace, xctestrun: xctestrun, scheme: scheme, testPlan: testPlan,
            onlyTesting: onlyTesting, skipTesting: skipTesting, configuration: configuration,
            allowProvisioningUpdates: allowProvisioningUpdates, diagnostics: diagnostics, extraArguments: extraArguments,
            stopRunner: stopRunner
        )
        return try await finish(job, timeout: timeout)
    }

    /// Checks the target, creates the job directory, starts xcodebuild and marks the target as running tests.
    static func start(
        _ target: Target,
        project: String?,
        workspace: String?,
        xctestrun: String? = nil,
        scheme: String?,
        testPlan: String? = nil,
        onlyTesting: [String] = [],
        skipTesting: [String] = [],
        configuration: String? = nil,
        allowProvisioningUpdates: Bool = false,
        diagnostics: Bool = false,
        extraArguments: [String] = [],
        stopRunner: Bool = false
    ) async throws -> TestJob {
        try DeviceQueries.requireReady(target)
        let directory = try Paths.newArtifact("test")
        let arguments = try xcodebuildArguments(
            project: project, workspace: workspace, xctestrun: xctestrun, scheme: scheme, testPlan: testPlan,
            onlyTesting: onlyTesting, skipTesting: skipTesting, configuration: configuration,
            allowProvisioningUpdates: allowProvisioningUpdates, diagnostics: diagnostics,
            extraArguments: extraArguments, udid: target.udid, resultBundle: directory.appending(path: "result.xcresult")
        )
        if let xctestrun { try checkXctestrun(URL(filePath: xctestrun), for: target) }
        if !target.isSimulator { try await RunnerSession.requireUnlocked(target) }

        let lock = try await SessionLock.acquire(for: target.udid)
        defer { lock.release() }
        if let marker = SuiteMarker.live(for: target.udid) { throw marker.busy(target) }
        try await SessionLock.checkNoFlow(on: target)
        try await RunnerSession.requireNoRunner(target, stop: stopRunner)
        try Paths.ensureDirectory(directory)
        let interrupt = InterruptFlag()
        let startTime = Date().timeIntervalSince1970
        let pid: pid_t
        do {
            pid = try Shell.spawnDetached(arguments, log: directory.appending(path: "xcodebuild.log"))
        } catch {
            interrupt.remove()
            throw error
        }
        let job = TestJob(
            target: target, directory: directory, arguments: arguments, pid: pid, startTime: startTime, interrupt: interrupt)
        if let identity = RunnerProcess.identity(of: pid) {
            do {
                try SuiteMarker(job: job.name, pid: pid, processIdentity: identity).write(for: target.udid)
            } catch {
                kill(pid, SIGKILL)
                var status: Int32 = 0
                waitpid(pid, &status, 0)
                interrupt.remove()
                throw DeviceLoopError(
                    .internalError, "Could not mark \(target.name) as running tests.",
                    fix: "Check write permissions at \(Paths.session(for: target.udid).path).", detail: "\(error)"
                )
            }
        }
        return job
    }

    /// Waits for the job's xcodebuild, reads the result bundle and writes `summary.json`.
    static func finish(_ job: TestJob, timeout: Duration) async throws -> CommandResult {
        defer { job.interrupt.remove() }
        let target = job.target
        var watch = PasscodeWatch(log: job.log, target: target)
        let (waitStatus, cancelReason) = await wait(for: job.pid, timeout: timeout, interrupt: job.interrupt) {
            target.isSimulator ? nil : watch.check { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        }
        let endTime = Date().timeIntervalSince1970
        await SuiteMarker.remove(job: job.name, for: target.udid)
        let logText = (try? String(contentsOf: job.log, encoding: .utf8)) ?? ""

        var run = TestRun(
            job: job.name, device: target.udid, status: "failed", cancelReason: cancelReason, arguments: job.arguments,
            exitStatus: waitStatus.flatMap { $0 & 0x7f == 0 ? ($0 >> 8) & 0xff : nil },
            signal: waitStatus.flatMap { $0 & 0x7f == 0 ? nil : $0 & 0x7f },
            startTime: job.startTime, endTime: endTime, directory: job.directory.path, bundle: job.bundle.path, log: job.log.path,
            xcodebuildErrors: logText.split(separator: "\n").filter { $0.hasPrefix("xcodebuild: error:") }.map(String.init)
        )
        if FileManager.default.fileExists(atPath: job.bundle.path) {
            do {
                run.result = try await XCResult.read(job.bundle)
            } catch {
                run.resultError = (error as? DeviceLoopError)?.message ?? "\(error)"
            }
        } else {
            run.resultError = "xcodebuild wrote no result bundle."
        }
        run.status = cancelReason == nil ? status(of: run.result) : "cancelled"

        let result = try CommandResult(
            text: text(run, header: target.summary, summary: job.summary), payload: run, files: [job.bundle, job.log, job.summary])
        try result.json.data(pretty: true).write(to: job.summary)
        if let error = userError(in: logText, status: run.status, target: target, summary: job.summary) { throw error }
        return result
    }

    /// The `summary.json` of a finished job in the artifacts directory, or in a run's artifacts.
    static func saved(job: String) throws -> CommandResult {
        let runs = (try? FileManager.default.contentsOfDirectory(at: Paths.runs, includingPropertiesForKeys: nil)) ?? []
        let directory = ([Paths.artifacts] + runs.map { RunStore(directory: $0).artifacts }).map { $0.appending(path: job) }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard job.hasPrefix("test-"), !job.contains("/"), let directory else {
            throw DeviceLoopError(.badArguments, "No test job \(job).", fix: "Pass the job that test_run returned.")
        }
        let summary = directory.appending(path: "summary.json")
        guard let summaryData = try? Data(contentsOf: summary) else {
            guard SuiteMarker.live(job: job) == nil else {
                throw DeviceLoopError(
                    .badArguments, "Test job \(job) has no summary.json yet, and only jobs this server started report while they run.",
                    fix: "Call test_status again after it finishes."
                )
            }
            throw DeviceLoopError(
                .badArguments, "Test job \(job) ended without a summary.json because the process that ran it exited first.",
                fix: "Read \(directory.path)/result.xcresult with deviceloop test results, and see \(directory.path)/xcodebuild.log."
            )
        }
        let run = try JSONDecoder().decode(TestRun.self, from: summaryData)
        return try CommandResult(
            text: text(run, header: run.device, summary: summary), payload: run,
            files: [URL(filePath: run.bundle), URL(filePath: run.log), summary]
        )
    }

    /// The error a finished job's log shows when the user has to act: an unanswered passcode prompt, a missing
    /// development team or a failed provisioning profile.
    static func userError(in log: String, status: String, target: Target, summary: URL) -> DeviceLoopError? {
        if log.contains(RunnerSession.passcodeTimedOut) {
            var error = RunnerSession.passcodeError(target)
            error.detail = "Summary: \(summary.path)"
            return error
        }
        guard status == "failed" else { return nil }
        if let line = log.split(separator: "\n").last(where: { line in
            line.range(of: "error: ").map { line[$0.upperBound...].contains("requires a development team") } ?? false
        }) {
            return DeviceLoopError(
                .signingNoTeam, "The tests need a development team to be signed for \(target.name).",
                fix: "Pass DEVELOPMENT_TEAM=<team ID> after --, or set the team in the project. deviceloop doctor lists the teams "
                    + "signed in to Xcode.",
                detail: String(line), device: target.name
            )
        }
        guard let line = RunnerBuild.provisioningError(in: log) else { return nil }
        return DeviceLoopError(
            .signingProfileFailed, "The tests could not be signed for \(target.name).",
            fix: "Pass --allow-provisioning-updates, and DEVELOPMENT_TEAM=<team ID> after --. Check Xcode > Settings > Accounts.",
            detail: line, device: target.name
        )
    }

    /// Refuses an xctestrun whose products were all built for the other kind of target.
    static func checkXctestrun(_ file: URL, for target: Target) throws {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw DeviceLoopError(
                .badArguments, "No xctestrun at \(file.path).", fix: "Pass the .xctestrun that build-for-testing wrote to Build/Products.")
        }
        guard let contents = try? Data(contentsOf: file),
            let plist = try? PropertyListSerialization.propertyList(from: contents, format: nil) as? [String: Any],
            let simulator = builtForSimulator(plist), simulator != target.isSimulator
        else { return }
        throw DeviceLoopError(
            .unsupportedOnTarget,
            "\(file.lastPathComponent) was built for \(simulator ? "a simulator" : "a device"), not \(target.name).",
            fix: "Rerun xcodebuild build-for-testing with -destination 'generic/platform=\(target.isSimulator ? "iOS Simulator" : "iOS")' "
                + "and pass the .xctestrun it writes.",
            device: target.name
        )
    }

    /// True when every product an xctestrun depends on is in a `-iphonesimulator` directory, false when every one is
    /// in a `-iphoneos` directory, and nil for an unknown format or anything else.
    static func builtForSimulator(_ plist: [String: Any]) -> Bool? {
        let metadata = plist["__xctestrun_metadata__"] as? [String: Any]
        let targets: [Any]
        switch metadata == nil ? 1 : metadata?["FormatVersion"] as? Int {
            case 1: targets = plist.filter { $0.key != "__xctestrun_metadata__" }.map(\.value)
            case 2: targets = (plist["TestConfigurations"] as? [[String: Any]] ?? []).flatMap { $0["TestTargets"] as? [Any] ?? [] }
            default: return nil
        }
        let platforms = targets.flatMap { ($0 as? [String: Any])?["DependentProductPaths"] as? [String] ?? [] }.map { path in
            path.split(separator: "/").lazy.compactMap { component -> Bool? in
                component.hasSuffix("-iphonesimulator") ? true : component.hasSuffix("-iphoneos") ? false : nil
            }.first
        }
        guard let first = platforms.first, platforms.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// The `xcrun xcodebuild test` or `test-without-building` argv. The destination and result bundle are DeviceLoop's.
    static func xcodebuildArguments(
        project: String?,
        workspace: String?,
        xctestrun: String? = nil,
        scheme: String?,
        testPlan: String? = nil,
        onlyTesting: [String] = [],
        skipTesting: [String] = [],
        configuration: String? = nil,
        allowProvisioningUpdates: Bool = false,
        diagnostics: Bool = false,
        extraArguments: [String] = [],
        udid: String,
        resultBundle: URL
    ) throws -> [String] {
        var arguments = ["xcrun", "xcodebuild"]
        switch (project, workspace, xctestrun) {
            case (let project?, nil, nil): arguments += ["test", "-project", project]
            case (nil, let workspace?, nil): arguments += ["test", "-workspace", workspace]
            case (nil, nil, let xctestrun?): arguments += ["test-without-building", "-xctestrun", xctestrun]
            default: throw DeviceLoopError.usage("Pass exactly one of --project, --workspace or --xctestrun.")
        }
        let ownedFixes = [
            "-destination": "Pick the target with --device.", "-resultBundlePath": "Read the bundle from the job directory.",
            "-collect-test-diagnostics": "Pass --diagnostics.",
        ]
        if let owned = extraArguments.first(where: { ownedFixes[$0] != nil }) {
            throw DeviceLoopError(.badArguments, "\(owned) cannot be passed through to xcodebuild.", fix: ownedFixes[owned])
        }
        if xctestrun == nil {
            guard let scheme else { throw DeviceLoopError.usage("Pass --scheme with --project or --workspace.") }
            arguments += ["-scheme", scheme]
            if let testPlan { arguments += ["-testPlan", testPlan] }
            if let configuration { arguments += ["-configuration", configuration] }
        } else if scheme != nil || testPlan != nil || configuration != nil {
            throw DeviceLoopError.usage("--scheme, --test-plan and --configuration do not apply to --xctestrun.")
        }
        arguments += ["-destination", "id=\(udid)", "-resultBundlePath", resultBundle.path]
        arguments += ["-collect-test-diagnostics", diagnostics ? "on-failure" : "never"]
        if allowProvisioningUpdates { arguments.append("-allowProvisioningUpdates") }
        arguments += onlyTesting.map { "-only-testing:\($0)" } + skipTesting.map { "-skip-testing:\($0)" }
        return arguments + extraArguments
    }

    /// Reaps the owned child and returns its wait status, or nil if it could not be reaped.
    /// An interrupt, task cancellation, the timeout or a reason from `check` sends SIGINT, then SIGTERM after `grace`
    /// and SIGKILL 10 s later.
    static func wait(
        for pid: pid_t, timeout: Duration, interrupt: InterruptFlag, grace: Duration = .seconds(60),
        check: () -> String? = { nil }
    ) async -> (status: Int32?, cancelReason: String?) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var cancelReason: String?
        var escalation: [(signal: Int32, wait: Duration)] = [(SIGINT, grace), (SIGTERM, .seconds(10)), (SIGKILL, .seconds(10))]
        var nextSignal = clock.now
        while true {
            var status: Int32 = 0
            let reaped = waitpid(pid, &status, WNOHANG)
            if reaped == pid { return (status, cancelReason) }
            if reaped < 0, errno != EINTR { return (nil, cancelReason) }
            if cancelReason == nil {
                cancelReason = interrupt.isRaised || Task.isCancelled ? "interrupt" : clock.now >= deadline ? "timeout" : check()
                nextSignal = clock.now
            }
            if cancelReason != nil, clock.now >= nextSignal, !escalation.isEmpty {
                let step = escalation.removeFirst()
                kill(pid, step.signal)
                nextSignal = clock.now.advanced(by: step.wait)
            }
            // Sleeps 0.2 s without throwing on task cancellation.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { continuation.resume() }
            }
        }
    }

    /// `passed` when the bundle shows no failed build and passed, skipped or expected-failure tests, otherwise `failed`.
    static func status(of report: XCResult.Report?) -> String {
        guard let report, report.build.status != "failed", let result = report.summary?.result,
            ["Passed", "Skipped", "Expected Failure"].contains(result)
        else { return "failed" }
        return "passed"
    }

    /// The header, cancellation, results with one line per test, xcodebuild errors, then the job's files.
    static func text(_ run: TestRun, header: String, summary: URL) -> String {
        var lines = [header]
        if let cancelReason = run.cancelReason { lines.append("Cancelled: \(cancelReason)") }
        if let report = run.result {
            lines += self.lines(report, listTests: true)
        } else {
            lines.append("Result bundle not finalized: \(run.resultError ?? "unknown error")")
        }
        lines += run.xcodebuildErrors
        lines += [run.bundle, "log \(run.log)", "summary \(summary.path)"]
        return lines.joined(separator: "\n")
    }

    /// Summarizes a result bundle from xcodebuild, Xcode or any other tool.
    public static func results(_ bundle: URL) async throws -> CommandResult {
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            throw DeviceLoopError(
                .badArguments, "No result bundle at \(bundle.path).", fix: "Pass the path of an .xcresult bundle.")
        }
        let report = try await XCResult.read(bundle)
        return try CommandResult(text: text(report), payload: report)
    }

    /// Destination, result and counts, one line per failure or build error, then the bundle path.
    static func text(_ report: XCResult.Report) -> String {
        var devices = report.summary?.devicesAndConfigurations.map(\.device) ?? []
        if devices.isEmpty { devices = [report.build.destination] }
        var seen = Set<String>()
        let destination = devices.filter { seen.insert($0.deviceId).inserted }.map { device in
            let os = [device.platform, device.osVersion].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            return "\(device.deviceName) (\(os.isEmpty ? "" : "\(os), ")\(device.deviceId))"
        }
        return ([destination.joined(separator: ", ")] + lines(report) + [report.bundle]).joined(separator: "\n")
    }

    /// Result and counts, optionally one line per test that did not fail, then failures, metrics and build errors.
    static func lines(_ report: XCResult.Report, listTests: Bool = false) -> [String] {
        var lines: [String] = []
        if let summary = report.summary, summary.result != "unknown" || summary.totalTestCount > 0 {
            var counts = [
                "\(summary.totalTestCount) test\(summary.totalTestCount == 1 ? "" : "s")",
                "\(summary.passedTests) passed", "\(summary.failedTests) failed", "\(summary.skippedTests) skipped",
            ]
            if summary.expectedFailures > 0 { counts.append("\(summary.expectedFailures) expected failures") }
            if let start = summary.startTime, let finish = summary.finishTime {
                counts.append(String(format: "%.1f s", finish - start))
            }
            lines.append("Tests \(summary.result): " + counts.joined(separator: ", "))
            if listTests {
                lines += (report.tests ?? []).filter { $0.result != "Failed" }.map { test in
                    "\(test.result == "Passed" ? "PASS" : test.result.uppercased()) \(test.identifier)"
                }
            }
            lines += summary.testFailures.map { "FAIL \($0.targetName)/\($0.testIdentifierString): \($0.failureText)" }
            lines += (report.metrics ?? []).map { metric in
                let values: [(String, Double?)] = [
                    ("median", metric.median), ("mean", metric.mean), ("sd", metric.standardDeviation), ("min", metric.min),
                    ("max", metric.max), ("baseline", metric.baselineAverage),
                ]
                let stats = values.compactMap { name, value in
                    value.map { "\(name) \(String(format: "%g", $0)) \(metric.unitOfMeasurement)" }
                }
                return "METRIC \(metric.test) \(metric.displayName): " + (stats + ["n \(metric.count)"]).joined(separator: ", ")
            }
        } else {
            lines.append("No test results")
        }

        let build = report.build
        if build.status == "failed" || !build.errors.isEmpty {
            lines.append("Build \(build.status ?? "unknown"): \(build.errors.count) error\(build.errors.count == 1 ? "" : "s")")
            lines += build.errors.map { error in "ERROR " + (error.location.map { "\($0): " } ?? "") + error.message }
        }
        return lines
    }
}

/// Follows a device job's log for the UI Automation passcode prompt.
struct PasscodeWatch {
    let log: URL
    let target: Target
    var offset: UInt64 = 0
    var hinted = false

    /// Reads the lines added since the last call. Prints the passcode hint once a UI test bundle starts, and
    /// returns `passcode` once the prompt timed out.
    mutating func check(_ progress: (String) -> Void) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let added = try? handle.readToEnd(),
            let end = added.lastIndex(of: UInt8(ascii: "\n"))
        else { return nil }
        offset += UInt64(end - added.startIndex + 1)
        for line in String(decoding: added[..<end], as: UTF8.self).split(separator: "\n") {
            if line.contains(RunnerSession.passcodeTimedOut) { return "passcode" }
            if !hinted, line.contains(RunnerSession.uiTestsStarted) {
                hinted = true
                progress(RunnerSession.passcodeHint(target))
            }
        }
        return nil
    }
}
