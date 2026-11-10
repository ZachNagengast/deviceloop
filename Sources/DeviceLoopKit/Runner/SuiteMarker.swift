//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// Marks a target as running a `test run` job so the UI runner and other jobs stay off it.
struct SuiteMarker: Codable, Sendable, Equatable {
    var job: String
    var pid: pid_t
    var processIdentity: RunnerProcessIdentity

    static func url(for udid: String) -> URL {
        Paths.session(for: udid).appending(path: "suite.json")
    }

    static func read(for udid: String) -> SuiteMarker? {
        guard let data = try? Data(contentsOf: url(for: udid)) else { return nil }
        return try? JSONDecoder().decode(SuiteMarker.self, from: data)
    }

    /// The marker while its xcodebuild runs. Removes one whose process exited or whose PID now belongs to another process.
    /// The caller holds the session lock.
    static func live(for udid: String) -> SuiteMarker? {
        if let marker = read(for: udid), RunnerProcess.state(of: marker.pid, matching: marker.processIdentity) != .exited {
            return marker
        }
        try? FileManager.default.removeItem(at: url(for: udid))
        return nil
    }

    /// The marker of `job` on any target while its xcodebuild runs.
    static func live(job: String) -> SuiteMarker? {
        let sessions = Paths.home.appending(path: "sessions", directoryHint: .isDirectory)
        let udids = (try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []
        return udids.lazy.compactMap { read(for: $0) }.first { marker in
            marker.job == job && RunnerProcess.state(of: marker.pid, matching: marker.processIdentity) != .exited
        }
    }

    func write(for udid: String) throws {
        try Paths.ensureDirectory(Paths.session(for: udid))
        try JSONEncoder().encode(self).write(to: Self.url(for: udid), options: .atomic)
    }

    /// Removes the marker for `udid` if it still belongs to `job`.
    static func remove(job: String, for udid: String) async {
        guard let lock = try? await SessionLock.acquire(for: udid, timeout: .seconds(10)) else { return }
        defer { lock.release() }
        if read(for: udid)?.job == job { try? FileManager.default.removeItem(at: url(for: udid)) }
    }

    func busy(_ target: Target) -> DeviceLoopError {
        DeviceLoopError(
            .deviceBusy, "Test job \(job) is running on \(target.name).",
            fix: "Wait for it to finish, or cancel it with kill -INT \(pid).", device: target.name
        )
    }
}
