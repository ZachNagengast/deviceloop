//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Darwin
import Foundation

/// A background capture, saved as `Paths.home/logs/<id>.json` so another process can read or stop it.
struct LogHandle: Codable, Sendable, Equatable {
    var id: String
    var udid: String
    var summary: String
    /// nil for a capture of the simulator's unified log.
    var bundleID: String?
    /// The detached `devicectl device process launch --console`, or `simctl spawn log stream`, process.
    var pid: Int32
    var identity: RunnerProcessIdentity?
    var log: String
    var startedAt: String
}

/// `deviceloop logs`: an app's stdout, stderr and os_log, written to a log artifact by a detached devicectl, or a simulator's
/// unified log, written by a detached `log stream`.
public enum LogCommands {
    static var directory: URL { Paths.home.appending(path: "logs", directoryHint: .isDirectory) }

    /// Terminates a running instance, since devicectl connects the streams of a new process only, then relaunches the app
    /// with its console going to a log artifact. Returns once the app has a pid.
    public static func start(
        _ target: Target, bundleID: String, arguments: [String], environment: [String: String]
    ) async throws -> CommandResult {
        try Validate.bundleID(bundleID)
        try DeviceQueries.require(Capability.applicationControl, "Launching apps", on: target)
        try checkIdle(target, bundleID: bundleID)
        do {
            _ = try await AppCommands.terminate(target, bundleID: bundleID)
        } catch let error as DeviceLoopError where error.code == .appNotRunning {}
        var variables = environment
        variables["OS_ACTIVITY_DT_MODE"] = variables["OS_ACTIVITY_DT_MODE"] ?? "YES"
        let launch = try AppCommands.launchCommand(
            target, bundleID: bundleID, environment: variables, console: true, terminateExisting: false)
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let log = try Paths.newArtifact("log-\(bundleID)", extension: "log")
        let command = Devicectl.command(launch, output: resultFile(id), passthrough: arguments)
        let handle = try spawn(command, id: id, log: log, target: target, bundleID: bundleID)
        let appPid = try await track(handle, signal: SIGKILL) {
            try await waitForLaunch(handle, bundleID: bundleID, command: launch, target: target)
        }
        return CommandResult(
            text: "\(target.summary)\ncapturing \(bundleID) pid \(appPid) as \(id) to \(log.path)\nstartedAt \(handle.startedAt)\n"
                + "read with: deviceloop logs read \(id)\nstop with: deviceloop logs stop \(id)",
            json: [
                "handle": .string(id), "bundleID": .string(bundleID), "pid": .number(Double(appPid)), "log": .string(log.path),
                "startedAt": .string(handle.startedAt), "arguments": .array(arguments.map(JSONValue.string)),
                "environmentKeys": .array(variables.keys.sorted().map(JSONValue.string)),
            ],
            files: [log]
        )
    }

    /// Streams the simulator's unified log as ndjson to a log artifact with `simctl spawn log stream`, filtered by `predicate`.
    /// Returns once `log` prints its filter line or a first event, and throws when it exits first.
    public static func startSystem(_ target: Target, predicate: String?) async throws -> CommandResult {
        guard target.isSimulator else {
            throw DeviceLoopError.unsupported(
                "Streaming the unified log", on: target,
                alternatives: [
                    "Open Console.app, select the device and filter by process",
                    "Run `deviceloop logs start <bundle ID>` for one app's stdout, stderr and os_log",
                ])
        }
        try DeviceQueries.requireReady(target)
        try checkIdle(target, bundleID: nil)
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let log = try Paths.newArtifact("log-system", extension: "ndjson")
        let handle = try spawn(streamCommand(target.udid, predicate: predicate), id: id, log: log, target: target, bundleID: nil)
        try await track(handle, signal: SIGTERM) { try await waitForStream(handle) }
        return CommandResult(
            text: "\(target.summary)\ncapturing the unified log\(predicate.map { " where \($0)" } ?? "") as \(id) to \(log.path)\n"
                + "startedAt \(handle.startedAt)\nread with: deviceloop logs read \(id)\nstop with: deviceloop logs stop \(id)",
            json: [
                "handle": .string(id), "bundleID": .null, "predicate": predicate.map(JSONValue.string) ?? .null, "log": .string(log.path),
                "startedAt": .string(handle.startedAt),
            ],
            files: [log]
        )
    }

    /// Spawns `command` detached with its output in `log` and returns the handle of the capture.
    private static func spawn(_ command: [String], id: String, log: URL, target: Target, bundleID: String?) throws -> LogHandle {
        try Paths.ensureDirectory(directory)
        let pid = try Shell.spawnDetached(command, log: log)
        return LogHandle(
            id: id, udid: target.udid, summary: target.summary, bundleID: bundleID, pid: pid, identity: RunnerProcess.identity(of: pid),
            log: log.path, startedAt: Date().ISO8601Format(.init(includingFractionalSeconds: true)))
    }

    /// Saves `handle` and returns what `wait` returns. When either throws, sends `signal` to a capture still running and
    /// removes its handle.
    private static func track<Value>(_ handle: LogHandle, signal: Int32, wait: () async throws -> Value) async throws -> Value {
        do {
            try save(handle)
            return try await wait()
        } catch {
            if isRunning(handle) { kill(handle.pid, signal) }
            remove(handle)
            throw error
        }
    }

    static func streamCommand(_ udid: String, predicate: String?) -> [String] {
        ["xcrun", "simctl", "spawn", udid, "log", "stream", "--style", "ndjson"] + (predicate.map { ["--predicate", $0] } ?? [])
    }

    /// The last `tail` lines of a capture that contain `grep`, all of them when both are nil.
    /// Throws `app_crashed` when the app ended by a crash signal and its report appears.
    public static func read(handle id: String, tail: Int?, grep: String?) async throws -> CommandResult {
        let handle = try load(id)
        let all = lines(handle)
        let shown = select(all, tail: tail, grep: grep)
        let running = isRunning(handle)
        let note = running ? nil : try await checkForCrash(handle)
        let ended = handle.bundleID == nil ? "stream ended" : "app exited"
        let state = running ? "capturing" : "\(ended), stop with: deviceloop logs stop \(id)"
        let header = "\(handle.bundleID.map { "\($0) logs" } ?? "unified log") \(id), \(state), \(shown.count) of \(all.count) lines"
        return CommandResult(
            text: ([handle.summary, header] + (note.map { [$0] } ?? []) + shown).joined(separator: "\n"),
            json: [
                "handle": .string(id), "bundleID": handle.bundleID.map(JSONValue.string) ?? .null, "running": .bool(running),
                "log": .string(handle.log), "total": .number(Double(all.count)), "lines": .array(shown.map(JSONValue.string)),
            ]
        )
    }

    /// Terminates the app, which ends devicectl, and reports how the app exited. devicectl does not forward signals to
    /// simulator apps, so interrupting devicectl would leave the app running. Throws `app_crashed` when the app had
    /// already ended by a crash signal and its report appears.
    public static func stop(handle id: String) async throws -> CommandResult {
        let handle = try load(id)
        guard let bundleID = handle.bundleID else { return try await stopStream(handle) }
        if isRunning(handle) {
            let target = try await TargetResolver.resolve(handle.udid)
            do {
                _ = try await AppCommands.terminate(target, bundleID: bundleID)
            } catch let error as DeviceLoopError where error.code == .appNotRunning {}
            if try await !RunnerProcess.waitForExit(handle.pid, matching: handle.identity, timeout: .seconds(15)), isRunning(handle) {
                kill(handle.pid, SIGKILL)
            }
        }
        defer { remove(handle) }
        let result = exitResult(id)
        let pid = result.flatMap(AppCommands.processID)
        let ending =
            result.map { AppCommands.exitLine(bundleID, pid: pid, result: $0) }
            ?? "devicectl reported no exit for \(bundleID)"
        let note = try await checkForCrash(handle)
        let count = lines(handle).count
        return CommandResult(
            text: "\(handle.summary)\nstopped \(id), \(count) lines\n\(ending)\n\(note.map { "\($0)\n" } ?? "")saved \(handle.log)",
            json: [
                "handle": .string(id), "bundleID": .string(bundleID), "pid": pid.map { .number(Double($0)) } ?? .null,
                "log": .string(handle.log), "total": .number(Double(count)), "terminationResult": result?["terminationResult"] ?? .null,
            ],
            files: [URL(filePath: handle.log)]
        )
    }

    /// Ends `log stream` with SIGTERM, which simctl passes on. After SIGKILL, `log` keeps running in the simulator.
    static func stopStream(_ handle: LogHandle) async throws -> CommandResult {
        if isRunning(handle) {
            kill(handle.pid, SIGTERM)
            if try await !RunnerProcess.waitForExit(handle.pid, matching: handle.identity, timeout: .seconds(5)), isRunning(handle) {
                kill(handle.pid, SIGKILL)
            }
        }
        remove(handle)
        let count = lines(handle).count
        return CommandResult(
            text: "\(handle.summary)\nstopped \(handle.id), \(count) lines\nsaved \(handle.log)",
            json: ["handle": .string(handle.id), "bundleID": .null, "log": .string(handle.log), "total": .number(Double(count))],
            files: [URL(filePath: handle.log)]
        )
    }

    static func select(_ lines: [String], tail: Int?, grep: String?) -> [String] {
        let matching = grep.map { text in lines.filter { $0.contains(text) } } ?? lines
        return tail.map { Array(matching.suffix(max(0, $0))) } ?? matching
    }

    /// True while `handle.pid` is still the devicectl or simctl process the handle was saved for.
    static func isRunning(_ handle: LogHandle) -> Bool {
        handle.identity != nil && RunnerProcess.state(of: handle.pid, matching: handle.identity) == .running
    }

    static func save(_ handle: LogHandle) throws {
        let file = try Paths.ensureDirectory(directory).appending(path: "\(handle.id).json")
        try JSONEncoder().encode(handle).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func load(_ id: String) throws -> LogHandle {
        guard id.allSatisfy(\.isHexDigit), let data = try? Data(contentsOf: directory.appending(path: "\(id).json")),
            let handle = try? JSONDecoder().decode(LogHandle.self, from: data)
        else {
            throw DeviceLoopError(
                .badArguments,
                "No log capture with handle \(id).",
                fix: "Use the handle printed by `deviceloop logs start`. A stopped capture leaves only its log file."
            )
        }
        return handle
    }

    static func remove(_ handle: LogHandle) {
        try? FileManager.default.removeItem(at: directory.appending(path: "\(handle.id).json"))
        try? FileManager.default.removeItem(at: resultFile(handle.id))
    }

    /// devicectl's `--json-output`, written when the app exits.
    static func resultFile(_ id: String) -> URL {
        directory.appending(path: "\(id).result.json")
    }

    /// The `result` in the result file, nil until devicectl exits.
    static func exitResult(_ id: String) -> JSONValue? {
        (try? JSONValue(data: Data(contentsOf: resultFile(id))))?["result"]
    }

    /// `CrashCommands.checkForCrash` for an app capture that ended, with the result file's write time as the exit time.
    private static func checkForCrash(_ handle: LogHandle) async throws -> String? {
        guard let bundleID = handle.bundleID, let result = exitResult(handle.id), CrashCommands.crashSignal(in: result) != nil else {
            return nil
        }
        let written = try? resultFile(handle.id).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return try await CrashCommands.checkForCrash(
            TargetResolver.resolve(handle.udid), bundleID: bundleID, result: result, launchedAt: handle.startedAt,
            exitedAt: written ?? Date(), log: handle.log)
    }

    /// Throws `device_busy` while another capture of `bundleID`, or of the unified log when nil, on `target` runs.
    static func checkIdle(_ target: Target, bundleID: String?) throws {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let other = try? JSONDecoder().decode(LogHandle.self, from: data),
                other.udid == target.udid, other.bundleID == bundleID, isRunning(other)
            else { continue }
            throw DeviceLoopError(
                .deviceBusy,
                "\(bundleID ?? "The unified log") on \(target.name) is already being captured as \(other.id).",
                fix: "Read it with `deviceloop logs read \(other.id)`, or stop it with `deviceloop logs stop \(other.id)`.",
                device: target.name
            )
        }
    }

    /// Polls for up to 5 s until `log stream` prints its filter line or a first event. Throws when it exits first.
    static func waitForStream(_ handle: LogHandle) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let running = isRunning(handle)
            let output = lines(handle)
            guard running else {
                throw DeviceLoopError(
                    .badArguments,
                    "log stream on \(handle.summary) exited: \(output.last ?? "no output")",
                    fix: "Check the predicate with `log help predicates`."
                )
            }
            if output.contains(where: { $0.hasPrefix("{") || $0.hasPrefix("Filtering") }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Polls for the app's pid for up to 30 s. When devicectl exits first, throws `app_crashed` when `crashCheck`, by default
    /// `CrashCommands.checkForCrash`, finds a crash report, and `app_not_running` otherwise. When devicectl fails on a device,
    /// throws `device_locked` when `requireUnlocked` finds it locked.
    static func waitForLaunch(
        _ handle: LogHandle, bundleID: String, command: [String], target: Target,
        crashCheck: ((JSONValue) async throws -> String?)? = nil,
        requireUnlocked: (Target) async throws -> Void = RunnerSession.requireUnlocked
    ) async throws -> Int32 {
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            if !isRunning(handle) {
                let output = String(lines(handle).joined(separator: "\n").suffix(2000))
                let result: JSONValue
                do {
                    result = try Devicectl.result(at: resultFile(handle.id), arguments: command, stderr: output, target: target)
                } catch let error as DeviceLoopError where error.code == .deviceError && !target.isSimulator {
                    try await requireUnlocked(target)
                    throw error
                }
                let pid = AppCommands.processID(in: result)
                let note =
                    if let crashCheck {
                        try await crashCheck(result)
                    } else {
                        try await CrashCommands.checkForCrash(
                            target, bundleID: bundleID, result: result, launchedAt: handle.startedAt, exitedAt: Date(), log: handle.log)
                    }
                throw DeviceLoopError(
                    .appNotRunning,
                    "\(bundleID) exited right after launch on \(target.summary).",
                    fix: "Read its output in \(handle.log), and run `deviceloop crashes` for a crash report.",
                    detail: AppCommands.exitLine(bundleID, pid: pid, result: result) + (note.map { "\n\($0)" } ?? ""),
                    device: target.name
                )
            }
            if let pid = try await DeviceQueries.runningApps(target)[bundleID]?.first { return pid }
            guard ContinuousClock.now < deadline else {
                throw DeviceLoopError(
                    .timeout,
                    "\(bundleID) did not start on \(target.summary) within 30 s.",
                    fix: "Run `deviceloop launch \(bundleID) --console` to see why.",
                    device: target.name
                )
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func lines(_ handle: LogHandle) -> [String] {
        var splitter = LineSplitter()
        let lines = splitter.feed((try? Data(contentsOf: URL(filePath: handle.log))) ?? Data())
        return lines + (splitter.finish().map { [$0] } ?? [])
    }
}
