//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Darwin
import Foundation

/// Serializes session startup and shutdown across CLI processes. The lock inode is never removed.
final class SessionLock: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(for udid: String, timeout: Duration = .seconds(120)) async throws -> SessionLock {
        try await acquire(at: Paths.session(for: udid).appending(path: "session.lock"), timeout: timeout)
    }

    /// A shared lock coexists with other shared locks and excludes an exclusive one.
    static func acquire(at url: URL, timeout: Duration = .seconds(120), exclusive: Bool = true) async throws -> SessionLock {
        try Task.checkCancellation()
        try Paths.ensureDirectory(url.deletingLastPathComponent())
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw failure(at: url) }
        var transferred = false
        defer { if !transferred { close(descriptor) } }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_uid == geteuid(), metadata.st_nlink == 1,
            fchmod(descriptor, 0o600) == 0
        else { throw failure(at: url) }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 {
                try Task.checkCancellation()
                transferred = true
                return SessionLock(descriptor: descriptor)
            }
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else { throw failure(at: url) }
            guard clock.now < deadline else {
                throw DeviceLoopError(
                    .deviceBusy, "Another process is starting or stopping this runner.",
                    fix: "Wait for that operation to finish, then retry."
                )
            }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(50))))
        }
    }

    /// Holds the target's `flow.lock` while `body` runs flow `runID`, waiting up to 2 s for it. Throws device_busy naming
    /// the flow that holds it.
    static func withFlowLock<T>(_ runID: String, on target: Target, _ body: () async throws -> T) async throws -> T {
        let lock = try await acquireFlow(on: target, exclusive: true)
        defer {
            lock.record("")
            lock.release()
        }
        lock.record(runID)
        return try await body()
    }

    /// Throws device_busy while a flow runs on `target`.
    static func checkNoFlow(on target: Target) async throws {
        try await acquireFlow(on: target, exclusive: false).release()
    }

    private static func acquireFlow(on target: Target, exclusive: Bool) async throws -> SessionLock {
        let url = Paths.session(for: target.udid).appending(path: "flow.lock")
        do {
            return try await acquire(at: url, timeout: exclusive ? .seconds(2) : .zero, exclusive: exclusive)
        } catch let error as DeviceLoopError where error.code == .deviceBusy {
            let runID = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            throw DeviceLoopError(
                .deviceBusy, "\(runID.isEmpty ? "A flow" : "Flow \(runID)") is running on \(target.summary).",
                fix: "Wait for the flow to finish, or stop it with flow_cancel or Ctrl-C, then retry.",
                device: target.name
            )
        }
    }

    /// Replaces the lock file's contents with `text`, which other processes read to name the owner.
    private func record(_ text: String) {
        stateLock.withLock {
            guard descriptor >= 0, ftruncate(descriptor, 0) == 0 else { return }
            _ = text.withCString { pwrite(descriptor, $0, strlen($0), 0) }
        }
    }

    /// Releases this descriptor once. Removing the file would split future callers onto another lock inode.
    func release() {
        stateLock.withLock {
            guard descriptor >= 0 else { return }
            flock(descriptor, LOCK_UN)
            close(descriptor)
            descriptor = -1
        }
    }

    deinit { release() }

    private static func failure(at url: URL) -> DeviceLoopError {
        DeviceLoopError(
            .internalError, "Could not acquire the runner session lock.",
            fix: "Check ownership and write permissions at \(url.path)."
        )
    }
}
