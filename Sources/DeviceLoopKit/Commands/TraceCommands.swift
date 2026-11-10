//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Darwin
import Foundation
import notify
import os

/// Instruments traces of one app through `xctrace record`.
public enum TraceCommands {
    static let defaultTemplate = "Time Profiler"
    static let defaultLimitMs = 10_000
    static let maxLimitMs = 60_000
    /// Disk use to reserve per second of recording. An Animation Hitches trace on a device can write over 200 MB a second.
    static let bytesPerSecond: Int64 = 250_000_000
    static let diskMargin: Int64 = 1_000_000_000
    /// Time xctrace gets beyond the time limit to attach and save before it is killed.
    static let overrun: Duration = .seconds(120)
    /// Time xctrace gets to save after SIGINT before it is killed.
    static let saveGrace: Duration = .seconds(60)
    /// The line xctrace prints once recording has started.
    static let startedLine = "Ctrl-C to stop the recording"

    /// Attaches to the running `app` and records until `durationMs` passes, or until SIGINT or task cancellation.
    public static func record(
        _ target: Target, app: String, template: String?, durationMs: Int?, output: URL?
    ) async throws -> CommandResult {
        try DeviceQueries.requireReady(target)
        let limitMs = try timeLimitMs(durationMs)
        if let output {
            guard output.pathExtension == "trace" else {
                throw DeviceLoopError(.badArguments, "\(output.path) does not end in .trace.", fix: "Pass a path such as launch.trace.")
            }
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw DeviceLoopError(.badArguments, "\(output.path) already exists.", fix: "Pass a new path, or remove the old trace.")
            }
        }
        let template = template ?? defaultTemplate
        if target.isSimulator && template == TraceSummary.hitchesTemplate {
            throw DeviceLoopError.unsupported(
                "Animation Hitches tracing", on: target,
                alternatives: ["Use an iPhone or iPad over USB", "Pick another template, such as Time Profiler"])
        }
        let listing = try await Shell.run(["xcrun", "xctrace", "list", "templates"])
        guard listing.succeeded else {
            throw DeviceLoopError(
                .xcodeMissing, "xctrace is not available in the selected Xcode.",
                fix: "Install Xcode 27 or later and run: sudo xcode-select -s /Applications/Xcode.app",
                detail: listing.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let templates = templateNames(listing.stdoutString)
        guard templates.contains(template) else {
            throw DeviceLoopError(
                .badArguments, "xctrace has no template named \(template).",
                fix: "Pass one of the names from `xcrun xctrace list templates`.", alternatives: templates)
        }
        let (pid, names) = try await attachment(target, app: app)
        return try await record(
            target, app: app, pid: pid, names: names, template: template, limitMs: limitMs,
            output: try output ?? Paths.newArtifact("trace", extension: "trace"))
    }

    /// The pid of the running `app` and the names xctrace may give its process.
    static func attachment(_ target: Target, app: String) async throws -> (pid: Int32, names: [String]) {
        async let running = DeviceQueries.runningApps(target)
        async let installed = DeviceQueries.installedApp(target, bundleID: app)
        guard let pid = try await running[app]?.first else {
            throw AppCommands.appNotRunning(app, on: target)
        }
        guard let bundle = try await installed else { throw DeviceQueries.appNotInstalled(app, on: target) }
        return (pid, processNames(bundle))
    }

    /// devicectl's name for `app` and its bundle name without `.app`. xctrace names an app's process by one or the other.
    static func processNames(_ app: InstalledApp) -> [String] {
        let bundleName = URL(string: app.url)?.deletingPathExtension().lastPathComponent ?? ""
        return bundleName.isEmpty || bundleName == app.name ? [app.name] : [app.name, bundleName]
    }

    /// Records with `run`, then checks that the trace names `pid` and one of `names` on the target and writes its TOC and
    /// summary next to it.
    static func record(
        _ target: Target,
        app: String,
        pid: Int32,
        names: [String],
        template: String,
        limitMs: Int,
        output: URL,
        xctrace: [String] = ["xcrun", "xctrace"],
        timeout: Duration? = nil,
        grace: Duration = saveGrace,
        freeBytes: (URL) -> Int64? = freeBytes
    ) async throws -> CommandResult {
        let stopped = try await run(
            target, app: app, pid: pid, template: template, limitMs: limitMs, output: output, xctrace: xctrace, timeout: timeout,
            grace: grace, freeBytes: freeBytes)
        let summaryFile = sibling(output, "summary.json")
        // Summarizes in a new task, which this task's cancellation does not reach.
        let summary = try await Task { try await summarize(output, target: target, pid: pid, names: names, xctrace: xctrace) }.value.summary
        try JSONValue(encoding: summary).data(pretty: true).write(to: summaryFile, options: .atomic)
        var lines = [
            target.summary,
            "\(template) trace of \(app) (pid \(pid)), time limit \(limitMs) ms\(stopped ? ", stopped early" : "")",
            "trace \(output.path)",
            "toc \(summary.toc)",
            "summary \(summaryFile.path)",
        ]
        if let hitches = summary.hitches { lines.append("hitches \(hitches.count)") }
        for (label, intervals) in [("potential hangs", summary.hangs), ("displayed surfaces", summary.surfaces)] {
            guard let intervals else { continue }
            lines.append("\(label) \(intervals.count)" + (intervals.longestMs.map { ", longest \(ParityText.number($0)) ms" } ?? ""))
        }
        if summary.partial {
            let missing = summary.missing.isEmpty ? "" : ", missing tables: \(summary.missing.joined(separator: ", "))"
            lines.append("partial summary\(missing). The raw trace and TOC are kept.")
        }
        return CommandResult(
            text: lines.joined(separator: "\n"),
            json: [
                "trace": .string(output.path), "template": .string(template), "app": .string(app), "pid": .number(Double(pid)),
                "timeLimitMs": .number(Double(limitMs)), "stoppedEarly": .bool(stopped), "device": .string(target.udid),
                "summaryFile": .string(summaryFile.path), "summary": try JSONValue(encoding: summary),
            ],
            files: [output, URL(filePath: summary.toc), summaryFile])
    }

    /// Runs `xctrace record` with TMPDIR in a per-trace directory under `Paths.home`, which is removed afterwards.
    /// With `during`, waits for xctrace's tracing-started notification, runs `during`, then stops xctrace.
    /// Returns true when xctrace was stopped with SIGINT.
    static func run(
        _ target: Target,
        app: String,
        pid: Int32,
        template: String,
        limitMs: Int,
        output: URL,
        xctrace: [String] = ["xcrun", "xctrace"],
        timeout: Duration? = nil,
        grace: Duration = saveGrace,
        freeBytes: (URL) -> Int64? = freeBytes,
        during: (() async throws -> Void)? = nil
    ) async throws -> Bool {
        let temp = try Paths.ensureDirectory(Paths.home.appending(path: "tmp/trace-\(UUID().uuidString)", directoryHint: .isDirectory))
        defer { try? FileManager.default.removeItem(at: temp) }
        let needed = requiredBytes(limitMs: limitMs)
        for directory in [temp, try Paths.ensureDirectory(output.deletingLastPathComponent())] {
            if let free = freeBytes(directory), free < needed {
                throw DeviceLoopError(
                    .badArguments,
                    "A \(limitMs) ms trace needs about \(gigabytes(needed)) free, and \(directory.path) has \(gigabytes(free)).",
                    fix: "Free disk space, or pass a shorter \(during == nil ? "--duration-ms" : "--wait-ms").")
            }
        }

        let log = temp.appending(path: "xctrace.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        let notification = "com.argmaxinc.deviceloop.trace.\(UUID().uuidString)"
        process.arguments =
            xctrace + arguments(udid: target.udid, pid: pid, template: template, limitMs: limitMs, output: output)
            + (during == nil ? [] : ["--notify-tracing-started", notification])
        process.environment = ProcessInfo.processInfo.environment.merging(["TMPDIR": temp.path]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle

        let tracing = OSAllocatedUnfairLock(initialState: false)
        var token: Int32 = 0
        notify_register_dispatch(notification, &token, .global()) { _ in tracing.withLock { $0 = true } }
        defer { notify_cancel(token) }
        let interrupt = InterruptFlag()
        defer { interrupt.remove() }
        do {
            try process.run()
        } catch {
            throw DeviceLoopError(.internalError, "Could not start xctrace.", detail: "\(error)")
        }
        let started = ContinuousClock.now
        let deadline = started + (timeout ?? .milliseconds(limitMs) + overrun)
        var interruptedAt: ContinuousClock.Instant?
        var failure: DeviceLoopError?
        var ran = false
        var duringError: (any Error)?
        if let during {
            while !ran, process.isRunning, !interrupt.isRaised, !Task.isCancelled, ContinuousClock.now < deadline {
                guard tracing.withLock({ $0 }) else {
                    await pause()
                    continue
                }
                ran = true
                do { try await during() } catch { duringError = error }
                if process.isRunning { process.interrupt() }
                interruptedAt = .now
            }
        }
        while process.isRunning {
            let now = ContinuousClock.now
            if interruptedAt == nil, interrupt.isRaised || Task.isCancelled {
                process.interrupt()
                interruptedAt = now
            }
            if failure == nil, interruptedAt.map({ now - $0 > grace }) ?? (now > deadline) {
                kill(process.processIdentifier, SIGKILL)
                let message =
                    interruptedAt == nil
                    ? "xctrace did not finish within \(limitMs) ms plus \(overrun)." : "xctrace did not save within \(grace) of SIGINT."
                failure = DeviceLoopError(.timeout, message, fix: "Retry, or record the same template in Instruments.", device: target.name)
            }
            await pause()
        }
        interrupt.remove()

        let text = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let duringError { throw duringError }
        if var failure {
            failure.detail = text
            throw failure
        }
        let recording = ran || text.contains(startedLine)
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else {
            if interruptedAt != nil, !recording { throw CancellationError() }
            let errorLine = text.components(separatedBy: "[Error] ").dropFirst().last?.split(separator: "\n").first
            let reason = (errorLine ?? text.split(separator: "\n").last).map(String.init) ?? "exit \(process.terminationStatus)"
            if !recording || reason.contains("not supported") {
                throw DeviceLoopError(
                    .unsupportedOnTarget, "xctrace could not record \(app) on \(target.summary): \(reason)",
                    fix: "Check that \(app) is still running, or "
                        + (during == nil ? "pick another template" : "drop --instruments") + ", then retry.",
                    detail: text, device: target.name)
            }
            throw DeviceLoopError(
                .deviceError, "xctrace recording failed with status \(process.terminationStatus): \(reason)",
                fix: "Check free disk space, then retry.", detail: text, device: target.name)
        }
        if during != nil, !ran {
            if interruptedAt != nil { throw CancellationError() }
            throw DeviceLoopError(
                .unsupportedOnTarget, "xctrace recorded \(app) on \(target.summary) without reporting that tracing started.",
                fix: "Retry, or record the trace with `deviceloop trace record` instead.", detail: text, device: target.name)
        }
        return interruptedAt != nil
    }

    /// Exports the TOC next to `trace`, checks it, and reads the tables `TraceSummary` uses with `xctrace export`.
    static func summarize(
        _ trace: URL, target: Target, pid: Int32, names: [String], xctrace: [String]
    ) async throws -> (summary: TraceSummary, toc: TraceTOC, tables: [String: TraceTable]) {
        let export = xctrace + ["export", "--input", trace.path]
        let tocResult = try await Shell.run(export + ["--toc"])
        guard tocResult.succeeded else {
            throw DeviceLoopError(
                .deviceError, "xctrace could not read the trace it recorded at \(trace.path).",
                fix: "Open the trace in Instruments, or record again.", detail: tocResult.stderrString, device: target.name)
        }
        let tocFile = sibling(trace, "toc.xml")
        try tocResult.stdout.write(to: tocFile, options: .atomic)
        let toc = try TraceTOC(xml: tocResult.stdout)
        try checkOwner(toc, target: target, pid: pid, names: names, trace: trace)
        var tables: [String: TraceTable] = [:]
        for schema in TraceSummary.schemas where toc.schemas.contains(schema) {
            let result = try await Shell.run(export + ["--xpath", "/trace-toc/run[1]/data/table[@schema=\"\(schema)\"]"])
            if result.succeeded { tables[schema] = try? TraceTable(xml: result.stdout) }
        }
        return (TraceSummary(toc: toc, tables: tables, trace: trace, tocFile: tocFile), toc, tables)
    }

    /// Throws `device_error` unless the TOC names the target's UDID and the attached process `pid` called one of `names`.
    static func checkOwner(_ toc: TraceTOC, target: Target, pid: Int32, names: [String], trace: URL) throws {
        if toc.device == target.udid, toc.pid == pid, let name = toc.processName, names.contains(name) { return }
        throw DeviceLoopError(
            .deviceError,
            "The trace at \(trace.path) records \(toc.processName ?? "no process") (pid \(toc.pid.map(String.init) ?? "none")) "
                + "on \(toc.device ?? "no device"), not \(names.joined(separator: " or ")) (pid \(pid)) on \(target.udid).",
            fix: "Check --device and --app, then record again.", device: target.name)
    }

    /// `trace` with its `.trace` extension replaced by `suffix`.
    static func sibling(_ trace: URL, _ suffix: String) -> URL {
        trace.deletingPathExtension().appendingPathExtension(suffix)
    }

    /// The `xctrace record` arguments: one process on one device, not `--all-processes`.
    static func arguments(udid: String, pid: Int32, template: String, limitMs: Int, output: URL) -> [String] {
        [
            "record", "--device", udid, "--template", template, "--attach", String(pid), "--time-limit", "\(limitMs)ms",
            "--output", output.path, "--no-prompt",
        ]
    }

    /// `durationMs`, or 10 s when nil, capped at 60 s.
    static func timeLimitMs(_ durationMs: Int?) throws -> Int {
        guard let durationMs else { return defaultLimitMs }
        guard durationMs > 0 else {
            throw DeviceLoopError(
                .badArguments, "--duration-ms must be positive, got \(durationMs).", fix: "For example: --duration-ms 5000")
        }
        return min(durationMs, maxLimitMs)
    }

    /// Twice the recording estimate, for the temp files and the trace, plus a margin.
    static func requiredBytes(limitMs: Int) -> Int64 {
        Int64(limitMs) * bytesPerSecond / 1000 * 2 + diskMargin
    }

    /// Template names from `xctrace list templates`, without the `== ... ==` section headers.
    static func templateNames(_ listing: String) -> [String] {
        listing.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("==") }
    }

    /// Free bytes on the volume holding `directory`, not counting purgeable space.
    static func freeBytes(_ directory: URL) -> Int64? {
        (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init)
    }

    private static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1e9)
    }

    /// Sleeps 50 ms on a GCD timer, which task cancellation does not cut short.
    private static func pause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
        }
    }
}
