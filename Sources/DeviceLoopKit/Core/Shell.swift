//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Darwin
import Foundation

public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { status == 0 }
}

/// Runs other tools.
public enum Shell {
    /// Runs `arguments[0]` (resolved on PATH) and waits for it to exit.
    /// On timeout the process gets SIGTERM, then SIGKILL, and `DeviceLoopError.timeout` is thrown.
    public static func run(
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: Duration = .seconds(120)
    ) async throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stdoutTask = Task { await readToEnd(stdoutPipe.fileHandleForReading) }
        let stderrTask = Task { await readToEnd(stderrPipe.fileHandleForReading) }

        let exited = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }

        do {
            try process.run()
        } catch {
            throw DeviceLoopError(.internalError, "Could not start \(arguments.first ?? "process").", detail: "\(error)")
        }

        let status = await withTaskGroup(of: Int32?.self) { group in
            group.addTask {
                for await status in exited { return status }
                // The stream only ends without a value when this task is cancelled.
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let status else {
            process.terminate()
            try? await Task.sleep(for: .milliseconds(500))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            if Task.isCancelled { throw CancellationError() }
            throw DeviceLoopError(
                .timeout,
                "\(arguments.prefix(3).joined(separator: " ")) did not finish within \(timeout).",
                detail: arguments.joined(separator: " ")
            )
        }

        return ShellResult(status: status, stdout: await stdoutTask.value, stderr: await stderrTask.value)
    }

    /// Starts a long-lived process in its own session so it outlives the calling CLI.
    /// Output goes to `log`. The process starts with default signal handlers and no blocked signals. Returns the pid.
    @discardableResult
    public static func spawnDetached(
        _ arguments: [String],
        log: URL,
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
    ) throws -> pid_t {
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        if let currentDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, currentDirectory.path)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var signals = sigset_t()
        sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)
        sigfillset(&signals)
        posix_spawnattr_setsigdefault(&attributes, &signals)

        let argv = (["/usr/bin/env"] + arguments).map { strdup($0) } + [nil]
        let merged = ProcessInfo.processInfo.environment.merging(environment ?? [:]) { _, new in new }
        let envp = merged.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv + envp { free(pointer) }
        }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/usr/bin/env", &actions, &attributes, argv, envp)
        guard status == 0 else {
            throw DeviceLoopError(
                .internalError, "Could not start \(arguments.first ?? "process").", detail: String(cString: strerror(status)))
        }
        return pid
    }

    /// Reads a pipe to EOF on a GCD thread so a blocked read never holds a Swift concurrency thread.
    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: handle.readDataToEndOfFile()) }
        }
    }

    /// Posts a macOS notification with sound through osascript without waiting. `DEVICELOOP_NOTIFY=0` turns it off.
    @discardableResult
    static func notify(_ message: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard environment["DEVICELOOP_NOTIFY"] != "0" else { return false }
        let script = ["on run argv", "display notification (item 1 of argv) with title \"DeviceLoop\" sound name \"Glass\"", "end run"]
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = script.flatMap { ["-e", $0] } + [message]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        return (try? process.run()) != nil
    }

    public static func isRunning(_ pid: pid_t) -> Bool {
        pid > 0 && kill(pid, 0) == 0
    }
}
