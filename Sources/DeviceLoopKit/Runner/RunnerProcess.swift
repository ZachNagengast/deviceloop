//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Darwin
import Foundation

/// A process's start time and user, which survive exec and tell a reused PID from the runner DeviceLoop started.
struct RunnerProcessIdentity: Codable, Sendable, Equatable {
    var startSeconds: UInt64
    var startMicroseconds: UInt64
    var userID: UInt32
}

enum RunnerProcess {
    enum State: Equatable {
        case running
        case exited
        case unknown
    }

    static func identity(of pid: pid_t) -> RunnerProcessIdentity? {
        guard let info = information(pid), info.pbi_status != SZOMB else { return nil }
        return identity(info)
    }

    /// Reads public process metadata. A replacement PID means the original process has exited.
    static func state(of pid: pid_t, matching expected: RunnerProcessIdentity?) -> State {
        guard pid > 0 else { return .unknown }
        guard let info = information(pid) else {
            // DeviceLoop runs the runner as this user, so a PID owned by another user is not the runner.
            if errno == ESRCH || errno == EPERM {
                _ = waitpid(pid, nil, WNOHANG)
                return .exited
            }
            return kill(pid, 0) == -1 && errno == ESRCH ? .exited : .unknown
        }
        if let expected, identity(info) != expected { return .exited }
        if info.pbi_status == SZOMB {
            _ = waitpid(pid, nil, WNOHANG)
            return .exited
        }
        return .running
    }

    /// Whether a child of this process exited, reaping it. Its PID cannot be reused before that.
    static func childHasExited(_ pid: pid_t) -> Bool {
        var result: pid_t
        repeat { result = waitpid(pid, nil, WNOHANG) } while result < 0 && errno == EINTR
        return result == pid || (result < 0 && errno == ECHILD)
    }

    static func waitForExit(
        _ pid: pid_t, matching expected: RunnerProcessIdentity?, timeout: Duration
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            switch state(of: pid, matching: expected) {
                case .exited: return true
                case .unknown: return false
                case .running: break
            }
            guard clock.now < deadline else { return false }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(100))))
        }
    }

    /// Sends SIGTERM, then SIGKILL after `grace`, while `pid` still has the `expected` identity. Returns true once it exited.
    static func terminate(_ pid: pid_t, matching expected: RunnerProcessIdentity?, grace: Duration = .seconds(3)) async -> Bool {
        guard let expected else { return false }
        for signal in [SIGTERM, SIGKILL] {
            switch state(of: pid, matching: expected) {
                case .exited: return true
                case .unknown: return false
                case .running: kill(pid, signal)
            }
            if (try? await waitForExit(pid, matching: expected, timeout: grace)) == true { return true }
        }
        return false
    }

    private static func information(_ pid: pid_t) -> proc_bsdinfo? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    private static func identity(_ info: proc_bsdinfo) -> RunnerProcessIdentity {
        RunnerProcessIdentity(startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec, userID: info.pbi_uid)
    }
}
