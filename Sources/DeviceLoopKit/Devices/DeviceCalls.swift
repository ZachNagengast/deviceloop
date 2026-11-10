//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

extension Devicectl {
    /// `devicectl device <subcommand> -d <udid>`.
    static func device(_ target: Target, _ subcommand: String...) -> [String] {
        ["device"] + subcommand + ["-d", target.udid]
    }

    /// Like `run`, but passes `passthrough` after `--` and also returns stdout.
    /// `process launch` takes app arguments after `--`, and `pasteboard paste` prints its payload.
    static func runCapturing(
        _ arguments: [String],
        passthrough: [String] = [],
        target: Target?,
        timeout: Duration = .seconds(60)
    ) async throws -> (result: JSONValue, stdout: Data) {
        let output = jsonOutputPath()
        defer { try? FileManager.default.removeItem(at: output) }
        let shell = try await Shell.run(command(arguments, output: output, passthrough: passthrough), timeout: timeout)
        do {
            return (try result(at: output, arguments: arguments, stderr: shell.stderrString, target: target), shell.stdout)
        } catch let error as DeviceLoopError where error.code == .deviceError {
            throw await lockedError(error, target: target, arguments: arguments) ?? error
        }
    }

    /// `device_locked` in place of `error` when the device reports that it needs its passcode.
    private static func lockedError(_ error: DeviceLoopError, target: Target?, arguments: [String]) async -> DeviceLoopError? {
        guard let target, !target.isSimulator, target.supports(Capability.lockState), !arguments.contains("lockState"),
            let lock = try? await run(device(target, "info", "lockState"), target: target, timeout: .seconds(10)),
            lock["passcodeRequired"]?.bool == true
        else { return nil }
        return DeviceLoopError(
            .deviceLocked,
            "\(target.name) is locked: \(error.message)",
            fix: "Unlock \(target.name), then retry.",
            detail: error.detail,
            device: target.name
        )
    }

    /// Runs devicectl, passes each line of its stdout and stderr to `lines`, and waits for it to exit, however long that takes.
    /// The first SIGINT or SIGTERM to this process calls `interrupted` instead of ending it. A second one, or devicectl still
    /// running 5 s after `interrupted` returns, terminates devicectl and throws CancellationError.
    /// Cancelling the task sends SIGTERM to devicectl.
    static func runAttached(
        _ arguments: [String],
        passthrough: [String] = [],
        target: Target?,
        lines: @escaping @Sendable (String) -> Void,
        interrupted: @escaping @Sendable () async throws -> Void
    ) async throws -> JSONValue {
        let output = jsonOutputPath()
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = Array(command(arguments, output: output, passthrough: passthrough).dropFirst())
        let interrupt = InterruptFlag()
        defer { interrupt.remove() }
        if try await attach(process, interrupt: interrupt, lines: lines, interrupted: interrupted) { throw CancellationError() }
        return try result(at: output, arguments: arguments, stderr: "", target: target)
    }

    /// Runs `process`, passes each line of its stdout and stderr to `lines`, and waits for it to exit. The first signal on
    /// `interrupt` calls `interrupted` and writes its error to stderr. A second signal, caught by the flag `again` returns, or
    /// `process` still running `grace` after `interrupted` returns, terminates `process`. Returns true when that ended it.
    static func attach(
        _ process: Process,
        interrupt: InterruptFlag,
        again: @escaping @Sendable () -> InterruptFlag = { InterruptFlag() },
        grace: Duration = .seconds(5),
        lines: @escaping @Sendable (String) -> Void,
        interrupted: @escaping @Sendable () async throws -> Void
    ) async throws -> Bool {
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let exited = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in continuation.finish() }
        }
        do {
            try process.run()
        } catch {
            throw DeviceLoopError(.internalError, "Could not start devicectl.", detail: "\(error)")
        }
        let reader = Task { await forwardLines(pipe.fileHandleForReading, to: lines) }
        let watcher = Task {
            guard await interrupt.sleep(seconds: nil), interrupt.isRaised else { return false }
            let stop = again()
            defer { stop.remove() }
            let stopping = Task {
                do {
                    try await interrupted()
                } catch {
                    if !Task.isCancelled { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)) }
                }
                try? await Task.sleep(for: grace)
                stop.raise()
            }
            defer { stopping.cancel() }
            guard await stop.sleep(seconds: nil), stop.isRaised, process.isRunning else { return false }
            process.terminate()
            return true
        }
        await withTaskCancellationHandler {
            for await _ in exited {}
        } onCancel: {
            process.terminate()
        }
        watcher.cancel()
        await reader.value
        return await watcher.value
    }

    /// Reads `handle` to EOF on a GCD thread and passes each line to `sink`, a partial last line included.
    static func forwardLines(_ handle: FileHandle, to sink: @escaping @Sendable (String) -> Void) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var splitter = LineSplitter()
                while case let chunk = handle.availableData, !chunk.isEmpty {
                    splitter.feed(chunk).forEach(sink)
                }
                if let last = splitter.finish() { sink(last) }
                continuation.resume()
            }
        }
    }

    private static func jsonOutputPath() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "deviceloop-devicectl-\(UUID().uuidString).json")
    }

    static func command(_ arguments: [String], output: URL, passthrough: [String]) -> [String] {
        ["xcrun", "devicectl"] + arguments + ["--json-output", output.path, "--quiet"]
            + (passthrough.isEmpty ? [] : ["--"] + passthrough)
    }

    static func result(at output: URL, arguments: [String], stderr: String, target: Target?) throws -> JSONValue {
        guard let contents = try? Data(contentsOf: output), let json = try? JSONValue(data: contents) else {
            if stderr.contains("unable to find utility") {
                throw DeviceLoopError(
                    .xcodeMissing,
                    "devicectl is not available in the selected Xcode.",
                    fix: "Install Xcode 27 or later and run: sudo xcode-select -s /Applications/Xcode.app"
                )
            }
            throw DeviceLoopError(
                .deviceError,
                "devicectl \(arguments.prefix(3).joined(separator: " ")) failed without output.",
                detail: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                device: target?.name
            )
        }
        if json.value(at: "info.outcome")?.string == "success" {
            return json["result"] ?? .null
        }
        throw translate(json["error"] ?? .null, target: target)
    }
}

/// Reads and checks the target state the parity commands route on.
enum DeviceQueries {
    /// Throws `device_offline` for a shut-down simulator or a disconnected device.
    static func requireReady(_ target: Target) throws {
        guard !target.isReady else { return }
        if target.isSimulator {
            throw DeviceLoopError(
                .deviceOffline,
                "\(target.name) is \(target.bootState ?? "not booted").",
                fix: "Boot it: xcrun simctl boot \(target.udid)",
                device: target.name
            )
        }
        throw DeviceLoopError(
            .deviceOffline,
            "\(target.name) is \(target.connectionState).",
            fix: "Connect the device with a cable (or join the same network), unlock it, and retry.",
            device: target.name
        )
    }

    /// Throws `unsupported_on_target` naming `capability` when the target lacks it.
    static func require(_ capability: String, _ what: String, on target: Target) throws {
        try requireReady(target)
        guard target.supports(capability) else {
            throw DeviceLoopError.unsupported(what, on: target, capability: capability)
        }
    }

    static func displays(_ target: Target) async throws -> DeviceDisplays {
        DeviceDisplays(devicectl: try await Devicectl.run(Devicectl.device(target, "info", "displays"), target: target))
    }

    /// Every app on the target, system apps included.
    static func apps(_ target: Target) async throws -> [InstalledApp] {
        let arguments = Devicectl.device(target, "info", "apps") + ["--include-all-apps"]
        return InstalledApp.list(devicectl: try await Devicectl.run(arguments, target: target))
    }

    /// One app by bundle ID. `--include-default-apps` keeps system apps such as Settings in the filtered list.
    static func installedApp(_ target: Target, bundleID: String) async throws -> InstalledApp? {
        let arguments = Devicectl.device(target, "info", "apps") + ["--bundle-id", bundleID, "--include-default-apps"]
        return InstalledApp.list(devicectl: try await Devicectl.run(arguments, target: target)).first { $0.bundleID == bundleID }
    }

    /// Bundle ID to pids of running apps: `launchctl list` on simulators, where devicectl reports pids without
    /// executables, and devicectl processes joined with the app list on devices.
    static func runningApps(_ target: Target) async throws -> [String: [Int32]] {
        if target.isSimulator {
            let list = try await Simctl.run(["spawn", target.udid, "launchctl", "list"])
            return RunningApps.match(launchctlList: list.stdoutString)
        }
        async let processes = Devicectl.run(Devicectl.device(target, "info", "processes"), target: target)
        async let installed = apps(target)
        return RunningApps.match(processes: try await processes, apps: try await installed)
    }

    static func appNotInstalled(_ bundleID: String, on target: Target) -> DeviceLoopError {
        DeviceLoopError(
            .appNotInstalled,
            "\(bundleID) is not installed on \(target.summary).",
            fix: "Install it with `deviceloop install <path>`, or find the right bundle ID with `deviceloop apps --system`.",
            device: target.name
        )
    }
}

/// Splits a byte stream into lines without the line ending, holding a partial line until its newline arrives.
struct LineSplitter {
    private var pending = Data()

    mutating func feed(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(Self.text(pending[pending.startIndex ..< newline]))
            pending.removeSubrange(pending.startIndex ... newline)
        }
        return lines
    }

    /// The partial last line, or nil when the stream ended with a newline.
    mutating func finish() -> String? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : Self.text(pending)
    }

    /// Decodes one line and drops the carriage return of a CRLF ending, which devicectl console output uses.
    private static func text(_ bytes: Data) -> String {
        let line = String(decoding: bytes, as: UTF8.self)
        return line.hasSuffix("\r") ? String(line.dropLast()) : line
    }
}
