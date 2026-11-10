//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Testing

@testable import DeviceLoopKit

/// `list-preferredDDI.json` as recorded, or with `isUsable` false.
private func preferredDDI(usable: Bool = true) throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: "Resources/devicectl/list-preferredDDI", withExtension: "json"))
    var text = try String(contentsOf: url, encoding: .utf8)
    if !usable { text = text.replacingOccurrences(of: "\"isUsable\": true", with: "\"isUsable\": false") }
    return try #require(try JSONValue(data: Data(text.utf8))["result"])
}

@Suite struct DoctorTests {
    func device(
        paired: Bool = true,
        developerMode: Bool? = true,
        connection: String = "connected",
        transport: String = "wired",
        tunnel: String? = "fd85:efc2:a0aa::1"
    ) -> Target {
        Target(
            udid: "00008130-578D60C5D3FFD610",
            identifier: "6812A417-3B91-576A-A4EB-F81FED731A58",
            name: "Test iPhone",
            kind: .device,
            deviceType: "iPhone",
            platform: "iOS",
            model: "iPhone 15 Pro Max",
            productType: "iPhone16,2",
            osVersion: "27.0",
            connectionState: connection,
            bootState: "booted",
            transport: transport,
            paired: paired,
            developerModeEnabled: developerMode,
            tunnelAddress: tunnel,
            capabilities: [Capability.lockState]
        )
    }

    func simulator(bootState: String) -> Target {
        Target(
            udid: "00000000-0000-0000-0000-000000000112",
            identifier: "00000000-0000-0000-0000-000000000112",
            name: "iPhone Duo",
            kind: .simulator,
            deviceType: "iPhone",
            platform: "iOS",
            model: "iPhone Duo",
            productType: "iPhone99,1",
            osVersion: "27.1",
            connectionState: bootState == "booted" ? "connected" : "disconnected",
            bootState: bootState,
            transport: "sameMachine"
        )
    }

    @Test func fullXcodePassesWithVersionAndBuild() {
        let check = DoctorReport.xcodeCheck(
            developerDir: "/Applications/Xcode.app/Contents/Developer\n",
            versionOutput: "Xcode 27.1\nBuild version 27A9275\n"
        )
        #expect(check.status == .ok)
        #expect(check.detail == "Xcode 27.1 (27A9275) at /Applications/Xcode.app/Contents/Developer")
    }

    @Test func commandLineToolsSelectionFails() {
        let check = DoctorReport.xcodeCheck(developerDir: "/Library/Developer/CommandLineTools", versionOutput: nil)
        #expect(check.status == .fail)
        #expect(check.code == .xcodeMissing)
        #expect(check.fix?.contains("xcode-select -s") == true)
    }

    @Test func xcodeOlderThan27Warns() {
        let check = DoctorReport.xcodeCheck(developerDir: "/Applications/Xcode-26.app", versionOutput: "Xcode 26.6\nBuild version 17E100")
        #expect(check.status == .warn)
    }

    @Test func missingDevicectlFails() {
        let check = DoctorReport.devicectlCheck(versionOutput: nil)
        #expect(check.status == .fail)
        #expect(check.code == .xcodeMissing)
    }

    @Test func readyWiredDevicePassesStateChecks() {
        let checks = DoctorReport.stateChecks(device())
        #expect(checks.map(\.name) == ["pairing", "developer mode", "connection", "tunnel"])
        #expect(checks.allSatisfy { $0.status == .ok })
    }

    @Test func developerModeOffFailsWithItsCode() throws {
        let check = try #require(DoctorReport.stateChecks(device(developerMode: false)).first { $0.name == "developer mode" })
        #expect(check.status == .fail)
        #expect(check.code == .developerModeOff)
    }

    @Test func unpairedDeviceNeedsTrust() throws {
        let check = try #require(DoctorReport.stateChecks(device(paired: false)).first { $0.name == "pairing" })
        #expect(check.status == .fail)
        #expect(check.code == .trustRequired)
    }

    @Test func disconnectedDeviceFailsAndSkipsTunnel() {
        let checks = DoctorReport.stateChecks(device(connection: "disconnected", tunnel: nil))
        #expect(checks.last?.name == "connection")
        #expect(checks.last?.status == .fail)
        #expect(checks.last?.code == .deviceOffline)
    }

    @Test func networkConnectionWarnsAboutUSB() throws {
        let check = try #require(DoctorReport.stateChecks(device(transport: "localNetwork")).first { $0.name == "connection" })
        #expect(check.status == .warn)
    }

    @Test func shutDownSimulatorFailsWithBootCommand() throws {
        let check = try #require(DoctorReport.stateChecks(simulator(bootState: "shutdown")).first)
        #expect(check.status == .fail)
        #expect(check.fix == "xcrun simctl boot 00000000-0000-0000-0000-000000000112")
    }

    @Test func shutDownSimulatorWarnsWhenNotSelected() throws {
        let check = try #require(DoctorReport.stateChecks(simulator(bootState: "shutdown"), selected: false).first)
        #expect(check.status == .warn)
    }

    @Test func passcodeRequiredMeansLocked() {
        let check = DoctorReport.lockCheck(["passcodeRequired": true, "unlockedSinceBoot": true], target: device())
        #expect(check.status == .warn)
        #expect(check.code == .deviceLocked)
    }

    @Test func unusableDeveloperDiskImageWarns() throws {
        let host = DoctorReport.hostDDICheck(try preferredDDI())
        let check = DoctorReport.ddiCheck(["ddiMetadata": ["isUsable": false]], target: device(), host: host)
        #expect(check.status == .warn)
        #expect(check.code == .ddiUnavailable)
        #expect(check.fix == "deviceloop prepare --device 00008130-578D60C5D3FFD610")
    }

    @Test func recordedHostImagePasses() throws {
        let check = DoctorReport.hostDDICheck(try preferredDDI())
        #expect(check.status == .ok)
        #expect(check.detail == "iOS 27B52 at /Library/Developer/DeveloperDiskImages/iOS_DDI")
    }

    @Test func unusableHostImageWarnsWithTheUpdateCommands() throws {
        let check = DoctorReport.hostDDICheck(try preferredDDI(usable: false))
        #expect(check.status == .warn)
        #expect(check.code == .ddiUnavailable)
        #expect(check.detail == "iOS 27B52 at /Library/Developer/DeveloperDiskImages/iOS_DDI is not usable")
        #expect(check.fix?.contains("sudo xcodebuild -runFirstLaunch -checkForNewerComponents") == true)
        #expect(check.fix?.contains("xcrun devicectl manage ddis update") == true)
    }

    @Test func unmountedDeviceImageOnAHostWithoutOneGetsTheHostFix() throws {
        let host = DoctorReport.hostDDICheck(try preferredDDI(usable: false))
        let check = DoctorReport.ddiCheck(["ddiMetadata": ["isUsable": false]], target: device(), host: host)
        let mountable = DoctorReport.ddiCheck(
            ["ddiMetadata": ["isUsable": false]], target: device(), host: DoctorReport.hostDDICheck(try preferredDDI()))
        #expect(check.fix == host.fix)
        #expect(check.fix != mountable.fix)
        #expect(check.detail != mountable.detail)
    }

    func health() -> HealthResult {
        HealthResult(
            version: RunnerWire.version, runnerBuild: "test", os: "test", uptimeS: 90, busy: false, queue: 0,
            sessionEpoch: UUID().uuidString)
    }

    @Test func liveRunnerMakesUIAutomationOK() throws {
        let now = try Date("2026-11-08T20:01:30Z", strategy: .iso8601)
        let check = DoctorReport.automationCheck(health(), enabledAt: nil, deviceLoopVersion: version, target: device(), now: now)
        #expect(check.status == .ok)
        #expect(check.detail == "runner live since 2026-11-08T20:00:00Z")
    }

    @Test(arguments: [nil, "0.0.1"] as [String?])
    func liveRunnerFromAnotherDeviceLoopVersionWarnsAndPointsAtPrepare(startedBy: String?) {
        let check = DoctorReport.automationCheck(health(), enabledAt: nil, deviceLoopVersion: startedBy, target: device())
        #expect(check.status == .warn)
        #expect(check.detail == "runner started by another DeviceLoop version. The next UI command replaces it")
        #expect(check.fix == "deviceloop prepare --device 00008130-578D60C5D3FFD610")
    }

    @Test func noLiveRunnerWarnsThatStartingOneMayAskForThePasscode() throws {
        var target = device()
        target.udid = "doctor-automation-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
        try RunnerSession.recordAutomationEnabled(for: target.udid)
        let enabledAt = try #require(RunnerSession.automationEnabledAt(for: target.udid))
        let check = DoctorReport.automationCheck(nil, enabledAt: enabledAt, deviceLoopVersion: version, target: target)
        #expect(check.status == .warn)
        #expect(check.code == .uiAutomationPasscode)
        #expect(check.detail == "no live runner. Starting one may ask for the passcode on Test iPhone, last enabled \(enabledAt)")
    }

    func session(host: String) -> SessionFile {
        SessionFile(udid: "00008130-578D60C5D3FFD610", host: host, port: 49152, token: "token", pid: 4242)
    }

    @Test func noRunnerSessionPasses() {
        let check = DoctorReport.runnerCheck(device(), session: nil)
        #expect(check.status == .ok)
        #expect(check.detail == "no session")
    }

    @Test func runnerAtTheTunnelAddressPassesWithHostAndPort() {
        let check = DoctorReport.runnerCheck(device(), session: session(host: "fd85:efc2:a0aa::1")) { _ in .running }
        #expect(check.status == .ok)
        #expect(check.detail == "session at fd85:efc2:a0aa::1:49152, host process running")
    }

    @Test func runningHostProcessWhoseRunnerDoesNotAnswerWarns() {
        let check = DoctorReport.runnerCheck(device(), session: session(host: "fd85:efc2:a0aa::1"), answered: false) { _ in .running }
        #expect(check.status == .warn)
        #expect(check.detail == "session at fd85:efc2:a0aa::1:49152, host process running, runner does not answer")
        #expect(check.code == .runnerUnreachable)
        #expect(check.fix == "deviceloop runner stop --device 00008130-578D60C5D3FFD610, then run the UI command again.")
    }

    @Test func runningHostProcessOnADeviceWithNoTunnelAddressWarns() {
        let check = DoctorReport.runnerCheck(device(tunnel: nil), session: session(host: "fd85:efc2:a0aa::1")) { _ in .running }
        #expect(check.status == .warn)
        #expect(check.detail == "session at fd85:efc2:a0aa::1:49152, host process running, device has no tunnel address")
        #expect(check.code == .runnerUnreachable)
    }

    @Test func runnerThatAnswersOnADeviceWithNoTunnelAddressPasses() {
        let check = DoctorReport.runnerCheck(device(tunnel: nil), session: session(host: "fd85:efc2:a0aa::1"), answered: true) { _ in
            .running
        }
        #expect(check.status == .ok)
        #expect(check.detail == "session at fd85:efc2:a0aa::1:49152, host process running")
    }

    @Test func liveRunnerLeftAtAnOldTunnelAddressWarns() {
        let check = DoctorReport.runnerCheck(device(), session: session(host: "fd85:efc2:a0aa::2")) { _ in .running }
        #expect(check.status == .warn)
        #expect(
            check.detail == "session at fd85:efc2:a0aa::2:49152, but the device tunnel moved to fd85:efc2:a0aa::1, host process running")
        #expect(check.code == .runnerUnreachable)
        #expect(check.fix?.hasPrefix("deviceloop runner stop --device 00008130-578D60C5D3FFD610") == true)
    }

    @Test func exitedRunnerLeftAtAnOldTunnelAddressPointsAtANewRunner() {
        let check = DoctorReport.runnerCheck(device(), session: session(host: "fd85:efc2:a0aa::2")) { _ in .exited }
        #expect(check.status == .warn)
        #expect(check.code == nil)
        #expect(check.fix?.contains("deviceloop runner start --device 00008130-578D60C5D3FFD610") == true)
    }

    @Test func stoppingRunnerWithALiveHostProcessWarnsBusy() {
        var stopping = session(host: "fd85:efc2:a0aa::1")
        stopping.stopping = true
        let check = DoctorReport.runnerCheck(device(), session: stopping) { _ in .running }
        #expect(check.status == .warn)
        #expect(check.code == .deviceBusy)
    }

    @Test func fixLineFollowsItsCheck() {
        let report = DoctorReport(
            header: "This Mac (macOS 27.0.1)",
            host: [DoctorCheck("license", .fail, "Xcode license not accepted", fix: "sudo xcodebuild -license accept")],
            targets: []
        )
        let expected = [
            "This Mac (macOS 27.0.1)",
            "fail license: Xcode license not accepted",
            "     fix: sudo xcodebuild -license accept",
            "1 failed, 0 warnings",
        ]
        #expect(report.text.split(separator: "\n").map(String.init) == expected)
    }

    @Test func selectedTargetIsNotRepeatedUnderTheHeader() {
        let target = simulator(bootState: "booted")
        let section = DoctorReport.Section(target, checks: DoctorReport.stateChecks(target))
        let report = DoctorReport(header: target.summary, host: [], targets: [section])
        #expect(report.text.split(separator: "\n").filter { $0 == target.summary }.count == 1)
    }

    @Test func failedCheckMakesJSONNotOK() throws {
        let report = DoctorReport(header: "This Mac", host: [DoctorCheck("xcode", .fail, "missing")], targets: [])
        let json = try JSONValue(encoding: report)
        #expect(json["ok"] == false)
        #expect(json["failures"] == 1)
    }

    @Test func missingCaptureHelperWarns() {
        let home = FileManager.default.temporaryDirectory.appending(path: "deviceloop-doctor-\(UUID().uuidString)")
        #expect(DoctorReport.captureHelperCheck(home: home, bundled: nil, bundledProblem: nil).status == .warn)
    }

    @Test func builtCaptureHelperPasses() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "deviceloop-doctor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let contents = home.appending(path: "DeviceLoopCapture.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: contents.appending(path: "Info.plist"))
        let check = DoctorReport.captureHelperCheck(home: home, bundled: nil, bundledProblem: nil)
        #expect(check.status == .ok)
        #expect(check.detail.hasPrefix("built "))
    }

    @Test func verifiedBundledCaptureHelperIsReported() {
        let home = FileManager.default.temporaryDirectory.appending(path: "deviceloop-doctor-\(UUID().uuidString)")
        let bundled = URL(filePath: "/opt/homebrew/Cellar/deviceloop/0.1.0/libexec/DeviceLoopCapture.app")
        let check = DoctorReport.captureHelperCheck(home: home, bundled: bundled, bundledProblem: nil)
        #expect(check.status == .ok)
        #expect(check.detail == "bundled \(bundled.path), camera permission not readable")
    }

    @Test func bundledCaptureHelperWithBadSignatureWarns() {
        let home = FileManager.default.temporaryDirectory.appending(path: "deviceloop-doctor-\(UUID().uuidString)")
        let bundled = URL(filePath: "/opt/homebrew/Cellar/deviceloop/0.1.0/libexec/DeviceLoopCapture.app")
        let check = DoctorReport.captureHelperCheck(home: home, bundled: bundled, bundledProblem: "invalid Info.plist")
        #expect(check.status == .warn)
        #expect(check.detail.contains(home.appending(path: "DeviceLoopCapture.app").path))
    }

    @Test func missingRunnerProjectFailsWithTheRunnerPathFix() {
        let check = DoctorReport.runnerProjectCheck(nil)
        #expect(check.status == .fail)
        #expect(check.fix?.contains("DEVICELOOP_RUNNER_PATH") == true)
    }

    @Test func bundledCaptureAppResolvesThroughSymlinkedExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "deviceloop-prefix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "Cellar/deviceloop/0.1.0")
        let app = prefix.appending(path: "libexec/DeviceLoopCapture.app")
        try FileManager.default.createDirectory(at: prefix.appending(path: "bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: app.appending(path: "Contents/Info.plist"))
        try Data().write(to: prefix.appending(path: "bin/deviceloop"))
        let link = root.appending(path: "bin/deviceloop")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: prefix.appending(path: "bin/deviceloop"))
        #expect(Paths.bundledCaptureApp(executable: link)?.path == app.resolvingSymlinksInPath().path)
    }

    @Test func bundledCaptureAppIsNilWithoutLibexec() throws {
        let prefix = FileManager.default.temporaryDirectory.appending(path: "deviceloop-prefix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: prefix) }
        try FileManager.default.createDirectory(at: prefix.appending(path: "bin"), withIntermediateDirectories: true)
        try Data().write(to: prefix.appending(path: "bin/deviceloop"))
        #expect(Paths.bundledCaptureApp(executable: prefix.appending(path: "bin/deviceloop")) == nil)
    }

    /// Writes an ad hoc signed DeviceLoopCapture.app at `app` whose executable is a copy of `/usr/bin/true`.
    func signedCaptureApp(_ app: URL) async throws {
        try FileManager.default.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: CaptureApp.info, format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: app.appending(path: "Contents/MacOS/deviceloop"))
        #expect(try await Shell.run(["codesign", "--force", "--sign", "-", app.path]).succeeded)
    }

    @Test func captureAppUsesVerifiedBundledHelper() async throws {
        let prefix = FileManager.default.temporaryDirectory.appending(path: "deviceloop-prefix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: prefix) }
        let app = prefix.appending(path: "libexec/DeviceLoopCapture.app")
        try await signedCaptureApp(app)
        try FileManager.default.createDirectory(at: prefix.appending(path: "bin"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: prefix.appending(path: "bin/deviceloop"))
        let used = try await CaptureApp.ensure(executable: prefix.appending(path: "bin/deviceloop"))
        #expect(used.path == app.resolvingSymlinksInPath().path)
    }

    @Test func captureAppSignatureCheckRejectsAModifiedBundle() async throws {
        let app = FileManager.default.temporaryDirectory.appending(path: "deviceloop-capture-\(UUID().uuidString)/DeviceLoopCapture.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        try await signedCaptureApp(app)
        #expect(await CaptureApp.signatureProblem(app) == nil)

        try PropertyListSerialization.data(fromPropertyList: CaptureApp.info, format: .binary, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        #expect(await CaptureApp.signatureProblem(app)?.hasPrefix("invalid Info.plist") == true)
    }

    @Test func packagedCaptureInfoMatchesBuiltHelper() throws {
        let file = URL(filePath: #filePath).appending(path: "../../../Packaging/DeviceLoopCapture-Info.plist").standardizedFileURL
        let packaged = try #require(
            try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? NSDictionary)
        #expect(packaged.isEqual(to: CaptureApp.info))
    }
}

/// Runs against a booted simulator: DEVICELOOP_TEST_SIMULATOR=<udid> xcrun swift test --filter DoctorLiveTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEVICELOOP_TEST_SIMULATOR"] != nil), .sharedSimulator)
struct DoctorLiveTests {
    @Test func liveRunnerAnswersTheUIAutomationCheck() async throws {
        let target = try await TargetResolver.resolve(ProcessInfo.processInfo.environment["DEVICELOOP_TEST_SIMULATOR"])
        _ = try await RunnerSession.connect(target)
        let check = DoctorReport.automationCheck(
            await RunnerSession.liveHealth(target), enabledAt: nil,
            deviceLoopVersion: SessionFile.read(for: target.udid)?.deviceLoopVersion,
            target: target)
        #expect(check.status == .ok, "\(check.detail)")
    }
}

extension DoctorTests {
    /// A DEVICELOOP_HOME with a runner session, a runner build and a failed run, holding the values in `planted`.
    struct ExportFixture {
        let home = FileManager.default.temporaryDirectory.appending(
            path: "deviceloop-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        let userHome = "/Users/jappleseed"
        let token = Data((0 ..< 32).map { UInt8($0 * 5) }).base64EncodedString()
        let identity = "Apple Development: John Appleseed (Z9Y8X7W6V5)"
        let target: Target
        let signing: SigningState

        var planted: [String] {
            [
                userHome, token, identity, "QX7K2M9P4L", "Appleseed Fruit Co", target.name, target.udid, target.identifier,
                "fd85:efc2:a0aa::1", "hunter2", "call Mom",
            ]
        }

        init(device: Target) throws {
            var named = device
            named.name = "Johnny's Test iPhone"
            target = named
            signing = SigningState(
                teams: [SigningTeam(id: "QX7K2M9P4L", name: "Appleseed Fruit Co", type: "Company", isFree: false)],
                identities: [SigningIdentity(sha1: String(repeating: "A", count: 40), name: identity, team: "QX7K2M9P4L")])

            let session = home.appending(path: "sessions/\(target.udid)", directoryHint: .isDirectory)
            let key = "device-\(String(repeating: "0", count: 64))"
            let products = home.appending(path: "runner/\(key)/Build/Products", directoryHint: .isDirectory)
            let xctestrun = products.appending(path: "run-\(UUID().uuidString).xctestrun")
            try Paths.ensureDirectory(products)
            try Data("DEVICELOOP_TOKEN \(token) DEVELOPMENT_TEAM QX7K2M9P4L \(userHome)".utf8).write(to: xctestrun)
            try SessionFile(udid: target.udid, host: "fd85:efc2:a0aa::1", port: 59479, token: token, pid: 1, xctestrunPath: xctestrun.path)
                .write(to: session.appending(path: "session.json"))
            let log = [
                "xcodebuild test-without-building -xctestrun \(xctestrun.path) -destination id=\(target.udid)",
                "Writing result bundle at path: \(userHome)/Library/Caches/deviceloop/sessions/\(target.udid)/result.xcresult",
                #"Signing Identity: "\#(identity)""#,
                "DEVELOPMENT_TEAM = QX7K2M9P4L (Appleseed Fruit Co)",
                "Installing on Johnny's Test iPhone (\(target.identifier))",
                "DEVICELOOP_READY port=59479 v=4 bind=fd85:efc2:a0aa::1",
                "Authorization: Bearer \(token)",
                "DEVICELOOP_TOKEN \(token)",
                #"    t =     5.12s Type 'hunter2' into "fixture.text.input" TextField"#,
                "    t =     6.40s Activate Siri with voice recognition text: call Mom",
            ]
            let startup = try Paths.ensureDirectory(session.appending(path: "startup-\(UUID().uuidString)", directoryHint: .isDirectory))
            try Data(log.joined(separator: "\n").utf8).write(to: startup.appending(path: "xcodebuild.log"))

            let run = RunStore(directory: try Paths.ensureDirectory(home.appending(path: "runs/run-20261108-120000-abc123")))
            try run.write(
                RunManifest(
                    id: run.id, name: target.name, status: .finished, outcome: .failed, createdAt: "2026-11-08T12:00:00.000Z",
                    finishedAt: "2026-11-08T12:00:02.500Z", hostStart: 0))
            var started = RunEvent(kind: "started", command: "ui tap", args: ["id=missing", "--device", .string(target.name)])
            started.seq = 1
            started.offset = 0.5
            let error = DeviceLoopError(.elementNotFound, "No element id=missing on \(target.udid).", device: target.name)
            var finished = RunEvent(kind: "finished", command: "ui tap", started: 1, outcome: .error, error: error)
            finished.seq = 2
            finished.offset = 0.75
            let journal = try [started, finished].map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
            try Data(journal.joined(separator: "\n").utf8).write(to: run.eventsURL)
        }

        var doctor: DoctorReport {
            let config = DoctorCheck("deviceloop team", .ok, "QX7K2M9P4L in \(userHome)/Library/Caches/deviceloop/config.json")
            let checks =
                DoctorReport.stateChecks(target) + [
                    DoctorReport.ddiCheck(.object([:]), target: target, host: DoctorCheck("host ddi", .ok, "iOS 27B52"))
                ]
            return DoctorReport(
                header: SetupCommands.hostSummary, host: DoctorReport.signingChecks(signing, stored: nil) + [config],
                targets: [DoctorReport.Section(target, checks: checks)])
        }

        func export(to directory: URL, runnerLogs: Bool = true) throws -> [String] {
            var redactor = SupportExport.redactor(home: userHome, targets: [target], signing: signing, storedTeam: "QX7K2M9P4L")
            return try SupportExport.write(
                doctor: doctor, versions: ["deviceloop 0.1.0"], home: home, includeRunnerLogs: runnerLogs, redactor: &redactor,
                to: directory)
        }
    }

    @Test func exportHasNoPlantedValueAndNoCredentialFile() throws {
        let fixture = try ExportFixture(device: device())
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let directory = fixture.home.appending(path: "export", directoryHint: .isDirectory)
        let files = try fixture.export(to: directory)
        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(written) == Set(files))
        #expect(written.count == 5)
        #expect(!written.contains { $0 == "session.json" || $0.hasSuffix(".xctestrun") })
        for name in written {
            let data = try Data(contentsOf: directory.appending(path: name))
            for value in fixture.planted {
                #expect(data.range(of: Data(value.utf8)) == nil, "\(name) contains \(value)")
                #expect(!name.contains(value))
            }
        }
    }

    @Test func udidKeepsOneAliasWithinAnExportAndChangesAcrossExports() throws {
        let fixture = try ExportFixture(device: device())
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        var aliases: [Set<String>] = []
        for name in ["first", "second", "third"] {
            let directory = fixture.home.appending(path: name, directoryHint: .isDirectory)
            var found: Set<String> = []
            for file in try fixture.export(to: directory) {
                let text = file + String(decoding: try Data(contentsOf: directory.appending(path: file)), as: UTF8.self)
                found.formUnion(text.matches(of: /udid-[0-9a-f]{4,}/).map { String($0.0) })
            }
            aliases.append(found)
        }
        #expect(aliases.allSatisfy { $0.count == 1 })
        #expect(Set(aliases).count >= 2)
    }

    @Test func exportRunsHoldOnlyIDsStatusDurationsCommandNamesAndErrorCodes() throws {
        let fixture = try ExportFixture(device: device())
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let directory = fixture.home.appending(path: "export", directoryHint: .isDirectory)
        _ = try fixture.export(to: directory)
        let runs = try JSONValue(data: Data(contentsOf: directory.appending(path: "runs.json")))
        let command: JSONValue = ["command": "ui tap", "outcome": "error", "code": "element_not_found", "seconds": 0.25]
        let run: JSONValue = [
            "id": "run-20261108-120000-abc123", "status": "finished", "outcome": "failed", "seconds": 2.5, "commands": [command],
        ]
        #expect(runs == [run])
    }

    @Test func exportLeavesOutRunnerLogsUnlessAsked() throws {
        let fixture = try ExportFixture(device: device())
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let files = try fixture.export(to: fixture.home.appending(path: "export", directoryHint: .isDirectory), runnerLogs: false)
        #expect(files == ["doctor.json", "version.txt", "runs.json", "REDACTIONS.txt"])
    }

    @Test func exportRefusesAFolderThatIsNotEmpty() throws {
        let fixture = try ExportFixture(device: device())
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let directory = try Paths.ensureDirectory(fixture.home.appending(path: "export", directoryHint: .isDirectory))
        try Data("notes".utf8).write(to: directory.appending(path: "notes.txt"))
        let error = #expect(throws: DeviceLoopError.self) {
            try fixture.export(to: directory)
        }
        #expect(error?.code == .badArguments)
    }

    @Test func exportRefusesAPathThatIsAFile() throws {
        let fixture = try ExportFixture(device: device())
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let file = fixture.home.appending(path: "export.txt")
        try Data("notes".utf8).write(to: file)
        let error = #expect(throws: DeviceLoopError.self) { try fixture.export(to: file) }
        #expect(error?.code == .badArguments)
    }
}
