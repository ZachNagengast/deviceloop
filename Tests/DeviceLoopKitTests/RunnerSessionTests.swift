//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Security
import Testing

@testable import DeviceLoopKit

@Suite struct RunnerSessionTests {
    private func health(version: Int = RunnerWire.version, epoch: String = UUID().uuidString) -> HealthResult {
        HealthResult(version: version, runnerBuild: "test", os: "test", uptimeS: 0, busy: false, queue: 0, sessionEpoch: epoch)
    }

    /// A target with a new UDID.
    private func testTarget(_ kind: Target.Kind = .simulator, tunnel: String? = nil) -> Target {
        let udid = "unit-test-\(UUID().uuidString)"
        return Target(
            udid: udid, identifier: udid, name: "Unit test", kind: kind, deviceType: "iPhone", platform: "iOS", model: "fixture",
            productType: "fixture", osVersion: "test", connectionState: "connected", tunnelAddress: tunnel
        )
    }

    @Test func acceptsCurrentProtocol() throws {
        try RunnerSession.validateHealth(health(version: RunnerWire.version))
    }

    @Test func rejectsMissingEpochEvenWithCurrentProtocol() {
        var response = health(version: RunnerWire.version)
        response.sessionEpoch = nil
        #expect(throws: DeviceLoopError.self) { try RunnerSession.validateHealth(response) }
    }

    @Test(arguments: [-1, 1]) func rejectsDifferentProtocol(offset: Int) {
        #expect(throws: DeviceLoopError.self) {
            try RunnerSession.validateHealth(health(version: RunnerWire.version + offset))
        }
    }

    @Test func sessionFileWithoutRunnerLogStillDecodes() throws {
        let json = #"{"udid":"unit-test","host":"::1","port":1234,"token":"test-only","pid":1}"#
        let file = try JSONDecoder().decode(SessionFile.self, from: Data(json.utf8))
        #expect(file.runnerLog == nil)
    }

    private func testSession() -> RunnerSession {
        let target = testTarget()
        let file = SessionFile(udid: target.udid, host: "::1", port: 1234, token: "test-only", pid: 0)
        let client = RunnerClient(baseURL: .runner(host: file.host, port: file.port), token: file.token)
        return RunnerSession(target: target, client: client, info: file)
    }

    @Test func explicitStopShutsDownTheLoadedSession() async throws {
        let session = testSession()
        defer { try? FileManager.default.removeItem(at: Paths.session(for: session.target.udid)) }
        var stopped = false
        let result = try await RunnerSession.stopExisting(
            session.target,
            load: { _ in session },
            shutdown: { received in
                #expect(received.info.token == session.info.token)
                stopped = true
            }
        )
        #expect(result)
        #expect(stopped)
    }

    @Test func explicitStopWithNoLoadedSessionDoesNotShutDown() async throws {
        let session = testSession()
        defer { try? FileManager.default.removeItem(at: Paths.session(for: session.target.udid)) }
        var stopped = false
        let result = try await RunnerSession.stopExisting(
            session.target,
            load: { _ in nil },
            shutdown: { _ in stopped = true }
        )
        #expect(!result)
        #expect(!stopped)
    }

    @Test func stopWithoutARunnerReportsStoppedFalse() async throws {
        let target = testTarget()
        defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
        #expect(try await RunnerCommands.stop(target).json == ["stopped": false])
    }

    @Test func sleepStepReportsSleptMs() async throws {
        #expect(try await UICommands.perform(.sleep(ms: 0), on: testSession().target, app: nil).json == ["sleptMs": 0])
    }

    private func validationCode(_ step: UIStep) -> DeviceLoopError.Code? {
        do {
            try step.validate()
            return nil
        } catch {
            return (error as? DeviceLoopError)?.code ?? .internalError
        }
    }

    private let pointTarget = ElementTarget(point: WirePoint(x: 100, y: 100))

    @Test func tapCountOtherThanOneOrTwoIsBadArguments() {
        for count in [0, 3, -1] {
            #expect(validationCode(.tap(pointTarget, count: count)) == .badArguments)
        }
    }

    @Test func holdOutsideOneTo10000MsIsBadArguments() {
        for holdMs in [0, -1, 10_001] {
            #expect(validationCode(.tap(pointTarget, holdMs: holdMs)) == .badArguments)
            #expect(validationCode(.drag(from: WirePoint(x: 10, y: 10), to: WirePoint(x: 20, y: 20), holdMs: holdMs)) == .badArguments)
        }
    }

    @Test func velocityThatIsNotPositiveAndFiniteIsBadArguments() {
        for velocity in [-100, 0, .nan, .infinity] {
            #expect(validationCode(.swipe(direction: "left", velocity: velocity)) == .badArguments)
            #expect(validationCode(.drag(from: WirePoint(x: 10, y: 10), to: WirePoint(x: 20, y: 20), velocity: velocity)) == .badArguments)
        }
    }

    @Test func nonfinitePointsAreBadArguments() {
        #expect(validationCode(.tap(ElementTarget(point: WirePoint(x: .nan, y: 10)))) == .badArguments)
        #expect(validationCode(.drag(from: WirePoint(x: 10, y: 10), to: WirePoint(x: 20, y: .infinity))) == .badArguments)
    }

    @Test func unknownSwipeDirectionIsBadArguments() {
        #expect(validationCode(.swipe(direction: "sideways")) == .badArguments)
        for direction in UIStep.swipeDirections {
            #expect(validationCode(.swipe(direction: direction)) == nil)
        }
    }

    @Test func unknownButtonIsBadArguments() {
        #expect(validationCode(.press(button: "back")) == .badArguments)
        for button in UIStep.buttons {
            #expect(validationCode(.press(button: button)) == nil)
        }
    }

    @Test func performRejectsAnInvalidStepBeforeConnecting() async {
        var target = testSession().target
        target.platform = "tvOS"
        await #expect(throws: DeviceLoopError(.badArguments, "Tap count must be 1 or 2, not 3.")) {
            try await UICommands.perform(.tap(pointTarget, count: 3), on: target, app: nil)
        }
    }

    @Test func refAsTheTreePrintsItNeedsNoAt() throws {
        #expect(try UIStep.parse("tap e5457f2fb.1.42") == .tap(ElementTarget(ref: "e5457f2fb.1.42")))
        #expect(try UIStep.parse("tap @e5457f2fb.1.42") == .tap(ElementTarget(ref: "e5457f2fb.1.42")))
        #expect(try UIStep.parse("tap e5") == .tap(ElementTarget(query: ElementQuery(label: "e5"))))
    }

    @Test func holdStepWithNonNumericMillisecondsIsBadArguments() {
        #expect(throws: DeviceLoopError.usage("hold needs milliseconds, for example: hold @e5 800")) {
            try UIStep.parse("hold @e5 abc")
        }
    }

    @Test func gestureArgumentsAtTheirLimitsAreAccepted() {
        #expect(validationCode(.tap(pointTarget, count: 2)) == nil)
        #expect(validationCode(.tap(pointTarget, holdMs: 1)) == nil)
        #expect(validationCode(.tap(pointTarget, holdMs: 10_000)) == nil)
        #expect(validationCode(.swipe(direction: "up", velocity: 0.5)) == nil)
        #expect(validationCode(.drag(from: WirePoint(x: -5, y: 10), to: WirePoint(x: 20, y: 20), velocity: 1, holdMs: 10_000)) == nil)
    }

    @Test func startupSuccessKeepsOwnedProcess() async throws {
        var cleaned: [pid_t] = []
        let result = try await RunnerSession.completeStartup(pid: 123, cleanup: { cleaned.append($0) }, operation: { "ready" })
        #expect(result == "ready")
        #expect(cleaned.isEmpty)
    }

    @Test(arguments: [DeviceLoopError.Code.runnerBuildFailed, .runnerUnreachable, .internalError, .uiAutomationPasscode])
    func startupFailureCleansOwnedProcessAndPreservesError(code: DeviceLoopError.Code) async {
        var cleaned: [pid_t] = []
        let failure = DeviceLoopError(code, "Injected startup failure")
        do {
            let _: Void = try await RunnerSession.completeStartup(pid: 123, cleanup: { cleaned.append($0) }, operation: { throw failure })
            Issue.record("Startup unexpectedly succeeded")
        } catch {
            #expect(error as? DeviceLoopError == failure)
        }
        #expect(cleaned == [123])
    }

    @Test func startupCancellationCleansOwnedProcess() async {
        var cleaned: [pid_t] = []
        do {
            let _: Void = try await RunnerSession.completeStartup(
                pid: 456, cleanup: { cleaned.append($0) }, operation: { throw CancellationError() })
            Issue.record("Startup unexpectedly succeeded")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(cleaned == [456])
    }

    /// Waits for a runner log written by `script` and returns the notifications.
    private func startupNotifications(_ kind: Target.Kind, script: String) async throws -> [String] {
        let log = FileManager.default.temporaryDirectory.appending(path: "deviceloop-startup-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let pid = try Shell.spawnDetached(["sh", "-c", script + "; exec sleep 10"], log: log)
        defer {
            var status: Int32 = 0
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
        let interrupt = InterruptFlag()
        defer { interrupt.remove() }
        let target = testTarget(kind)
        var posted: [String] = []
        _ = try? await RunnerSession.notifyingPerson(
            target, notify: { posted.append($0) },
            startup: { post in
                try await RunnerSession.waitForReady(
                    logURL: log, pid: pid, target: target, interrupt: interrupt, log: { _ in }, notify: post)
            })
        return posted
    }

    private let passcodeTimeoutLog = "echo Running tests; sleep 8; echo Timed out while enabling automation mode"

    @Test func devicePasscodePromptNotifiesOncePerStartup() async throws {
        let posted = try await startupNotifications(.device, script: passcodeTimeoutLog)
        #expect(posted == ["Unlock Unit test and enter its passcode to allow UI Automation (up to 60 s)."])
    }

    @Test func simulatorStartupDoesNotNotify() async throws {
        #expect(try await startupNotifications(.simulator, script: passcodeTimeoutLog).isEmpty)
    }

    @Test func deviceReadySoonAfterRunningTestsDoesNotNotify() async throws {
        let script = "echo Running tests; sleep 1.5; echo \(RunnerWire.readyPrefix) port=4321"
        #expect(try await startupNotifications(.device, script: script).isEmpty)
    }

    @Test func lockedDeviceStartupNotifies() async {
        var posted: [String] = []
        do {
            let _: Void = try await RunnerSession.notifyingPerson(
                testTarget(.device), notify: { posted.append($0) },
                startup: { _ in throw DeviceLoopError(.deviceLocked, "Unit test is locked.") })
            Issue.record("Startup unexpectedly succeeded")
        } catch {
            #expect((error as? DeviceLoopError)?.code == .deviceLocked)
        }
        #expect(posted == ["Unit test is locked."])
    }

    @Test func automationTimeoutInTheStartupLogIsAPasscodeWait() {
        let log = "Running tests...\nTimed out while enabling automation mode.\n"
        #expect(RunnerSession.startupFailure(in: log, target: testTarget(.device))?.code == .uiAutomationPasscode)
        #expect(RunnerSession.startupFailure(in: "Running tests...\n", target: testTarget(.device)) == nil)
    }

    @Test func deviceStartupThatNeverRanTestsIsUnreachable() {
        let logURL = URL(filePath: "/tmp/startup/xcodebuild.log")
        let failure = RunnerSession.deadlineFailure(in: "Testing started\n", target: testTarget(.device), logURL: logURL)
        #expect(failure.code == .runnerUnreachable)
        #expect(failure.fix == "See /tmp/startup/xcodebuild.log.")
    }

    /// An install rejected with 0xe8008015, in the shape Apple Developer Forums thread 792425 shows. Not a captured log.
    private let profileLog = """
        Testing failed:
        \tUnable to Install "DeviceLoopHost" Domain: IXUserPresentableErrorDomain Code: 14 Failure Reason: This app cannot be \
        installed because its integrity could not be verified. Recovery Suggestion: Failed to verify code signature of \
        /var/installd/Library/Caches/com.apple.mobile.installd.staging/temp.HXa0sV/extracted/DeviceLoopHost.app : 0xe8008015 \
        (A valid provisioning profile for this executable was not found.)
        ** TEST EXECUTE FAILED **

        """

    @Test func installRejectedForItsProfileIsASigningProfileFailure() throws {
        let error = try #require(RunnerSession.startupFailure(in: profileLog, target: testTarget(.device)))
        #expect(error.code == .signingProfileFailed)
        #expect(error.message == "Unit test rejected the runner's provisioning profile, which is expired, revoked or out of date.")
        #expect(error.fix == "Remove \(Paths.runnerBuilds.path) so the runner is built and signed again, then retry.")
        #expect(error.detail?.hasSuffix("0xe8008015 (A valid provisioning profile for this executable was not found.)") == true)
    }

    @Test func runnerThatExitsAfterAProfileRejectionReportsIt() {
        let logURL = URL(filePath: "/tmp/startup/xcodebuild.log")
        let error = RunnerSession.exitFailure(in: profileLog, target: testTarget(.device), logURL: logURL)
        #expect(error.code == .signingProfileFailed)
    }

    @Test func passcodeTimeoutStartsTheRunnerAgainWithinTheOwnerWait() async throws {
        var attempts = 0
        var lines: [String] = []
        let result = try await RunnerSession.retryingPasscode(
            testTarget(.device), ownerWait: .seconds(60), log: { lines.append($0) },
            attempt: {
                attempts += 1
                if attempts == 1 { throw DeviceLoopError(.uiAutomationPasscode, "waiting for the passcode") }
                return "ready"
            })
        #expect(result == "ready")
        #expect(attempts == 2)
        #expect(lines.count == 1)
    }

    @Test func passcodeTimeoutAfterTheOwnerWaitIsNotRetried() async {
        var attempts = 0
        await #expect(throws: DeviceLoopError(.uiAutomationPasscode, "waiting for the passcode")) {
            try await RunnerSession.retryingPasscode(
                self.testTarget(.device), ownerWait: .zero, log: { _ in },
                attempt: {
                    attempts += 1
                    throw DeviceLoopError(.uiAutomationPasscode, "waiting for the passcode")
                })
        }
        #expect(attempts == 1)
    }

    @Test func unreachableStartupIsNotRetried() async {
        var attempts = 0
        await #expect(throws: DeviceLoopError(.runnerUnreachable, "not ready")) {
            try await RunnerSession.retryingPasscode(
                self.testTarget(.device), ownerWait: .seconds(60), log: { _ in },
                attempt: {
                    attempts += 1
                    throw DeviceLoopError(.runnerUnreachable, "not ready")
                })
        }
        #expect(attempts == 1)
    }

    @Test func entropyFailureDoesNotReturnToken() {
        #expect(throws: DeviceLoopError.self) {
            _ = try RunnerSession.randomToken(fill: { _ in errSecNotAvailable })
        }
    }

    @Test func secureTokenContainsAllGeneratedBytes() throws {
        let token = try RunnerSession.randomToken(fill: { bytes in
            bytes = Array(0 ..< 32)
            return errSecSuccess
        })
        #expect(Data(base64Encoded: token) == Data(0 ..< 32))
    }

    @Test func movedTunnelWithTheSameEpochReusesTheSessionAtTheNewAddress() async throws {
        let target = testTarget(.device, tunnel: "fd00::2")
        defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
        let epoch = UUID().uuidString
        try SessionFile(udid: target.udid, host: "fd00::1", port: 1234, token: "test-only", pid: 0, sessionEpoch: epoch).write()
        var probed: [String] = []
        let session = try await RunnerSession.reattach(
            target,
            probe: { _, host in
                probed.append(host)
                return host == "fd00::2" ? health(epoch: epoch) : nil
            },
            exited: { _ in
                Issue.record("Checked the host process of a runner that answered")
                return false
            }
        )
        #expect(probed == ["fd00::2"])
        #expect(session?.info.host == "fd00::2")
        #expect(session?.client.epoch == epoch)
        #expect(SessionFile.read(for: target.udid)?.host == "fd00::2")
    }

    @Test func movedTunnelWithADifferentEpochIsNotReused() async throws {
        let target = testTarget(.device, tunnel: "fd00::2")
        defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
        try SessionFile(udid: target.udid, host: "fd00::1", port: 1234, token: "test-only", pid: 0, sessionEpoch: UUID().uuidString).write()
        do {
            _ = try await RunnerSession.reattach(target, probe: { _, _ in health() }, exited: { _ in false })
            Issue.record("A runner with another session epoch was reused")
        } catch {
            #expect((error as? DeviceLoopError)?.code == .runnerUnreachable)
        }
        #expect(SessionFile.read(for: target.udid)?.host == "fd00::1")
    }

    @Test func movedTunnelWithAnExitedRunnerDiscardsTheSessionForALaunch() async throws {
        let target = testTarget(.device, tunnel: "fd00::2")
        defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
        try SessionFile(udid: target.udid, host: "fd00::1", port: 1234, token: "test-only", pid: 0, sessionEpoch: UUID().uuidString).write()
        var probed: [String] = []
        let session = try await RunnerSession.reattach(
            target,
            probe: { _, host in
                probed.append(host)
                return nil
            },
            exited: { _ in true }
        )
        #expect(session == nil)
        #expect(probed == ["fd00::2"])
        #expect(SessionFile.read(for: target.udid) == nil)
    }

    @Test func unchangedTunnelProbesOnlyTheStoredHost() async throws {
        let target = testTarget(.device, tunnel: "fd00::1")
        defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
        let epoch = UUID().uuidString
        try SessionFile(udid: target.udid, host: "fd00::1", port: 1234, token: "test-only", pid: 0, sessionEpoch: epoch).write()
        var probed: [String] = []
        let session = try await RunnerSession.reattach(
            target,
            probe: { _, host in
                probed.append(host)
                return health(epoch: epoch)
            }
        )
        #expect(probed == ["fd00::1"])
        #expect(session?.info.host == "fd00::1")
    }

    @Test func unchangedHostAnsweringWithADifferentEpochIsNotReused() async throws {
        let target = testTarget()
        defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
        try SessionFile(udid: target.udid, host: "::1", port: 1234, token: "test-only", pid: 0, sessionEpoch: UUID().uuidString).write()
        do {
            _ = try await RunnerSession.reattach(target, probe: { _, _ in health() }, exited: { _ in false })
            Issue.record("A server with another session epoch was reused")
        } catch {
            #expect((error as? DeviceLoopError)?.code == .runnerUnreachable)
        }
        #expect(SessionFile.read(for: target.udid) != nil)
    }

    @Test func unchangedHostAnsweringWithADifferentEpochAfterTheRunnerExitedDiscardsTheSession() async throws {
        let target = testTarget()
        defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
        try SessionFile(udid: target.udid, host: "::1", port: 1234, token: "test-only", pid: 0, sessionEpoch: UUID().uuidString).write()
        let session = try await RunnerSession.reattach(target, probe: { _, _ in health() }, exited: { _ in true })
        #expect(session == nil)
        #expect(SessionFile.read(for: target.udid) == nil)
    }

    /// Stops `target` with its session file pointing at a server that answers health with `answeredEpoch`, and counts shutdowns.
    private func stop(_ target: Target, storedEpoch: String, answeredEpoch: String) async throws -> (stopped: Bool, shutdowns: Int) {
        let reply = try JSONEncoder().encode(WireResponse(ok: true, result: health(epoch: answeredEpoch)))
        let server = try #require(LoopbackServer(answering: String(decoding: reply, as: UTF8.self)))
        defer { server.stop() }
        try SessionFile(udid: target.udid, host: "::1", port: server.port, token: "test-only", pid: 0, sessionEpoch: storedEpoch).write()
        var shutdowns = 0
        let stopped = try await RunnerSession.stopExisting(target, shutdown: { _ in shutdowns += 1 })
        return (stopped, shutdowns)
    }

    @Test func stopShutsDownTheRunnerWithTheRecordedEpoch() async throws {
        let target = testTarget()
        defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
        let epoch = UUID().uuidString
        #expect(try await stop(target, storedEpoch: epoch, answeredEpoch: epoch) == (true, 1))
    }

    @Test func stopDiscardsALegacySessionFileWhenAnotherEpochAnswers() async throws {
        let target = testTarget()
        defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
        #expect(try await stop(target, storedEpoch: UUID().uuidString, answeredEpoch: UUID().uuidString) == (false, 0))
        #expect(SessionFile.read(for: target.udid) == nil)
    }

    @Test func hostAppIsReinstalledWhenARebuildInPlaceEmbedsANewProfile() async throws {
        let target = testTarget(.device, tunnel: "fd00::1")
        let directory = FileManager.default.temporaryDirectory.appending(path: "deviceloop-host-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: Paths.session(for: target.udid))
        }
        let products = directory.appending(path: "device-key/Build/Products")
        let app = products.appending(path: "Debug-iphoneos/DeviceLoopHost.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        var installs = 0
        func installIfRebuilt() async throws {
            try await RunnerSession.installHostIfRebuilt(target, products: products, log: { _ in }, install: { _, _ in installs += 1 })
        }
        try Data("expired profile".utf8).write(to: app.appending(path: "embedded.mobileprovision"))
        try await installIfRebuilt()
        try await installIfRebuilt()
        #expect(installs == 1)
        try Data("renewed profile".utf8).write(to: app.appending(path: "embedded.mobileprovision"))
        try await installIfRebuilt()
        #expect(installs == 2)
    }

    /// Runs `body` with a device target and a folder for its runner builds, then removes both.
    private func withRunnerBuilds(_ body: (Target, URL) async throws -> Void) async throws {
        let target = testTarget(.device, tunnel: "fd00::1")
        let directory = Paths.home.appending(path: "host-tests/\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: Paths.session(for: target.udid))
        }
        try await body(target, directory)
    }

    /// Runs installHostIfRebuilt on the products of `build` in `directory`, creating its host app when `hostApp` is set.
    private func installHost(
        _ target: Target, in directory: URL, build: String, hostApp: Bool = true, install: (Target, URL) async throws -> Void
    ) async throws {
        let products = directory.appending(path: "\(build)/Build/Products")
        try Paths.ensureDirectory(hostApp ? products.appending(path: "Debug-iphoneos/DeviceLoopHost.app") : products)
        try await RunnerSession.installHostIfRebuilt(target, products: products, log: { _ in }, install: install)
    }

    @Test func hostAppIsReinstalledForANewRunnerBuild() async throws {
        try await withRunnerBuilds { target, directory in
            var installs = 0
            for build in ["build-a", "build-a", "build-b"] {
                try await installHost(target, in: directory, build: build) { _, _ in installs += 1 }
            }
            #expect(installs == 2)
        }
    }

    @Test func runnerBuildWithoutAHostAppInstallsNothing() async throws {
        try await withRunnerBuilds { target, directory in
            var installs = 0
            try await installHost(target, in: directory, build: "build-a", hostApp: false) { _, _ in installs += 1 }
            #expect(installs == 0)
            #expect(!FileManager.default.fileExists(atPath: Paths.session(for: target.udid).appending(path: "host.json").path))
        }
    }

    @Test func failedHostInstallIsNotRecordedAndIsRetried() async throws {
        try await withRunnerBuilds { target, directory in
            await #expect(throws: URLError.self) {
                try await installHost(target, in: directory, build: "build-a") { _, _ in throw URLError(.cannotWriteToFile) }
            }
            #expect(!FileManager.default.fileExists(atPath: Paths.session(for: target.udid).appending(path: "host.json").path))
            var installs = 0
            try await installHost(target, in: directory, build: "build-a") { _, _ in installs += 1 }
            #expect(installs == 1)
        }
    }

    @Test func sessionPersistenceIsPrivateAndRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "deviceloop-session-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "session.json")
        var file = SessionFile(udid: "test", host: "::1", port: 1234, token: "test-only", pid: 123)
        try file.write(to: url)
        file.port = 5678
        try file.write(to: url)
        let decoded = try JSONDecoder().decode(SessionFile.self, from: Data(contentsOf: url))
        #expect(decoded.port == 5678)
        #expect(decoded.token == "test-only")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["session.json"])
    }

    @Test func sessionPersistenceFailureIsVisible() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "deviceloop-session-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = SessionFile(udid: "test", host: "::1", port: 1234, token: "test-only", pid: 123)
        #expect(throws: DeviceLoopError.self) {
            try file.write(to: directory)
        }
    }
}
