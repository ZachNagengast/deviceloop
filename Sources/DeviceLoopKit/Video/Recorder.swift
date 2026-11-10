//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import CoreMedia
import Darwin
import Foundation
import Synchronization

/// Seconds on the host time clock.
func hostNow() -> Double {
    CMClockGetTime(CMClockGetHostTimeClock()).seconds
}

/// A running recording, saved as `Paths.home/recordings/<id>.json` so another process can stop it.
struct RecordingHandle: Codable, Sendable {
    var id: String
    var udid: String
    var summary: String
    var simulator: Bool
    var pid: Int32
    /// Start time of the `pid` process in microseconds since 1970.
    var pidStart: UInt64?
    var video: String
    /// Host time of the first video frame.
    var startedAt: Double
}

/// The finished file and what is needed to line it up with host time.
struct StoppedRecording: Sendable {
    var handle: RecordingHandle
    var video: URL
    /// Video time of the stop request.
    var endAt: Double
    /// Video times of frames the capture helper dropped.
    var drops: [Double]
    /// Capture slot measured from the helper's frame timestamps. Nil on simulators.
    var slot: Double?
    /// The AVFoundation source the capture helper recorded. Nil on simulators.
    var source: AnimationReport.CaptureSource?
    /// The capture helper's frame clock, `host` or `arrival`. Nil on simulators.
    var clock: String?
    /// Range of arrival time minus timestamp with the `arrival` clock, in seconds.
    var arrivalSpread: Double?
}

/// Starts and stops screen recordings: `simctl io recordVideo` on simulators, the USB capture helper on devices.
enum Recorder {
    static var directory: URL { Paths.home.appending(path: "recordings", directoryHint: .isDirectory) }

    /// Holds the recorder log and the capture helper's state files.
    static func stateDirectory(_ id: String) -> URL {
        directory.appending(path: id, directoryHint: .isDirectory)
    }

    /// Runs `preflight` first, or only `checkIdle` when the caller already ran `preflight`.
    static func start(_ target: Target, video: URL, preflighted: Bool = false) async throws -> RecordingHandle {
        if preflighted { try checkIdle(target) } else { try await preflight(target) }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let state = try Paths.ensureDirectory(stateDirectory(id))
        try Paths.ensureDirectory(video.deletingLastPathComponent())
        var handle = RecordingHandle(
            id: id,
            udid: target.udid,
            summary: target.summary,
            simulator: target.isSimulator,
            pid: 0,
            video: video.path,
            startedAt: 0
        )
        do {
            if target.isSimulator {
                try await startSimulator(target, handle: &handle)
            } else {
                try await startDevice(target, handle: &handle)
            }
        } catch {
            await abandon(handle)
            try? FileManager.default.removeItem(at: state)
            throw error
        }
        let file = directory.appending(path: "\(id).json")
        try JSONEncoder().encode(handle).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return handle
    }

    static func load(_ id: String) throws -> RecordingHandle {
        let file = directory.appending(path: "\(id).json")
        guard id.allSatisfy(\.isHexDigit), let contents = try? Data(contentsOf: file) else {
            throw DeviceLoopError(
                .badArguments,
                "No recording with handle \(id).",
                fix: "Use the handle printed by `deviceloop video start`, or start a new recording."
            )
        }
        return try JSONDecoder().decode(RecordingHandle.self, from: contents)
    }

    static func stop(_ handle: RecordingHandle) async throws -> StoppedRecording {
        let stoppedAt = hostNow()
        let state = stateDirectory(handle.id)
        defer {
            if !isRunning(handle) {
                try? FileManager.default.removeItem(at: directory.appending(path: "\(handle.id).json"))
                try? FileManager.default.removeItem(at: state)
            }
        }
        var drops: [Double] = []
        var slot: Double?
        var startedAt = handle.startedAt
        var lastFrameEnd: Double?
        var source: AnimationReport.CaptureSource?
        var clock: String?
        var arrivalSpread: Double?
        let wasRunning = isRunning(handle)
        if handle.simulator {
            if wasRunning {
                kill(handle.pid, SIGINT)
                guard await waitForExit(handle.pid, seconds: 15) else {
                    throw DeviceLoopError(.timeout, "simctl did not finish the recording within 15 s.", detail: log(state))
                }
            }
        } else {
            defer { markCaptureEnded() }
            FileManager.default.createFile(atPath: state.appending(path: "stop").path, contents: nil)
            if wasRunning { kill(handle.pid, SIGINT) }
            let done = state.appending(path: "done")
            let deadline = hostNow() + 20
            while !FileManager.default.fileExists(atPath: done.path) {
                if hostNow() > deadline || (handle.pid > 0 && !isRunning(handle)) {
                    throw DeviceLoopError(.timeout, "The capture helper did not finish the recording.", detail: log(state))
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            // The helper still holds the device for a moment after writing `done`.
            if handle.pid > 0 { _ = await waitForExit(handle.pid, seconds: 3) }
            if let sidecar = try? JSONDecoder().decode(CaptureSidecar.self, from: Data(contentsOf: state.appending(path: "frames.json"))) {
                startedAt = sidecar.firstFrameAt
                drops = sidecar.drops.map { $0 - sidecar.firstFrameAt }
                slot = VideoAnalyzer.snappedSlot(zip(sidecar.frames.dropFirst(), sidecar.frames).map { $0 - $1 })
                lastFrameEnd = (sidecar.frames.last ?? sidecar.firstFrameAt) - sidecar.firstFrameAt + (slot ?? 0)
                source = sidecar.source
                clock = sidecar.clock
                arrivalSpread = sidecar.arrivalSpread
            }
        }
        let video = URL(filePath: handle.video)
        let size = (try? FileManager.default.attributesOfItem(atPath: video.path)[.size] as? Int) ?? 0
        guard size > 0 else {
            let message =
                handle.simulator && !wasRunning
                ? "simctl recordVideo exited before the stop request and left \(video.path) empty."
                : "The recording at \(video.path) is empty."
            throw DeviceLoopError(.deviceError, message, detail: log(state))
        }
        var finished = handle
        finished.startedAt = startedAt
        let endAt = min(max(0, stoppedAt - startedAt), lastFrameEnd ?? .infinity)
        return StoppedRecording(
            handle: finished, video: video, endAt: endAt, drops: drops, slot: slot, source: source, clock: clock,
            arrivalSpread: arrivalSpread)
    }

    /// True while `handle.pid` is still the recorder process the handle was saved for.
    static func isRunning(_ handle: RecordingHandle) -> Bool {
        handle.pid > 0 && handle.pidStart != nil && processStart(handle.pid) == handle.pidStart
    }

    /// Start time of `pid` in microseconds since 1970, or nil when no such process exists.
    static func processStart(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    /// Stops the recorder left behind by a failed start, and starts the USB capture cool-down when the capture helper ran.
    static func abandon(_ handle: RecordingHandle) async {
        var recorder = handle
        if !handle.simulator {
            let state = stateDirectory(handle.id)
            FileManager.default.createFile(atPath: state.appending(path: "stop").path, contents: nil)
            recorder.pid = helperPID(state)
            recorder.pidStart = processStart(recorder.pid)
        }
        if isRunning(recorder) {
            kill(recorder.pid, SIGINT)
            _ = await waitForExit(recorder.pid, seconds: handle.simulator ? 15 : 2)
        }
        if !handle.simulator, recorder.pid > 0 { markCaptureEnded() }
    }

    /// Throws unless `target` is ready and not being recorded and, for a device, on USB under a name no other connected
    /// device has. Waits up to `wiredTimeout` for a device to list as wired, and waits out `captureCooldown`.
    static func preflight(
        _ target: Target, list: () async throws -> [Target] = Devicectl.listTargets, wiredTimeout: Duration = .seconds(5)
    ) async throws {
        try DeviceQueries.requireReady(target)
        try checkIdle(target)
        guard !target.isSimulator else { return }
        var targets = try await list()
        var current = targets.first { $0.udid == target.udid } ?? target
        // Right after a USB capture stops, devicectl can list the device on the local network for a moment.
        let wiredDeadline = ContinuousClock.now.advanced(by: wiredTimeout)
        while current.transport != "wired", ContinuousClock.now < wiredDeadline {
            try await Task.sleep(for: .milliseconds(300))
            targets = try await list()
            current = targets.first { $0.udid == target.udid } ?? current
        }
        try requireUSBSource(current, among: targets)
        if let ended = lastCaptureEnded() {
            let wait = captureCooldown - (Date().timeIntervalSince1970 - ended)
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        }
    }

    /// Throws `recorder_busy` when another DeviceLoop recording of `target` is still running, and forgets stale ones.
    static func checkIdle(_ target: Target) throws {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let contents = try? Data(contentsOf: file), let other = try? JSONDecoder().decode(RecordingHandle.self, from: contents),
                other.udid == target.udid
            else { continue }
            if isRunning(other) {
                throw DeviceLoopError(
                    .recorderBusy,
                    "\(target.name) is already being recorded (handle \(other.id)).",
                    fix: "Stop it with: deviceloop video stop \(other.id)",
                    device: target.name
                )
            }
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: stateDirectory(file.deletingPathExtension().lastPathComponent))
        }
    }

    static func startSimulator(_ target: Target, handle: inout RecordingHandle) async throws {
        let state = stateDirectory(handle.id)
        let display = await DeviceCommands.optionalDisplays(target)?.visible
        handle.pid = try Shell.spawnDetached(
            ["xcrun", "simctl", "io", target.udid, "recordVideo", "--codec", "h264", "--force"]
                + (display.map { ["--display=\($0.name)"] } ?? []) + [handle.video],
            log: state.appending(path: "recorder.log")
        )
        handle.pidStart = processStart(handle.pid)
        let deadline = hostNow() + 15
        while true {
            let text = log(state)
            if text.contains("Recording started") {
                handle.startedAt = hostNow()
                return
            }
            if await waitForExit(handle.pid, seconds: 0) {
                if text.contains("already in progress") {
                    throw DeviceLoopError(
                        .recorderBusy,
                        "Another recording of \(target.name) is in progress.",
                        fix: "Stop the other recording (Device Hub, QuickTime or another agent), then retry. If none is running, "
                            + "a recorder killed before it finished may have left it open, and rebooting the simulator may clear it: "
                            + "xcrun simctl shutdown \(target.udid) && xcrun simctl boot \(target.udid)",
                        detail: text,
                        device: target.name
                    )
                }
                throw DeviceLoopError(.deviceError, "simctl recordVideo exited before recording.", detail: text, device: target.name)
            }
            if hostNow() > deadline {
                throw DeviceLoopError(.timeout, "simctl recordVideo did not start within 15 s.", detail: text, device: target.name)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Throws unless `target` is on a USB cable and no other connected device shares its name, because the capture helper
    /// picks the AVFoundation source by name.
    static func requireUSBSource(_ target: Target, among targets: [Target]) throws {
        guard target.transport == "wired" else {
            throw DeviceLoopError(
                .unsupportedOnTarget,
                "Video of \(target.summary) needs USB screen capture, and it is connected over \(target.transport ?? "an unknown transport").",
                fix: "Connect \(target.name) with a USB cable, then retry.",
                device: target.name
            )
        }
        let name = TargetResolver.folded(target.name)
        let others = targets.filter { !$0.isSimulator && $0.isReady && $0.udid != target.udid && TargetResolver.folded($0.name) == name }
        guard others.isEmpty else {
            throw DeviceLoopError(
                .deviceAmbiguous,
                "\(others.count + 1) devices are named \(target.name), so the USB capture source cannot be tied to \(target.udid).",
                fix: "Rename one of them in Settings > General > About > Name, then retry.",
                alternatives: ([target] + others).map { "\($0.name) [\($0.udid)] \($0.transport ?? "unknown")" },
                device: target.name
            )
        }
    }

    /// A capture helper started within about 4 s of the end of any USB capture, of the same device or another, can find
    /// no screen capture source.
    static let captureCooldown = 5.0

    /// Where the end time of the last USB capture is kept, in seconds since 1970.
    static var lastCaptureEnd: URL { directory.appending(path: ".last-capture-ended") }

    /// The end time of the last USB capture in seconds since 1970, or nil when none is recorded.
    static func lastCaptureEnded() -> Double? {
        (try? String(contentsOf: lastCaptureEnd, encoding: .utf8)).flatMap { Double($0) }
    }

    /// Records now as the end time of the last USB capture.
    static func markCaptureEnded() {
        try? Data("\(Date().timeIntervalSince1970)".utf8).write(to: lastCaptureEnd)
    }

    static func startDevice(_ target: Target, handle: inout RecordingHandle) async throws {
        let state = stateDirectory(handle.id)
        let app = try await CaptureApp.ensure()
        let logPath = state.appending(path: "recorder.log").path
        let opened = try await Shell.run([
            "/usr/bin/open", "-n", "-g",
            "--stdout", logPath,
            "--stderr", logPath,
            app.path, "--args", "capture-helper",
            "--name", target.name, "--output", handle.video, "--state", state.path,
        ])
        guard opened.succeeded else {
            throw DeviceLoopError(.internalError, "Could not launch the capture helper app.", detail: opened.stderrString)
        }

        var deadline = hostNow() + 20
        var askedForPermission = false
        while true {
            if let errorJSON = try? Data(contentsOf: state.appending(path: "error.json")) {
                throw (try? JSONDecoder().decode(DeviceLoopError.self, from: errorJSON))
                    ?? DeviceLoopError(.internalError, "The capture helper failed.", detail: String(decoding: errorJSON, as: UTF8.self))
            }
            if let ready = try? String(contentsOf: state.appending(path: "ready"), encoding: .utf8), let first = Double(ready) {
                handle.startedAt = first
                handle.pid = helperPID(state)
                handle.pidStart = processStart(handle.pid)
                return
            }
            if !askedForPermission, FileManager.default.fileExists(atPath: state.appending(path: "waiting-permission").path) {
                askedForPermission = true
                deadline = hostNow() + 120
                FileHandle.standardError.write(
                    Data("Waiting for camera permission: click Allow for DeviceLoopCapture in the macOS dialog.\n".utf8))
            }
            if hostNow() > deadline {
                if askedForPermission {
                    throw DeviceLoopError(
                        .screenCaptureDenied,
                        "No answer to the camera permission dialog for DeviceLoopCapture.",
                        fix:
                            "Click Allow in the dialog, or turn on DeviceLoopCapture in System Settings > Privacy and Security > Camera, then retry.",
                        device: target.name
                    )
                }
                throw DeviceLoopError(
                    .timeout,
                    "USB screen capture of \(target.name) did not start within 20 s.",
                    fix: "Unlock the device, keep the USB cable connected, and retry.",
                    detail: log(state),
                    device: target.name
                )
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The process ID the capture helper wrote to `state`, or 0 before it wrote one.
    static func helperPID(_ state: URL) -> Int32 {
        Int32((try? String(contentsOf: state.appending(path: "pid"), encoding: .utf8)) ?? "") ?? 0
    }

    /// Waits up to `seconds` for `pid` to exit, reaping it when it is a child of this process.
    static func waitForExit(_ pid: pid_t, seconds: Double) async -> Bool {
        let deadline = hostNow() + seconds
        while true {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && !Shell.isRunning(pid)) { return true }
            if hostNow() >= deadline { return false }
            if Task.isCancelled { usleep(10_000) } else { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    static func log(_ state: URL) -> String {
        (try? String(contentsOf: state.appending(path: "recorder.log"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Per-frame host timestamps written by the capture helper next to the movie.
struct CaptureSidecar: Codable, Sendable {
    /// `host` when timestamps were converted from the capture session clock, `arrival` when shifted by the first
    /// frame's arrival time because the session had no clock.
    var clock = "host"
    /// Largest minus smallest arrival time minus timestamp over the frames, with the `arrival` clock.
    var arrivalSpread: Double?
    var firstFrameAt: Double
    var frames: [Double]
    var drops: [Double]
    var width: Int
    var height: Int
    var source: AnimationReport.CaptureSource?
}

/// The DeviceLoopCapture.app bundle that macOS shows in the camera permission dialog.
enum CaptureApp {
    static let bundleIdentifier = "com.argmaxinc.deviceloop.capture"

    /// The bundled `<prefix>/libexec/DeviceLoopCapture.app` when its signature verifies. Otherwise builds
    /// `Paths.home/DeviceLoopCapture.app` from `executable`, rebuilding only when the executable changed.
    static func ensure(executable: URL? = Bundle.main.executableURL) async throws -> URL {
        if let bundled = Paths.bundledCaptureApp(executable: executable), await signatureProblem(bundled) == nil {
            return bundled
        }
        let app = Paths.home.appending(path: "DeviceLoopCapture.app", directoryHint: .isDirectory)
        let stampFile = Paths.home.appending(path: "DeviceLoopCapture.stamp")
        guard let executable = executable?.resolvingSymlinksInPath() else {
            throw DeviceLoopError(.internalError, "Cannot locate the deviceloop executable to build the capture helper.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let identity = await developmentIdentity()
        let stamp = "\(executable.path) \(attributes[.size] as? Int ?? 0) \(modified) \(identity ?? "-")"
        if FileManager.default.fileExists(atPath: app.path), (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp {
            return app
        }

        try? FileManager.default.removeItem(at: app)
        let macOS = try Paths.ensureDirectory(app.appending(path: "Contents/MacOS", directoryHint: .isDirectory))
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        try FileManager.default.copyItem(at: executable, to: macOS.appending(path: "deviceloop"))
        var signedWithIdentity = false
        if let identity {
            let signed = try? await Shell.run(["codesign", "--force", "--sign", identity, app.path], timeout: .seconds(30))
            signedWithIdentity = signed?.succeeded ?? false
        }
        if !signedWithIdentity {
            let signed = try await Shell.run(["codesign", "--force", "--sign", "-", app.path])
            guard signed.succeeded else {
                throw DeviceLoopError(.internalError, "Could not sign the capture helper app.", detail: signed.stderrString)
            }
        }
        try stamp.write(to: stampFile, atomically: true, encoding: .utf8)
        return app
    }

    /// Info.plist of the built helper. `Packaging/DeviceLoopCapture-Info.plist` is the same for release builds.
    static var info: [String: Any] {
        [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "DeviceLoopCapture",
            "CFBundleExecutable": "deviceloop",
            "CFBundlePackageType": "APPL",
            "LSUIElement": true,
            "NSCameraUsageDescription": "Record the screen of a connected iPhone or iPad for animation debugging.",
        ]
    }

    /// The first `codesign --verify --strict` error line for `app`, or nil when its signature is valid.
    static func signatureProblem(_ app: URL) async -> String? {
        guard let verified = try? await Shell.run(["codesign", "--verify", "--strict", app.path], timeout: .seconds(30)) else {
            return "codesign did not run"
        }
        guard !verified.succeeded else { return nil }
        let line = verified.stderrString.split(separator: "\n").first.map(String.init) ?? "codesign exited \(verified.status)"
        return line.replacingOccurrences(of: "\(app.path): ", with: "")
    }

    /// SHA-1 of an Apple Development identity for the team `deviceloop setup` stored, or nil to sign ad hoc.
    static func developmentIdentity() async -> String? {
        guard let team = DeviceLoopConfig.team() else { return nil }
        return await SigningState.read().identities.first { $0.isDevelopment && $0.team == team }?.sha1
    }
}

/// Catches SIGINT and SIGTERM while alive so a recording is finalized instead of cut off.
final class InterruptFlag: @unchecked Sendable {
    /// Live flags in this process. Signals go back to default handling when the last one is removed.
    private static let liveCount = Mutex(0)
    private let lock = NSLock()
    private var raised = false
    private var sources: [any DispatchSourceSignal] = []

    init() {
        Self.liveCount.withLock { count in
            if count == 0 {
                signal(SIGINT, SIG_IGN)
                signal(SIGTERM, SIG_IGN)
            }
            count += 1
        }
        for number in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in self?.raise() }
            source.resume()
            sources.append(source)
        }
    }

    /// Stops catching signals, and restores default handling when no other flag is live.
    func remove() {
        guard !sources.isEmpty else { return }
        for source in sources { source.cancel() }
        sources = []
        Self.liveCount.withLock { count in
            count -= 1
            if count == 0 {
                signal(SIGINT, SIG_DFL)
                signal(SIGTERM, SIG_DFL)
            }
        }
    }

    var isRaised: Bool { lock.withLock { raised } }

    func raise() { lock.withLock { raised = true } }

    /// Sleeps for `seconds`, or until a signal when nil. Returns true when a signal or task cancellation ended the wait.
    func sleep(seconds: Double?) async -> Bool {
        let deadline = seconds.map { hostNow() + $0 }
        while !isRaised && !Task.isCancelled {
            let remaining = deadline.map { $0 - hostNow() } ?? 0.02
            if remaining <= 0 { return false }
            try? await Task.sleep(for: .seconds(min(0.02, remaining)))
        }
        return true
    }
}
