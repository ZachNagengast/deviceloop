//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Security

/// A running UI runner for one target. The CLI and MCP server share one per device through a session file.
struct RunnerSession: Sendable {
    /// The bundle ID of the fixture host app this runner was built with.
    var hostApp: String? { info.xctestrunPath.flatMap { RunnerBuild.hostBundleIdentifier(xctestrun: URL(filePath: $0)) } }

    let target: Target
    let client: RunnerClient
    let info: SessionFile

    /// Reuses a healthy runner for `target`, or builds, signs and launches one. A launch whose UI Automation passcode prompt
    /// times out starts again until `ownerWait` has passed since the first timeout.
    static func connect(_ target: Target, ownerWait: Duration = .zero, log: (String) -> Void = { _ in }) async throws -> RunnerSession {
        try Task.checkCancellation()
        try DeviceQueries.requireReady(target)
        // Covers another process holding the lock through a 660 s build-lock wait, a 600 s build and launch.
        let lock = try await SessionLock.acquire(for: target.udid, timeout: .seconds(1400))
        defer { lock.release() }
        if let existing = try await reattachUnlocked(target, log: log, replace: true) { return existing }
        return try await notifyingPerson(
            target, notify: { Shell.notify($0) },
            startup: { post in
                try await retryingPasscode(target, ownerWait: ownerWait, log: log) { try await launch(target, log: log, notify: post) }
            })
    }

    /// Runs `startup` with a notifier that posts once on a device, and posts a device_locked or ui_automation_passcode error.
    static func notifyingPerson<Value>(
        _ target: Target, notify: @escaping (String) -> Void, startup: ((String) -> Void) async throws -> Value
    ) async throws -> Value {
        var posted = false
        func post(_ message: String) {
            guard !target.isSimulator, !posted else { return }
            posted = true
            notify(message)
        }
        do {
            return try await startup(post)
        } catch let error as DeviceLoopError where error.code == .deviceLocked || error.code == .uiAutomationPasscode {
            post(error.message)
            throw error
        }
    }

    /// Runs `attempt` again each time it fails with ui_automation_passcode, until `ownerWait` has passed since the first failure.
    static func retryingPasscode<Value>(
        _ target: Target, ownerWait: Duration, log: (String) -> Void, attempt: () async throws -> Value
    ) async throws -> Value {
        var deadline: ContinuousClock.Instant?
        while true {
            do {
                return try await attempt()
            } catch let error as DeviceLoopError where error.code == .uiAutomationPasscode {
                let end = deadline ?? .now + ownerWait
                deadline = end
                let left = ContinuousClock.now.duration(to: end)
                guard left > .zero else { throw error }
                log("No passcode was entered on \(target.name) in time. Starting the runner again, \(left.components.seconds) s left.")
            }
        }
    }

    /// The live runner's health, read from the session file without taking the session lock. Nil when none answers.
    static func liveHealth(_ target: Target) async -> HealthResult? {
        guard let file = SessionFile.read(for: target.udid), file.stopping != true else { return nil }
        return await probeHealth(file, at: file.host)
    }

    /// `automation.json` in the session folder. Its `enabledAt` is the time the last runner became ready.
    private static func automationRecord(for udid: String) -> URL {
        Paths.session(for: udid).appending(path: "automation.json")
    }

    static func automationEnabledAt(for udid: String) -> String? {
        guard let data = try? Data(contentsOf: automationRecord(for: udid)) else { return nil }
        return (try? JSONDecoder().decode([String: String].self, from: data))?["enabledAt"]
    }

    static func recordAutomationEnabled(for udid: String) throws {
        try Paths.ensureDirectory(Paths.session(for: udid))
        try JSONEncoder().encode(["enabledAt": DeviceState.timestamp()]).write(to: automationRecord(for: udid), options: .atomic)
    }

    /// A healthy session from the session file, or nil. Throws device_busy when the session lock stays held for `lockTimeout`.
    static func reattach(
        _ target: Target,
        lockTimeout: Duration = .seconds(120),
        probe: (SessionFile, String) async -> HealthResult? = probeHealth,
        exited: (SessionFile) -> Bool = runnerExited
    ) async throws -> RunnerSession? {
        let lock = try await SessionLock.acquire(for: target.udid, timeout: lockTimeout)
        defer { lock.release() }
        return try await reattachUnlocked(target, probe: probe, exited: exited)
    }

    /// `replace` stops a runner that another DeviceLoop version started, or that no longer answers after the device tunnel
    /// moved, and returns nil, so the caller starts a new one.
    private static func reattachUnlocked(
        _ target: Target,
        log: (String) -> Void = { _ in },
        replace: Bool = false,
        probe: (SessionFile, String) async -> HealthResult? = probeHealth,
        exited: (SessionFile) -> Bool = runnerExited
    ) async throws -> RunnerSession? {
        guard let (session, health) = try await authenticatedSession(target, log: log, replace: replace, probe: probe, exited: exited)
        else { return nil }
        if replace, health.version != RunnerWire.version || session.info.deviceLoopVersion != version {
            log("stopping the runner on \(target.name), another DeviceLoop version started it")
            try await session.stop()
            return nil
        }
        try validateHealth(health)
        return session
    }

    /// Stops the runner on `target`, whatever DeviceLoop version started it. Returns false when there is none.
    static func stopExisting(
        _ target: Target,
        load: (Target) async throws -> RunnerSession? = sessionForStop,
        shutdown: (RunnerSession) async throws -> Void = { try await $0.stop() }
    ) async throws -> Bool {
        let lock = try await SessionLock.acquire(for: target.udid)
        defer { lock.release() }
        guard let session = try await load(target) else { return false }
        try await shutdown(session)
        return true
    }

    /// Throws device_busy while a runner process is alive on `target`, or stops it when `stop` is set.
    /// The caller holds the session lock.
    static func requireNoRunner(_ target: Target, stop: Bool) async throws {
        guard let file = SessionFile.read(for: target.udid),
            RunnerProcess.state(of: file.pid, matching: file.processIdentity) != .exited
        else { return }
        guard stop else {
            throw DeviceLoopError(
                .deviceBusy, "The UI runner is running on \(target.name).",
                fix: "Stop it with deviceloop runner stop --device \(target.udid), or pass --stop-runner.", device: target.name
            )
        }
        if let session = try await sessionForStop(target) { try await session.stop() }
    }

    private static func authenticatedSession(
        _ target: Target,
        log: (String) -> Void,
        replace: Bool = false,
        probe: (SessionFile, String) async -> HealthResult?,
        exited: (SessionFile) -> Bool
    ) async throws -> (RunnerSession, HealthResult)? {
        guard var file = SessionFile.read(for: target.udid) else { return nil }
        if file.stopping == true {
            guard RunnerProcess.state(of: file.pid, matching: file.processIdentity) == .exited else {
                throw teardownIncomplete(target)
            }
            file.discard()
            return nil
        }
        let previous = file.host
        if let current = file.movedTunnel(on: target) {
            if let health = await probe(file, current), let epoch = health.sessionEpoch, epoch == file.sessionEpoch {
                file.host = current
                try file.write()
                log("reusing runner session \(epoch) at \(current), the device tunnel moved from \(previous)")
                return (session(target, file), health)
            }
            try Task.checkCancellation()
            // USB capture moves the tunnel of some devices, and their runner stops answering while xcodebuild lingers.
            if !exited(file), replace, await RunnerProcess.terminate(file.pid, matching: file.processIdentity) {
                log("stopped the runner at \(previous), which does not answer since the device tunnel moved to \(current)")
                file.discard()
                return nil
            }
            guard exited(file) else {
                throw DeviceLoopError(
                    .runnerUnreachable,
                    "The device tunnel moved from \(previous) to \(current) and this runner session does not answer at \(current), "
                        + "but its host process has not exited.",
                    fix: "Run runner stop for this target and wait for teardown before starting another runner.", device: target.name
                )
            }
            log("the runner at \(previous) exited after the device tunnel moved to \(current)")
            file.discard()
            return nil
        }
        let health = await probe(file, previous)
        guard let health, let epoch = health.sessionEpoch, epoch == file.sessionEpoch else {
            try Task.checkCancellation()
            guard exited(file) else {
                let message =
                    health == nil
                    ? "The existing runner is unreachable, but its host process has not exited."
                    : "Another runner session answers at \(file.host) port \(file.port), but this session's host process has not exited."
                throw DeviceLoopError(
                    .runnerUnreachable, message,
                    fix: "Run runner stop for this target and wait for teardown before starting another runner.", device: target.name
                )
            }
            file.discard()
            return nil
        }
        return (session(target, file), health)
    }

    private static func session(_ target: Target, _ file: SessionFile) -> RunnerSession {
        let client = RunnerClient(baseURL: .runner(host: file.host, port: file.port), token: file.token, epoch: file.sessionEpoch)
        return RunnerSession(target: target, client: client, info: file)
    }

    private static func probeHealth(_ file: SessionFile, at host: String) async -> HealthResult? {
        let client = RunnerClient(baseURL: .runner(host: host, port: file.port), token: file.token)
        return try? await client.get(RunnerWire.Path.health, as: HealthResult.self, timeout: 3)
    }

    /// Session files from before protocol 3 have no process identity, so an unreachable one counts as exited.
    private static func runnerExited(_ file: SessionFile) -> Bool {
        file.processIdentity == nil || RunnerProcess.state(of: file.pid, matching: file.processIdentity) == .exited
    }

    /// The session to stop, also when its HTTP server is gone and xcodebuild is still finishing its results. A server
    /// that answers with another session epoch counts as gone.
    private static func sessionForStop(_ target: Target) async throws -> RunnerSession? {
        guard let file = SessionFile.read(for: target.udid) else { return nil }
        let client = RunnerClient(baseURL: .runner(host: file.host, port: file.port), token: file.token, epoch: file.sessionEpoch)
        if let health = try? await client.get(RunnerWire.Path.health, as: HealthResult.self, timeout: 3),
            health.sessionEpoch == file.sessionEpoch
        {
            return RunnerSession(target: target, client: client, info: file)
        }
        try Task.checkCancellation()
        if file.processIdentity == nil, file.stopping != true {
            SessionFile.remove(for: target.udid)
            return nil
        }
        return RunnerSession(target: target, client: client, info: file)
    }

    /// Installs the host app when the runner build or provisioning profile it came from differs from the one installed last,
    /// recorded in `host.json`. xcodebuild test-without-building can leave an older host app installed after a rebuild.
    /// A device runner rebuilt for an expired profile or a new device keeps its build directory but embeds a new profile.
    static func installHostIfRebuilt(
        _ target: Target, products: URL, log: (String) -> Void,
        install: (Target, URL) async throws -> Void = { _ = try await AppCommands.install($0, path: $1) }
    ) async throws {
        let app = products.appending(path: "\(target.isSimulator ? "Debug-iphonesimulator" : "Debug-iphoneos")/DeviceLoopHost.app")
        guard FileManager.default.fileExists(atPath: app.path) else { return }
        var build = products.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        if let profile = try? Data(contentsOf: app.appending(path: "embedded.mobileprovision")) {
            build += "-" + RunnerBuild.digest(profile)
        }
        let record = Paths.session(for: target.udid).appending(path: "host.json")
        guard (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: record)))?["build"] != build else { return }
        log("installing the runner host app")
        try await install(target, app)
        try Paths.writePrivate(try JSONEncoder().encode(["build": build]), to: record)
    }

    private static func launch(_ target: Target, log: (String) -> Void, notify: (String) -> Void) async throws -> RunnerSession {
        if let marker = SuiteMarker.live(for: target.udid) { throw marker.busy(target) }
        if !target.isSimulator {
            try await requireUnlocked(target)
        }
        let products = try await RunnerBuild.products(for: target, log: log)
        try await installHostIfRebuilt(target, products: products, log: log)
        let token = try Self.randomToken()
        let bind = target.isSimulator ? "::1" : (target.tunnelAddress ?? "::1")
        let sessionDir = try Paths.ensureDirectory(Paths.session(for: target.udid))
        let xctestrun = try RunnerBuild.writeServeXctestrun(from: products, token: token, bind: bind)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: xctestrun) } }
        let attemptDir = try Paths.ensureDirectory(sessionDir.appending(path: "startup-\(UUID().uuidString)"))
        let logURL = attemptDir.appending(path: "xcodebuild.log")
        let resultBundle = attemptDir.appending(path: "result.xcresult")

        log("starting runner on \(target.summary)")
        log("runner log: \(logURL.path)")
        try Task.checkCancellation()
        // The runner is detached from the CLI. Ctrl-C or SIGTERM during startup cancels and stops it.
        let interrupt = InterruptFlag()
        defer { interrupt.remove() }
        let pid = try Shell.spawnDetached(
            [
                "xcodebuild", "test-without-building",
                "-xctestrun", xctestrun.path,
                "-destination", "id=\(target.udid)",
                "-resultBundlePath", resultBundle.path,
            ],
            log: logURL
        )

        let session = try await completeStartup(pid: pid) {
            guard let identity = RunnerProcess.identity(of: pid) else {
                throw DeviceLoopError(.runnerBuildFailed, "Could not identify the runner host process.", fix: "See \(logURL.path).")
            }
            let port = try await waitForReady(logURL: logURL, pid: pid, target: target, interrupt: interrupt, log: log, notify: notify)
            var client = RunnerClient(baseURL: .runner(host: bind, port: port), token: token)
            let health: HealthResult
            do {
                health = try await client.get(RunnerWire.Path.health, as: HealthResult.self, timeout: 5)
            } catch {
                try Task.checkCancellation()
                throw DeviceLoopError(
                    .runnerUnreachable, "Runner started but did not answer on \(bind):\(port).", fix: "See \(logURL.path).",
                    device: target.name)
            }
            try validateHealth(health)
            try Task.checkCancellation()
            if interrupt.isRaised { throw CancellationError() }
            let file = SessionFile(
                udid: target.udid, host: bind, port: port, token: token, pid: pid, xctestrunPath: xctestrun.path,
                processIdentity: identity, sessionEpoch: health.sessionEpoch, deviceLoopVersion: version, runnerLog: logURL.path
            )
            try file.write()
            try? recordAutomationEnabled(for: target.udid)
            client.epoch = health.sessionEpoch
            return RunnerSession(target: target, client: client, info: file)
        }
        published = true
        return session
    }

    /// Throws runner_build_failed when `health` names another protocol version or no valid session epoch.
    static func validateHealth(_ health: HealthResult) throws {
        guard health.version == RunnerWire.version else {
            throw DeviceLoopError(
                .runnerBuildFailed,
                "Runner protocol \(health.version) is incompatible with client protocol \(RunnerWire.version).",
                fix: "Stop the existing runner and rebuild it with this version of DeviceLoop."
            )
        }
        guard let epoch = health.sessionEpoch, UUID(uuidString: epoch) != nil else {
            throw DeviceLoopError(
                .runnerBuildFailed, "The runner did not provide a valid session epoch.",
                fix: "Stop the existing runner and rebuild it with this version of DeviceLoop."
            )
        }
    }

    /// Runs `operation`, and calls `cleanup` with `pid` when it throws. The startup log and result bundle stay.
    static func completeStartup<Value>(
        pid: pid_t,
        cleanup: (pid_t) async -> Void = terminateOwnedProcess,
        operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch {
            await cleanup(pid)
            throw error
        }
    }

    /// Only signals a child spawned by this process. An exited child is reaped before its PID can be reused.
    private static func terminateOwnedProcess(_ pid: pid_t) async {
        guard pid > 0, waitpid(pid, nil, WNOHANG) == 0 else { return }
        for signal in [SIGTERM, SIGKILL] {
            kill(pid, signal)
            for _ in 0 ..< 20 {
                if waitpid(pid, nil, WNOHANG) != 0 { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stop() async throws {
        try await Self.finishStop(info) {
            _ = try await client.post(RunnerWire.Path.shutdown, WireEmpty(), as: WireEmpty.self, timeout: 3)
        }
    }

    static func finishStop(
        _ info: SessionFile, timeout: Duration = .seconds(45), request: () async throws -> Void
    ) async throws {
        var stopping = info
        stopping.stopping = true
        try stopping.write()
        try await Self.completeShutdown(
            pid: info.pid, identity: info.processIdentity, timeout: timeout,
            onRejected: { try info.write() }, request: request
        )
        info.discard()
    }

    /// Sends the shutdown `request`, then waits up to `timeout` for the runner process to exit without signaling it.
    static func completeShutdown(
        pid: pid_t, identity: RunnerProcessIdentity?, timeout: Duration = .seconds(45),
        onRejected: () throws -> Void = {},
        request: () async throws -> Void
    ) async throws {
        do {
            try await request()
        } catch let error as DeviceLoopError where [.deviceBusy, .dispatchExpired, .sessionMismatch].contains(error.code) {
            try onRejected()
            throw error
        } catch {
            // A lost response may follow an executed shutdown, so only the process exit counts.
        }
        try Task.checkCancellation()
        guard try await RunnerProcess.waitForExit(pid, matching: identity, timeout: timeout) else {
            throw DeviceLoopError(
                .deviceBusy, "Runner shutdown has not finished. Its session is retained until the host process exits.",
                fix: "Wait for XCTest teardown, then run runner stop again. Inspect the runner log if it remains stuck."
            )
        }
    }

    static func teardownIncomplete(_ target: Target) -> DeviceLoopError {
        DeviceLoopError(
            .deviceBusy, "Runner shutdown is still pending on \(target.name).",
            fix: "Wait for XCTest teardown, then run runner stop again. A new runner will not start over pending teardown.",
            device: target.name
        )
    }

    func health() async throws -> HealthResult {
        try await client.get(RunnerWire.Path.health, as: HealthResult.self, timeout: 5)
    }

    /// Reads the detached log until the runner prints its ready line, mapping the passcode prompt.
    static func waitForReady(
        logURL: URL, pid: pid_t, target: Target, interrupt: InterruptFlag, log: (String) -> Void, notify: (String) -> Void
    ) async throws -> UInt16 {
        var deadline = Date().addingTimeInterval(target.isSimulator ? 45 : 90)
        var warnedPasscode = false
        var runningTestsSince: Date?
        var text = ""
        while Date() < deadline {
            try Task.checkCancellation()
            if interrupt.isRaised { throw CancellationError() }
            text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if RunnerProcess.childHasExited(pid) {
                throw exitFailure(in: (try? String(contentsOf: logURL, encoding: .utf8)) ?? text, target: target, logURL: logURL)
            }
            if let port = readyPort(in: text) { return port }
            if let failure = startupFailure(in: text, target: target) { throw failure }
            if !target.isSimulator, runningTestsSince == nil, text.contains(uiTestsStarted) {
                runningTestsSince = Date()
                // XCTest gives up 60 s after its prompt and logs the timeout.
                deadline = max(deadline, Date().addingTimeInterval(75))
            }
            // Treats Running tests without a ready line after 3 s as the passcode prompt.
            if !warnedPasscode, let since = runningTestsSince, Date().timeIntervalSince(since) >= 3 {
                warnedPasscode = true
                let prompt = passcodeHint(target)
                log(prompt)
                notify(prompt)
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        throw deadlineFailure(in: text, target: target, logURL: logURL)
    }

    /// The failure a startup log shows before the deadline, or nil while the runner may still become ready.
    static func startupFailure(in log: String, target: Target) -> DeviceLoopError? {
        if log.contains(passcodeTimedOut) { return passcodeError(target) }
        if log.contains("Root install style is not supported") {
            return DeviceLoopError(
                .runnerInstallFailed, "The runner could not be installed on \(target.name).",
                detail: "Report it with the folder from deviceloop doctor --export <folder>.", device: target.name)
        }
        if let line = log.split(separator: "\n").first(where: { $0.contains("0xe8008015") }) {
            return DeviceLoopError(
                .signingProfileFailed,
                "\(target.name) rejected the runner's provisioning profile, which is expired, revoked or out of date.",
                fix: "Remove \(Paths.runnerBuilds.path) so the runner is built and signed again, then retry.",
                detail: line.trimmingCharacters(in: .whitespaces), device: target.name)
        }
        return nil
    }

    /// The failure for a runner whose xcodebuild exited before it was ready.
    static func exitFailure(in log: String, target: Target, logURL: URL) -> DeviceLoopError {
        startupFailure(in: log, target: target)
            ?? DeviceLoopError(
                .runnerBuildFailed, "The runner exited before it was ready.", fix: "See \(logURL.path).", device: target.name)
    }

    /// A device whose log reached `Running tests` is waiting for its passcode. Any other startup is unreachable.
    static func deadlineFailure(in log: String, target: Target, logURL: URL) -> DeviceLoopError {
        if !target.isSimulator, log.contains(uiTestsStarted) { return passcodeError(target) }
        return DeviceLoopError(
            .runnerUnreachable, "The runner did not become ready on \(target.name).", fix: "See \(logURL.path).", device: target.name)
    }

    private static func readyPort(in log: String) -> UInt16? {
        for line in log.split(separator: "\n") where line.contains(RunnerWire.readyPrefix) {
            for field in line.split(separator: " ") where field.hasPrefix("port=") {
                return UInt16(field.dropFirst("port=".count))
            }
        }
        return nil
    }

    /// Logged by a UI test runner app when its tests start.
    static let uiTestsStarted = "Running tests"
    /// Logged by xcodebuild when nobody entered the passcode to allow UI Automation.
    static let passcodeTimedOut = "Timed out while enabling automation mode"

    static func passcodeHint(_ target: Target) -> String {
        "Unlock \(target.name) and enter its passcode to allow UI Automation (up to 60 s)."
    }

    static func passcodeError(_ target: Target) -> DeviceLoopError {
        DeviceLoopError(
            .uiAutomationPasscode,
            "\(target.name) is waiting for its passcode to allow UI Automation.",
            fix: "Unlock \(target.name) and enter its passcode, then run the command again. A device with no passcode does not prompt.",
            device: target.name
        )
    }

    static func requireUnlocked(_ target: Target) async throws {
        guard target.supports(Capability.lockState) else { return }
        guard let state = try? await Devicectl.run(Devicectl.device(target, "info", "lockState"), target: target, timeout: .seconds(15))
        else { return }
        if state["passcodeRequired"]?.bool == true {
            throw DeviceLoopError(
                .deviceLocked, "\(target.name) is locked.", fix: "Unlock \(target.name), then run the command again.", device: target.name)
        }
    }

    static func randomToken(
        fill: (inout [UInt8]) -> OSStatus = { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        }
    ) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = fill(&bytes)
        guard status == errSecSuccess else {
            throw DeviceLoopError(.internalError, "Could not generate a secure runner token.", detail: "Security status \(status).")
        }
        return Data(bytes).base64EncodedString()
    }
}

/// The 0600 file that lets any DeviceLoop process reattach to a running runner.
struct SessionFile: Codable, Sendable {
    var udid: String
    var host: String
    var port: UInt16
    var token: String
    var pid: pid_t
    var xctestrunPath: String? = nil
    var processIdentity: RunnerProcessIdentity? = nil
    var sessionEpoch: String? = nil
    var stopping: Bool? = nil
    /// The DeviceLoop version that started the runner.
    var deviceLoopVersion: String? = nil
    /// The xcodebuild log of the startup attempt that launched this runner.
    var runnerLog: String? = nil

    /// The device's current tunnel address when it differs from `host`, or nil.
    func movedTunnel(on target: Target) -> String? {
        guard !target.isSimulator, let current = target.tunnelAddress, current != host else { return nil }
        return current
    }

    /// Deletes only generated credential files in the expected runner cache layout.
    @discardableResult
    func removeCredentials(in builds: URL = Paths.runnerBuilds) -> Bool {
        guard let xctestrunPath else { return false }
        let root = builds.standardizedFileURL
        let file = URL(filePath: xctestrunPath).standardizedFileURL
        let prefix = root.path + "/"
        guard file.path.hasPrefix(prefix) else { return false }
        let components = file.path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard components.count == 4, components[1] == "Build", components[2] == "Products" else { return false }
        let key = components[0]
        let digest = key.hasPrefix("sim-") ? String(key.dropFirst(4)) : key.hasPrefix("device-") ? String(key.dropFirst(7)) : ""
        guard digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else { return false }
        let name = components[3]
        guard name.hasPrefix("run-"), name.hasSuffix(".xctestrun"),
            UUID(uuidString: String(name.dropFirst(4).dropLast(".xctestrun".count))) != nil
        else { return false }

        var directory = open(root.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { return false }
        defer { close(directory) }
        for component in components.prefix(3) {
            let child = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard child >= 0 else { return false }
            close(directory)
            directory = child
        }
        var metadata = stat()
        guard fstatat(directory, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
            metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid()
        else { return false }
        return unlinkat(directory, name, 0) == 0
    }

    static func url(for udid: String) -> URL {
        Paths.session(for: udid).appending(path: "session.json")
    }

    static func read(for udid: String) -> SessionFile? {
        guard let data = try? Data(contentsOf: url(for: udid)) else { return nil }
        return try? JSONDecoder().decode(SessionFile.self, from: data)
    }

    static func remove(for udid: String) {
        try? FileManager.default.removeItem(at: url(for: udid))
    }

    /// Removes the generated xctestrun and this session file.
    func discard() {
        removeCredentials()
        Self.remove(for: udid)
    }

    func write(to destination: URL? = nil) throws {
        let url = destination ?? Self.url(for: udid)
        do {
            try Paths.writePrivate(try JSONEncoder().encode(self), to: url)
        } catch {
            throw DeviceLoopError(
                .internalError,
                "Could not save the runner session.",
                fix: "Check write permissions at \(url.deletingLastPathComponent().path).",
                detail: error.localizedDescription
            )
        }
    }
}
