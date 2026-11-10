//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import DeviceLoopKit

private func fixture(_ name: String) throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: "Resources/devicectl/\(name)", withExtension: "json"))
    return try #require(try JSONValue(data: Data(contentsOf: url))["result"])
}

private func simulator(bootState: String = "booted", capabilities: Set<String> = []) -> Target {
    Target(
        udid: "00000000-0000-0000-0000-000000000001",
        identifier: "00000000-0000-0000-0000-000000000001",
        name: "Test Simulator",
        kind: .simulator,
        deviceType: "iPhone",
        platform: "iOS",
        model: "iPhone 17 Pro",
        productType: "iPhone18,1",
        osVersion: "27.1",
        connectionState: bootState == "booted" ? "connected" : "disconnected",
        bootState: bootState,
        transport: "sameMachine",
        capabilities: capabilities
    )
}

private func device(developerMode: Bool = true) -> Target {
    Target(
        udid: "00000000-F3D2A99B0DA7486F",
        identifier: "00000000-0000-0000-0000-000000000002",
        name: "Test iPhone",
        kind: .device,
        deviceType: "iPhone",
        platform: "iOS",
        model: "iPhone 13 Pro",
        productType: "iPhone14,2",
        osVersion: "18.7.8",
        connectionState: "connected",
        bootState: "booted",
        transport: "wired",
        developerModeEnabled: developerMode
    )
}

@Suite struct ParityDisplayTests {
    @Test func visibleDisplaySkipsInactivePrimary() throws {
        let displays = DeviceDisplays(devicectl: try fixture("info-displays-dual-simulator"))
        #expect(displays.displays.count == 2)
        #expect(displays.visible?.name == "LCD-1")
        #expect(displays.visible?.primary == false)
        #expect(displays.visible?.uniqueID == "00000000-0000-0000-0000-000000000002")
    }

    @Test func pointSizeDividesNativeSizeByScale() throws {
        let screen = try #require(DeviceDisplays(devicectl: try fixture("info-displays-device")).visible)
        #expect(screen.pointWidth == 390)
        #expect(screen.pointHeight == 844)
    }

    @Test func readsDeviceOrientation() throws {
        #expect(DeviceDisplays(devicectl: try fixture("info-displays-device")).orientation == "portrait")
    }

    @Test func orientationGetPrefersTheNonFlatValue() throws {
        let state = DeviceOrientation(devicectl: try fixture("orientation-get"))
        #expect(state.orientation == "portrait")
        #expect(state.locked == false)
    }

    @Test func orientationLockIsNilWhenDevicectlOmitsIt() throws {
        var fields = try #require(try fixture("orientation-get").object)
        fields["deviceIsOrientationLocked"] = nil
        #expect(DeviceOrientation(devicectl: .object(fields)).locked == nil)
    }
}

@Suite struct ParityAppTests {
    @Test func marksAppsThatShipWithTheOS() throws {
        let apps = InstalledApp.list(devicectl: try fixture("info-apps-all"))
        #expect(apps.filter { !$0.systemApp }.map(\.bundleID) == ["com.example.sample", "com.example.store"])
    }

    @Test func matchesProcessesToAppBundles() throws {
        let apps = InstalledApp.list(devicectl: try fixture("info-apps-all"))
        let running = RunningApps.match(processes: try fixture("info-processes-device"), apps: apps)
        #expect(running == ["com.apple.Preferences": [731], "com.example.sample": [2101]])
    }

    @Test func launchOutcomeComparesThePidWithThePidsBefore() {
        #expect(AppCommands.launchOutcome(pid: 7, before: []) == "launched")
        #expect(AppCommands.launchOutcome(pid: 7, before: [7]) == "activated")
        #expect(AppCommands.launchOutcome(pid: 8, before: [7]) == "relaunched")
    }

    @Test func consoleOnARunningAppSaysItsOutputIsNotConnected() {
        #expect(
            AppCommands.consoleNotConnected("com.example.sample", pids: [2101])
                == "com.example.sample is already running as pid 2101, so its output is not connected. Add --restart to capture it.")
    }

    @Test func activatedLineSaysTheConsoleOutputWasNotCaptured() {
        let console = AppCommands.outcomeLine(
            "activated", bundleID: "com.example.sample", pid: 2101, before: [2101], passedOptions: false, console: true)
        let plain = AppCommands.outcomeLine(
            "activated", bundleID: "com.example.sample", pid: 2101, before: [2101], passedOptions: false, console: false)
        #expect(console == "Activated com.example.sample, pid 2101, already running, so its output was not captured")
        #expect(plain == "Activated com.example.sample, pid 2101, already running")
    }

    @Test func activatedLineJoinsWhatDidNotApplyIntoOneClause() {
        let line = AppCommands.outcomeLine(
            "activated", bundleID: "com.example.sample", pid: 2101, before: [2101], passedOptions: true, console: true)
        #expect(
            line == "Activated com.example.sample, pid 2101, already running, "
                + "so arguments and environment did not apply and its output was not captured")
    }

    @Test func consoleResultWithholdsEnvironmentValues() {
        let result: JSONValue = ["launchOptions": ["arguments": ["-flag"], "environmentVariables": ["TOKEN": "secret"]]]
        let json = AppCommands.consoleJSON(result, adding: ["environmentKeys": ["TOKEN"]])
        #expect(json.value(at: "launchOptions.environmentVariables") == nil)
        #expect(json.value(at: "launchOptions.arguments") == ["-flag"])
        #expect(json["environmentKeys"] == ["TOKEN"])
    }

    @Test func readsSimulatorAppsFromLaunchctl() throws {
        let url = try #require(Bundle.module.url(forResource: "Resources/devicectl/simctl-launchctl-list", withExtension: "txt"))
        let running = RunningApps.match(launchctlList: try String(contentsOf: url, encoding: .utf8))
        #expect(
            running.keys.sorted() == ["com.apple.DocumentManager.DockFolderViewService", "com.apple.Preferences", "com.example.sample"])
        #expect(running["com.apple.Preferences"] == [36506])
    }

    @Test func runningReportListsPidsAndTheScopedForeground() throws {
        let foreground = ForegroundReport(known: true, apps: ["com.apple.Preferences"], scope: "running apps via UI runner")
        let result = try AppCommands.runningReport(
            simulator(), running: ["com.example.sample": [2101, 2102], "com.apple.Preferences": [731]], foreground: foreground)
        #expect(
            result.text.split(separator: "\n").dropFirst().map(String.init) == [
                "2 running apps", "com.apple.Preferences  731", "com.example.sample     2101, 2102",
                "foreground: com.apple.Preferences (scope: running apps via UI runner)",
            ])
        #expect(result.json["running"]?[1] == ["bundleID": "com.example.sample", "pids": [2101, 2102]])
        #expect(result.json["foreground"] == ["known": true, "apps": ["com.apple.Preferences"], "scope": "running apps via UI runner"])
    }

    @Test func foregroundWithoutARunnerIsUnknownWithTheStartFix() async throws {
        let id = "unit-test-foreground-\(UUID().uuidString)"
        let target = Target(
            udid: id, identifier: id, name: "Unit test", kind: .simulator, deviceType: "iPhone", platform: "iOS",
            model: "fixture", productType: "fixture", osVersion: "test", connectionState: "connected"
        )
        defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
        let report = try await UICommands.foreground(target, candidates: ["com.apple.Preferences"])
        let fix = "Start one with `deviceloop runner start --device \(id)`."
        #expect(report == ForegroundReport(known: false, reason: "No UI runner is running on Unit test.", fix: fix))
        #expect(report.line == "foreground: unknown. No UI runner is running on Unit test. \(fix)")
    }
}

@Suite struct ParityConsoleTests {
    @Test func lineSplitterHoldsAPartialLineUntilItsNewline() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("ab".utf8)) == [])
        #expect(splitter.feed(Data("c\nd".utf8)) == ["abc"])
        #expect(splitter.feed(Data("e\nf".utf8)) == ["de"])
        #expect(splitter.finish() == "f")
        #expect(splitter.finish() == nil)
    }

    @Test func lineSplitterDropsTheCarriageReturnOfCRLF() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("M1\r\nM2\r".utf8)) == ["M1"])
        #expect(splitter.feed(Data("\n".utf8)) == ["M2"])
    }

    @Test func savedLinesStartWithTheHostTimeInUTC() {
        #expect(AppCommands.stamped("M1", at: Date(timeIntervalSince1970: 1.5)) == "1970-01-01T00:00:01.500Z M1")
    }

    @Test func echoWritesTheLineToTheOutputAndTheStampedLineToTheLog() throws {
        let output = Pipe()
        let log = FileManager.default.temporaryDirectory.appending(path: "deviceloop-echo-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let logFile = try FileHandle(forWritingTo: log)
        AppCommands.echo("M1", to: output.fileHandleForWriting, log: logFile)
        try logFile.close()
        try output.fileHandleForWriting.close()
        #expect(output.fileHandleForReading.readDataToEndOfFile() == Data("M1\n".utf8))
        let saved = try String(contentsOf: log, encoding: .utf8)
        #expect(saved.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z M1\n/) != nil)
    }
}

@Suite struct ParityCrashTests {
    @Test func listsOnlyReportFiles() throws {
        let reports = CrashReport.list(devicectl: try fixture("info-files-systemCrashLogs"))
        #expect(reports.count == 4)
        #expect(reports.contains { $0.name == "Retired/Sample-2026-10-01-080000.ips" })
    }

    @Test func processNameDropsTheTimestamp() {
        #expect(CrashReport.process(fromFileName: "Sample.cpu_resource-2026-10-18-120000.ips") == "Sample.cpu_resource")
        #expect(CrashReport.process(fromFileName: "Sample-2026-10-22-125249.0002.ips") == "Sample")
    }

    @Test func selectsByProcessPrefixNewestFirst() throws {
        let reports = CrashReport.list(devicectl: try fixture("info-files-systemCrashLogs"))
        let selected = CrashReport.select(reports, process: "sample")
        #expect(
            selected.map(\.name) == [
                "Sample-2026-10-20-231001.ips", "Sample.cpu_resource-2026-10-18-120000.ips", "Retired/Sample-2026-10-01-080000.ips",
            ])
    }

    @Test func namesKnownBugTypes() throws {
        let kinds = CrashReport.list(devicectl: try fixture("info-files-systemCrashLogs")).map(\.kind)
        #expect(kinds.sorted() == ["bug_type 288", "cpu_resource", "crash", "crash"])
    }

    @Test func datesHostReportsByHeaderTimestamp() {
        let contents = Data(
            (#"{"app_name":"Sample","timestamp":"2026-10-22 11:35:39.00 -0700","bug_type":"309","name":"Sample"}"# + "\n{}").utf8)
        let report = CrashReport(name: "Sample-2026-10-22-113539.ips", contents: contents, modified: .distantPast)
        #expect(report.date == Date(timeIntervalSince1970: 1_792_694_139))
    }

    @Test func sinceDropsEarlierReportsAndKeepsUndatedOnes() throws {
        let undated = CrashReport(name: "Sample-undated.ips", date: nil, bugType: "309", size: nil)
        let reports = CrashReport.list(devicectl: try fixture("info-files-systemCrashLogs")) + [undated]
        let since = try CrashCommands.time("2026-10-19T00:00:00.000Z")
        #expect(
            CrashReport.select(reports, process: nil, since: since).map(\.name) == [
                "Sample-2026-10-20-231001.ips", "stacks+backboardd-2026-10-19-101500.ips", "Sample-undated.ips",
            ])
    }

    @Test func sinceTakesTimesWithAndWithoutMilliseconds() throws {
        let launchedAt = try CrashCommands.time("2026-11-08T21:59:40.778Z")
        #expect(abs(launchedAt.timeIntervalSince1970 - 1_794_175_180.778) < 0.001)
        #expect(try CrashCommands.time("2026-11-08T13:59:40-08:00") == Date(timeIntervalSince1970: 1_794_175_180))
    }

    @Test func headerCountsOneReportInTheSingular() throws {
        let reports = CrashReport.list(devicectl: try fixture("info-files-systemCrashLogs"))
        let result = try CrashCommands.listing(device(), reports: reports, process: "stacks", limit: 20, since: nil)
        #expect(result.text.split(separator: "\n")[1] == "1 report for stacks in the device crash logs")
    }

    @Test func reportDateIsISO8601InJSON() throws {
        let report = CrashReport(
            name: "Sample-2026-10-22-113539.ips", date: Date(timeIntervalSince1970: 1_792_694_139), bugType: "309", size: nil)
        #expect(try JSONValue(encoding: report)["date"] == "2026-10-22T18:35:39Z")
    }

    @Test func decodeReadsISO8601Dates() throws {
        let report = CrashReport(
            name: "Sample-2026-10-22-113539.ips", date: Date(timeIntervalSince1970: 1_792_694_139), bugType: "309", size: nil)
        #expect(try JSONValue(encoding: report).decode(CrashReport.self) == report)
    }

    @Test func sinceRejectsTextThatIsNotATime() {
        let error = #expect(throws: DeviceLoopError.self) { try CrashCommands.time("yesterday") }
        #expect(error?.code == .badArguments)
    }
}

@Suite struct ParityCrashCheckTests {
    private let launchedAt = Date(timeIntervalSince1970: 1_000)

    private func report(_ name: String, at seconds: Double?) -> CrashReport {
        CrashReport(name: name, date: seconds.map { Date(timeIntervalSince1970: $0) }, bugType: "309", size: nil)
    }

    @Test func onlySignalsThatCreateACoreImageCountAsCrashes() {
        let trap: JSONValue = ["terminationResult": ["terminatingSignal": 5, "wasCoreDumpCreated": false]]
        let kill: JSONValue = ["terminationResult": ["terminatingSignal": 9, "wasCoreDumpCreated": false]]
        let exit: JSONValue = ["terminationResult": ["exitCode": 0]]
        #expect(CrashCommands.crashSignal(in: trap) == SIGTRAP)
        #expect(CrashCommands.crashSignal(in: kill) == nil)
        #expect(CrashCommands.crashSignal(in: exit) == nil)
    }

    @Test func blamesNoReportDatedBeforeLaunch() {
        let reports = [report("Sample-2026-11-08-130001.ips", at: 999), report("Sample-2026-11-08-130002.ips", at: nil)]
        #expect(CrashReport.blamed(reports, executable: "Sample", since: launchedAt, pid: nil, pidOf: { _ in nil }) == nil)
    }

    @Test func blamesTheOldestReportOfTheExecutableSinceLaunch() {
        let reports = [
            report("Sample-2026-11-08-130030.ips", at: 1_030), report("SampleKit-2026-11-08-130010.ips", at: 1_010),
            report("Sample-2026-11-08-130020.ips", at: 1_020),
        ]
        let blamed = CrashReport.blamed(reports, executable: "Sample", since: launchedAt, pid: nil, pidOf: { _ in nil })
        #expect(blamed?.name == "Sample-2026-11-08-130020.ips")
    }

    @Test func skipsAReportFromAnotherPid() {
        let reports = [report("Sample-2026-11-08-130010.ips", at: 1_010), report("Sample-2026-11-08-130040.ips", at: 1_040)]
        let pids = ["Sample-2026-11-08-130010.ips": Int32(41), "Sample-2026-11-08-130040.ips": 42]
        let blamed = CrashReport.blamed(reports, executable: "Sample", since: launchedAt, pid: 42, pidOf: { pids[$0.name] })
        #expect(blamed?.name == "Sample-2026-11-08-130040.ips")
    }

    @Test func executableIsTheBundleFolderNameWhenTheBundleIsNotOnThisMac() throws {
        let entry: JSONValue = [
            "bundleIdentifier": "com.example.sample", "url": "file:///private/var/containers/Bundle/Application/0000/Sample.app/",
        ]
        #expect(CrashCommands.executable(of: try #require(InstalledApp(devicectl: entry))) == "Sample")
    }

    @Test func executableComesFromInfoPlistWhenTheBundleIsOnThisMac() throws {
        let app = FileManager.default.temporaryDirectory.appending(path: "deviceloop-crash-\(UUID().uuidString)/Sample.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let info = ["CFBundleIdentifier": "com.example.sample", "CFBundleExecutable": "SampleBinary"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: app.appending(path: "Info.plist"))
        let entry: JSONValue = ["bundleIdentifier": "com.example.sample", "url": .string(app.absoluteString)]
        #expect(CrashCommands.executable(of: try #require(InstalledApp(devicectl: entry))) == "SampleBinary")
    }
}

@Suite struct ParityRoutingTests {
    @Test func shutDownSimulatorIsOffline() {
        let error = #expect(throws: DeviceLoopError.self) { try DeviceQueries.requireReady(simulator(bootState: "shutdown")) }
        #expect(error?.code == .deviceOffline)
        #expect(error?.fix == "Boot it: xcrun simctl boot 00000000-0000-0000-0000-000000000001")
    }

    @Test func missingCapabilityIsUnsupported() {
        let error = #expect(throws: DeviceLoopError.self) {
            try DeviceQueries.require(Capability.simulateLocation, "Simulated location", on: simulator())
        }
        #expect(error?.code == .unsupportedOnTarget)
        #expect(error?.detail == "missing capability \(Capability.simulateLocation)")
    }

    @Test func stateNamesTransportAndBlockers() {
        #expect(DeviceCommands.state(device()) == "wired")
        #expect(DeviceCommands.state(device(developerMode: false)) == "wired, developer mode off")
        #expect(DeviceCommands.state(simulator()) == "booted")
    }

    @Test func rejectsOutOfRangeLocation() async {
        let error = await #expect(throws: DeviceLoopError.self) {
            try await SettingsCommands.location(simulator(capabilities: [Capability.simulateLocation]), latitude: 91, longitude: 0)
        }
        #expect(error?.code == .badArguments)
    }

    @Test func locationResultsSayThePreviousLocationIsUnknown() {
        let set = SettingsCommands.locationResult(simulator(), latitude: 37.3349, longitude: -122.009)
        let cleared = SettingsCommands.locationResult(simulator(), latitude: nil, longitude: nil)
        for result in [set, cleared] {
            #expect(result.json["previousKnown"]?.bool == false)
            #expect(result.text.hasSuffix("\nPrevious simulated location unknown: devicectl cannot read it"))
        }
    }

    @Test func clearSaysItRemovesALocationAnotherToolSet() {
        let cleared = SettingsCommands.locationResult(simulator(), latitude: nil, longitude: nil)
        #expect(cleared.text.contains("\nLocation cleared, including any simulated location another tool set\n"))
        #expect(cleared.json["cleared"]?.bool == true)
    }

    @Test func pasteboardCopySaysThePreviousContentsWereNotSaved() {
        let result = SettingsCommands.pasteboardCopyResult(simulator(), text: "hello")
        #expect(result.json["previousSaved"]?.bool == false)
        #expect(result.text.hasSuffix("\nCopied 5 characters to the pasteboard, replacing its contents without saving them"))
    }

    @Test func pasteboardArgumentsNeverSyncWithTheHost() {
        let target = simulator()
        let copy = SettingsCommands.pasteboardCopyArguments(target, file: URL(filePath: "/tmp/text.txt"))
        let paste = SettingsCommands.pasteboardPasteArguments(target)
        #expect(copy == ["device", "pasteboard", "copy", "-d", target.udid, "--file", "/tmp/text.txt"])
        #expect(paste == ["device", "pasteboard", "paste", "-d", target.udid])
        #expect(!(copy + paste).contains { $0.contains("sync") || $0.contains("transfer") })
    }

    @Test func rejectsUnknownOrientation() async {
        let error = await #expect(throws: DeviceLoopError.self) {
            try await SettingsCommands.orientation(simulator(capabilities: [Capability.orientation]), value: "sideways")
        }
        #expect(error?.code == .badArguments)
    }

    @Test func rejectsCrashNamesOutsideTheLogFolder() async {
        let error = await #expect(throws: DeviceLoopError.self) {
            try await CrashCommands.pull(simulator(), name: "../../.zshrc", to: nil)
        }
        #expect(error?.code == .badArguments)
    }

    @Test func reportNamesAreRelativePathsWithoutOptionLikeParts() throws {
        try Validate.reportName("Retired/Sample-2026-10-01-080000.ips")
        for name in ["", "/etc/hosts", "-h", "Retired/--help", "Retired//x.ips", ".hidden.ips"] {
            #expect(throws: DeviceLoopError.self) { try Validate.reportName(name) }
        }
    }

    @Test func rejectsBundleIDsThatLookLikeOptions() async throws {
        try Validate.bundleID("com.example.sample-app_2")
        let error = await #expect(throws: DeviceLoopError.self) {
            try await AppCommands.terminate(simulator(), bundleID: "--all")
        }
        #expect(error?.code == .badArguments)
    }
}

@Suite struct ParityCapabilityTests {
    let targets: [Target]

    init() throws {
        targets = (try fixture("list-devices")["devices"]?.array ?? []).compactMap(Target.init(devicectl:))
    }

    func capability(
        _ name: String, on targetName: String, change: (inout Target) -> Void = { _ in }
    ) throws -> CapabilityStatus {
        var target = try #require(targets.first { $0.name == targetName })
        change(&target)
        return try #require(DeviceCommands.capabilities(target, team: "ABCDE12345").first { $0.name == name })
    }

    @Test func iOS18DeviceHasAppearanceButNotTextSize() throws {
        #expect(try capability("appearance", on: "Test iPhone 13 Pro").status == .available)
        let textSize = try capability("text size and contrast", on: "Test iPhone 13 Pro")
        #expect(textSize.status == .unavailable)
        #expect(textSize.reason?.contains("customizeappearancesettings") == true)
    }

    @Test func networkDeviceVideoNeedsUSB() throws {
        let video = try capability("video", on: "Test iPhone 17 Pro Max")
        #expect(video.status == .unavailable)
        #expect(video.reason?.contains("USB") == true)
    }

    @Test func bootedSimulatorHasVideoButNoLockState() throws {
        #expect(try capability("video", on: "iPhone Duo").status == .available)
        #expect(try capability("lock state", on: "iPhone Duo").status == .unavailable)
    }

    @Test func developerModeOffDeviceNeedsOwnerActionForTheRunner() throws {
        let runner = try capability("ui runner", on: "Test iPhone 15 Pro Max") { $0.developerModeEnabled = false }
        #expect(runner.status == .needsOwnerAction)
        #expect(runner.reason == "Developer Mode is off")
    }

    @Test func readyDeviceRunnerIsUnknownBecauseOfThePasscodePrompt() throws {
        #expect(try capability("ui runner", on: "Test iPhone 15 Pro Max").status == .unknown)
    }

    @Test func postureIsUnavailableEverywhere() {
        let postures = targets.map { DeviceCommands.capabilities($0, team: nil).first { $0.name == "posture" }?.status }
        #expect(!postures.isEmpty)
        #expect(postures.allSatisfy { $0 == .unavailable })
    }
}

@Suite struct ParityInstallTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "deviceloop-install-\(UUID().uuidString)")

    @Test func readsIdentityFromInfoPlist() throws {
        let app = folder.appending(path: "Sample.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.sample", "CFBundleShortVersionString": "1.0", "CFBundleVersion": "7",
            "CFBundleExecutable": "Sample", "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "MinimumOSVersion": "17.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: app.appending(path: "Info.plist"))
        let expected = AppArtifact(
            bundleID: "com.example.sample", version: "1.0", build: "7", executable: "Sample", platform: "iPhoneSimulator",
            minimumOSVersion: "17.0")
        #expect(try AppArtifact(bundle: app) == expected)
    }

    @Test func labelLeavesOutAMissingVersionOrBuild() {
        #expect(AppArtifact.label(version: "1.0", build: "7") == "1.0 (7)")
        #expect(AppArtifact.label(version: "1.0", build: nil) == "1.0")
        #expect(AppArtifact.label(version: nil, build: "7") == "(7)")
        #expect(AppArtifact.label(version: nil, build: nil) == "no version")
    }

    @Test func rejectsABuildForTheOtherKindOfTarget() {
        let deviceBuild = #expect(throws: DeviceLoopError.self) {
            try AppArtifact(bundleID: "com.example.sample", platform: "iPhoneOS").check(for: simulator())
        }
        let simulatorBuild = #expect(throws: DeviceLoopError.self) {
            try AppArtifact(bundleID: "com.example.sample", platform: "iPhoneSimulator").check(for: device())
        }
        #expect(deviceBuild?.code == .badArguments)
        #expect(simulatorBuild?.code == .badArguments)
    }

    @Test func rejectsAMinimumOSAboveTheTarget() throws {
        let error = #expect(throws: DeviceLoopError.self) {
            try AppArtifact(bundleID: "com.example.sample", minimumOSVersion: "27.2").check(for: simulator())
        }
        #expect(error?.code == .badArguments)
        try AppArtifact(bundleID: "com.example.sample", minimumOSVersion: "27.1.0").check(for: simulator())
    }

    @Test func skipsTheMinimumOSCheckWhenTheTargetVersionIsUnknown() throws {
        var target = simulator()
        target.osVersion = "unknown"
        try AppArtifact(bundleID: "com.example.sample", minimumOSVersion: "17.0").check(for: target)
    }

    @Test func readsSigningFromCodesign() {
        let samples: [(output: String, signing: String, team: String?)] = [
            ("Signature=adhoc\nTeamIdentifier=not set\n", "adhoc", nil),
            (
                "Authority=Apple Development: Jane Doe (ABCDE12345)\nAuthority=Apple Root CA\nTeamIdentifier=ABCDE12345\n",
                "Apple Development: Jane Doe (ABCDE12345)", "ABCDE12345"
            ),
            ("Sample.app: code object is not signed at all\n", "unsigned", nil),
        ]
        for sample in samples {
            var artifact = AppArtifact(bundleID: "com.example.sample")
            artifact.readSignature(codesign: sample.output)
            #expect(artifact.signing == sample.signing)
            #expect(artifact.team == sample.team)
        }
    }

    @Test func readsBundleIDsFromTheInstallResult() throws {
        #expect(InstalledApp.bundleIDs(installResult: try fixture("install-app")) == ["com.argmaxinc.deviceloop.host"])
    }

    @Test func failsWhenTheInstalledBuildDiffers() throws {
        let listed = InstalledApp.list(devicectl: try fixture("info-apps-bundle-id")).first
        try AppArtifact(bundleID: "com.argmaxinc.deviceloop.host", version: "1.0", build: "1").verify(installed: listed, on: simulator())
        let error = #expect(throws: DeviceLoopError.self) {
            try AppArtifact(bundleID: "com.argmaxinc.deviceloop.host", version: "1.0", build: "2").verify(
                installed: listed, on: simulator())
        }
        #expect(error?.code == .deviceError)
    }

    @Test func failsWhenNothingIsListedAfterInstall() {
        let error = #expect(throws: DeviceLoopError.self) {
            try AppArtifact(bundleID: "com.example.sample", version: "1.0", build: "1").verify(installed: nil, on: simulator())
        }
        #expect(error?.message.contains("lists nothing for com.example.sample") == true)
    }

    @Test func rejectsAnIPAWithSeveralApps() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["First.app", "Second.app"] {
            let app = folder.appending(path: "source/Payload/\(name)")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: app.appending(path: "Info.plist"))
        }
        let ipa = folder.appending(path: "Several.ipa")
        #expect(try await Shell.run(["/usr/bin/ditto", "-c", "-k", folder.appending(path: "source").path, ipa.path]).succeeded)
        let error = await #expect(throws: DeviceLoopError.self) {
            try await AppCommands.unpack(ipa: ipa, into: folder.appending(path: "unpacked"))
        }
        #expect(error?.code == .badArguments)
    }

    /// traversal.ipa holds Payload/Sample.app/Info.plist and entries named ../, ../../, Payload/../../ and /tmp/.
    @Test func keepsIPAEntriesInsideTheExtractionFolder() async throws {
        let ipa = try #require(Bundle.module.url(forResource: "Resources/ipa/traversal", withExtension: "ipa"))
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = try await AppCommands.unpack(ipa: ipa, into: folder.appending(path: "nested/unpacked"))
        #expect(app.lastPathComponent == "Sample.app")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["nested"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "nested").path) == ["unpacked"])
        #expect(!FileManager.default.fileExists(atPath: "/tmp/deviceloop-traversal-escaped.txt"))
    }
}

@Suite struct ParityCrashPullTests {
    let file = FileManager.default.temporaryDirectory.appending(path: "deviceloop-pull-\(UUID().uuidString).ips")

    private func sample() throws -> Data {
        try Data(contentsOf: try #require(Bundle.module.url(forResource: "Resources/crash/sample", withExtension: "ips")))
    }

    @Test func pullReportsHeaderFieldsAndThePid() throws {
        let result = try CrashCommands.store(
            sample(), name: "Sample-2026-10-22-113539.ips", source: "systemCrashLogs", target: device(), at: file, overwrite: false)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(result.json["bundleID"] == "com.example.Sample")
        #expect(result.json["appVersion"] == "2.3")
        #expect(result.json["buildVersion"] == "45")
        #expect(result.json["incidentID"] == "11111111-2222-3333-4444-555555555555")
        #expect(result.json["pid"] == 4321)
        #expect(result.json["source"] == "systemCrashLogs")
        #expect(result.json["udid"] == "00000000-F3D2A99B0DA7486F")
        #expect(result.json["symbolicated"] == false)
    }

    @Test func pullReportsTheSha256OfTheSavedFile() throws {
        let result = try CrashCommands.store(
            sample(), name: "Sample-2026-10-22-113539.ips", source: "systemCrashLogs", target: device(), at: file, overwrite: false)
        defer { try? FileManager.default.removeItem(at: file) }
        let saved = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        #expect(result.json["sha256"]?.string == saved)
    }

    @Test func malformedReportStillPullsWithNullFields() throws {
        let result = try CrashCommands.store(
            Data("not a report".utf8), name: "Sample-2026-10-22-113539.ips", source: "/tmp/Sample-2026-10-22-113539.ips",
            target: simulator(), at: file, overwrite: false)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Data(contentsOf: file) == Data("not a report".utf8))
        for key in ["bundleID", "appVersion", "buildVersion", "incidentID", "pid"] {
            #expect(result.json[key] == .null)
        }
    }

    @Test func pullThatFindsNoReportKeepsTheExistingFile() async throws {
        try Data("kept".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await #expect(throws: DeviceLoopError.self) {
            try await CrashCommands.pull(simulator(), name: file.lastPathComponent, to: file.deletingLastPathComponent())
        }
        #expect(try Data(contentsOf: file) == Data("kept".utf8))
    }

    @Test func saveRefusesToReplaceADifferentFile() throws {
        try Data("kept".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try CrashCommands.save(Data("kept".utf8), to: file, overwrite: false)
        let error = #expect(throws: DeviceLoopError.self) { try CrashCommands.save(Data("new".utf8), to: file, overwrite: false) }
        #expect(error?.code == .badArguments)
        #expect(try Data(contentsOf: file) == Data("kept".utf8))
    }

    @Test func saveWithOverwriteReplacesAFile() throws {
        try Data("old".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try CrashCommands.save(Data("new".utf8), to: file, overwrite: true)
        #expect(try Data(contentsOf: file) == Data("new".utf8))
    }

    @Test func saveNeverReplacesADirectory() throws {
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: (any Error).self) { try CrashCommands.save(Data("new".utf8), to: file, overwrite: true) }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }
}

@Suite struct ParityContainerTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "deviceloop-container-\(UUID().uuidString)")

    private func makeContainer() throws {
        try FileManager.default.createDirectory(at: root.appending(path: "Documents/sub"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appending(path: "Documents/f.txt"))
    }

    @Test func containerPathsAreRelativeWithoutDotDotOrLeadingDash() throws {
        for path in ["Documents/f.txt", ".config", "Library/.hidden/x", "Documents/a-b"] {
            try Validate.containerPath(path)
        }
        for path in ["", "/etc/hosts", "../x", "Documents/../../x", "Documents/..", "-h", "Documents//f.txt", "Documents/", "./f"] {
            #expect(throws: DeviceLoopError.self) { try Validate.containerPath(path) }
        }
    }

    @Test func readsContainerAccessibleFromInfoApps() throws {
        let apps = InstalledApp.list(devicectl: try fixture("info-apps-all"))
        #expect(apps.first { $0.bundleID == "com.example.sample" }?.containerAccessible == true)
        #expect(apps.first { $0.bundleID == "com.example.store" }?.containerAccessible == false)
    }

    @Test func inaccessibleContainerIsUnsupportedWithTheSigningFix() throws {
        let store = try #require(InstalledApp.list(devicectl: try fixture("info-apps-all")).first { $0.bundleID == "com.example.store" })
        let error = #expect(throws: DeviceLoopError.self) { try ContainerCommands.checkAccessible(store, on: device()) }
        #expect(error?.code == .unsupportedOnTarget)
        #expect(error?.fix == "Install a development-signed build of the app.")
    }

    @Test func listsEntriesOfAnInfoFilesResult() throws {
        let files = ContainerFile.list(devicectl: try fixture("info-files-systemCrashLogs"))
        let folder = try #require(files.first { $0.path == "Retired" })
        #expect(folder.directory && folder.size == nil)
        let report = try #require(files.first { $0.path == "Retired/Sample-2026-10-01-080000.ips" })
        #expect(!report.directory && report.size != nil)
        #expect(files.map(\.path) == files.map(\.path).sorted())
    }

    @Test func deviceListingUnderAFolderHasPathsRelativeToTheContainer() {
        let result: JSONValue = [
            "files": [["name": "f.txt", "relativePath": "f.txt", "resources": ["isDirectory": false], "metadata": ["size": 3]]]
        ]
        #expect(ContainerFile.list(devicectl: result, under: "Documents").map(\.path) == ["Documents/f.txt"])
    }

    @Test func devicePushNeedsItsFolderListedAsAFolder() throws {
        let listing = ContainerFile.list(devicectl: try fixture("info-files-appDataContainer"))
        try ContainerCommands.checkPush("Documents/new.txt", listing: listing, bundleID: "com.example.app", overwrite: false)
        try ContainerCommands.checkPush("new.txt", listing: listing, bundleID: "com.example.app", overwrite: false)
        for path in ["Missing/new.txt", "Library/Caches/com.apple.dyld/DeviceLoopHost.dyld4/new.txt"] {
            let error = #expect(throws: DeviceLoopError.self) {
                try ContainerCommands.checkPush(path, listing: listing, bundleID: "com.example.app", overwrite: true)
            }
            #expect(error?.message == "Nothing at \(path) in the data container of com.example.app.")
        }
    }

    @Test func devicePushKeepsAListedFileWithoutOverwrite() throws {
        let listing = ContainerFile.list(devicectl: try fixture("info-files-appDataContainer"))
        let path = "Library/LanguageModeling/en-dynamic.lm/Info.plist"
        let error = #expect(throws: DeviceLoopError.self) {
            try ContainerCommands.checkPush(path, listing: listing, bundleID: "com.example.app", overwrite: false)
        }
        #expect(error?.fix?.contains("--overwrite") == true)
        try ContainerCommands.checkPush(path, listing: listing, bundleID: "com.example.app", overwrite: true)
    }

    @Test func simulatorListingHasPathsRelativeToTheContainer() throws {
        try makeContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let all = try ContainerCommands.listing(in: root, under: nil, bundleID: "com.example.app")
        #expect(all.map(\.path) == ["Documents", "Documents/f.txt", "Documents/sub"])
        #expect(all.map(\.directory) == [true, false, true])
        #expect(all[1].size == 5)
        let documents = try ContainerCommands.listing(in: root, under: "Documents", bundleID: "com.example.app")
        #expect(documents.map(\.path) == ["Documents/f.txt", "Documents/sub"])
    }

    @Test func listingAFileNamesItAsAFile() throws {
        try makeContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let error = #expect(throws: DeviceLoopError.self) {
            try ContainerCommands.listing(in: root, under: "Documents/f.txt", bundleID: "com.example.app")
        }
        #expect(error?.message == "Documents/f.txt is a file in the data container of com.example.app.")
    }

    @Test func linksThatLeaveTheContainerAreRefused() throws {
        try makeContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appending(path: "deviceloop-outside-\(UUID().uuidString)")
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Documents/file-link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "Documents/dir-link"), withDestinationURL: root.deletingLastPathComponent())
        for path in ["Documents/file-link", "Documents/dir-link", "Documents/dir-link/\(outside.lastPathComponent)"] {
            let error = #expect(throws: DeviceLoopError.self) { try ContainerCommands.resolve(path, in: root, bundleID: "com.example.app") }
            #expect(error?.message.contains("leads outside") == true)
        }
    }

    @Test func linksInsideTheContainerResolve() throws {
        try makeContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Docs"), withDestinationURL: root.appending(path: "Documents"))
        let file = try ContainerCommands.resolve("Docs/f.txt", in: root, bundleID: "com.example.app")
        #expect(try Data(contentsOf: file) == Data("hello".utf8))
    }

    @Test func pullRefusesAFolder() throws {
        try makeContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let error = #expect(throws: DeviceLoopError.self) {
            try ContainerCommands.readFile(root.appending(path: "Documents/sub"), path: "Documents/sub", bundleID: "com.example.app")
        }
        #expect(error?.code == .badArguments)
    }

    @Test func pushKeepsAnExistingFileWithoutOverwrite() throws {
        try makeContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        let error = #expect(throws: DeviceLoopError.self) {
            try ContainerCommands.write(Data("new".utf8), to: "Documents/f.txt", in: root, bundleID: "com.example.app", overwrite: false)
        }
        #expect(error?.fix?.contains("--overwrite") == true)
        #expect(try Data(contentsOf: root.appending(path: "Documents/f.txt")) == Data("hello".utf8))
    }

    @Test func pushWithOverwriteReplacesTheFile() throws {
        try makeContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        try ContainerCommands.write(Data("new".utf8), to: "Documents/f.txt", in: root, bundleID: "com.example.app", overwrite: true)
        #expect(try Data(contentsOf: root.appending(path: "Documents/f.txt")) == Data("new".utf8))
    }

    @Test func pushNeedsAnExistingFolder() throws {
        try makeContainer()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: DeviceLoopError.self) {
            try ContainerCommands.write(Data("new".utf8), to: "Missing/sub/f.txt", in: root, bundleID: "com.example.app", overwrite: false)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Missing").path))
    }
}

@Suite struct ParityScreenshotTests {
    let png = FileManager.default.temporaryDirectory.appending(path: "deviceloop-parity-\(UUID().uuidString).png")

    /// Writes a solid 300x600 PNG to `png`.
    func writePNG() throws {
        let context = try #require(
            CGContext(
                data: nil, width: 300, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 600))
        let destination = try #require(CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test func scalesToPointSizedJPEG() throws {
        try writePNG()
        defer { try? FileManager.default.removeItem(at: png) }

        let jpeg = try ScreenshotImage.jpeg(from: png, maxPixelSize: 200)
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        #expect(image.width == 100)
        #expect(image.height == 200)
    }

    @Test func screenshotPayloadHashesTheSavedPNG() throws {
        try writePNG()
        defer { try? FileManager.default.removeItem(at: png) }
        let result = try UICommands.screenshotResult(simulator(), path: png, displays: nil, scale: .native, capturedAt: Date())
        let digest = SHA256.hash(data: try Data(contentsOf: png)).map { String(format: "%02x", $0) }.joined()
        #expect(result.json["sha256"]?.string == digest)
    }

    @Test func screenshotWithoutDisplayInfoSaysTheScaleIsGuessed() throws {
        try writePNG()
        defer { try? FileManager.default.removeItem(at: png) }
        let result = try UICommands.screenshotResult(simulator(), path: png, displays: nil, scale: .points, capturedAt: Date())
        #expect(result.json["scaleSource"]?.string == "guessed")
        #expect(result.text.contains("scale guessed"))
    }

    @Test func guessesScaleFromScreenClass() {
        #expect(ScreenshotImage.guessedScale(pixelWidth: 750, pixelHeight: 1334, deviceType: "iPhone") == 2)
        #expect(ScreenshotImage.guessedScale(pixelWidth: 2532, pixelHeight: 1170, deviceType: "iPhone") == 3)
        #expect(ScreenshotImage.guessedScale(pixelWidth: 1640, pixelHeight: 2360, deviceType: "iPad") == 2)
    }

    @Test func tablePadsAllButTheLastColumn() {
        #expect(ParityText.table([["a", "bb", "c"], ["ccc", "d", "e"]]) == ["a    bb  c", "ccc  d   e"])
    }
}

/// Runs against a booted simulator: DEVICELOOP_TEST_SIMULATOR=<udid> xcrun swift test --filter ParityLiveTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEVICELOOP_TEST_SIMULATOR"] != nil), .serialized)
struct ParityLiveTests {
    let target: Target

    init() async throws {
        target = try await TargetResolver.resolve(ProcessInfo.processInfo.environment["DEVICELOOP_TEST_SIMULATOR"])
    }

    @Test func runningBundleIDsIncludeLaunchedApp() async throws {
        _ = try await AppCommands.launch(
            target, bundleID: "com.apple.Preferences", arguments: [], environment: [:], console: false, terminateExisting: false)
        #expect(try await AppCommands.runningBundleIDs(target).contains("com.apple.Preferences"))
        _ = try await AppCommands.terminate(target, bundleID: "com.apple.Preferences")
    }

    @Test func firstLaunchReportsLaunchedWithAParseableTime() async throws {
        try await stop("com.apple.Preferences")
        let result = try await launch("com.apple.Preferences", restart: false)
        #expect(result.json["outcome"]?.string == "launched")
        let launchedAt = try #require(result.json["launchedAt"]?.string)
        #expect(try Date(launchedAt, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) <= Date())
        try await stop("com.apple.Preferences")
    }

    @Test func secondLaunchWithoutRestartReportsActivated() async throws {
        let first = try await launch("com.apple.Preferences", restart: false)
        let second = try await launch("com.apple.Preferences", restart: false)
        #expect(second.json["outcome"]?.string == "activated")
        #expect(second.json["pid"] == first.json["pid"])
        #expect(second.json["previousPids"] == .array([try #require(first.json["pid"])]))
        try await stop("com.apple.Preferences")
    }

    @Test func activatedTextNamesDroppedArgumentsOnlyWhenSomeWerePassed() async throws {
        _ = try await launch("com.apple.Preferences", restart: false)
        let plain = try await launch("com.apple.Preferences", restart: false)
        let withArguments = try await AppCommands.launch(
            target, bundleID: "com.apple.Preferences", arguments: ["-probe"], environment: [:], console: false, terminateExisting: false)
        #expect(!plain.text.contains("did not apply"))
        #expect(withArguments.text.contains("so arguments and environment did not apply"))
        try await stop("com.apple.Preferences")
    }

    @Test func restartReportsRelaunchedWithANewPid() async throws {
        let first = try await launch("com.apple.Preferences", restart: false)
        let second = try await launch("com.apple.Preferences", restart: true)
        #expect(second.json["outcome"]?.string == "relaunched")
        #expect(second.json["pid"] != first.json["pid"])
        #expect(second.json["previousPids"] == .array([try #require(first.json["pid"])]))
        try await stop("com.apple.Preferences")
    }

    @Test func terminateLeavesNoPid() async throws {
        _ = try await launch("com.apple.Preferences", restart: false)
        _ = try await AppCommands.terminate(target, bundleID: "com.apple.Preferences")
        #expect(try await DeviceQueries.runningApps(target)["com.apple.Preferences"] == nil)
    }

    /// Installs a copy of the runner's host app under another bundle ID.
    @Test func uninstallLeavesTheAppAbsent() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "deviceloop-uninstall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try await RunnerBuild.products(for: target) { _ in }.appending(path: "Debug-iphonesimulator/DeviceLoopHost.app")
        let app = folder.appending(path: "UninstallProbe.app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: host, to: app)
        let plist = app.appending(path: "Info.plist")
        var info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        info["CFBundleIdentifier"] = "com.argmaxinc.deviceloop.uninstallprobe"
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: plist)

        _ = try await AppCommands.install(target, path: app)
        _ = try await AppCommands.uninstall(target, bundleID: "com.argmaxinc.deviceloop.uninstallprobe")
        #expect(try await DeviceQueries.installedApp(target, bundleID: "com.argmaxinc.deviceloop.uninstallprobe") == nil)
    }

    @Test func openReportsTheAppThatHandledTheURL() async throws {
        let result = try await AppCommands.openURL(target, url: "https://apple.com")
        #expect(result.json["handledBy"]?.string == "com.apple.mobilesafari")
        try await stop("com.apple.mobilesafari")
    }

    @Test func openWithoutAHandlerIsAppNotInstalled() async {
        let error = await #expect(throws: DeviceLoopError.self) {
            try await AppCommands.openURL(target, url: "deviceloop-no-handler://route")
        }
        #expect(error?.code == .appNotInstalled)
    }

    @Test func terminatingAnAppThatIsNotInstalledSaysSo() async {
        let error = await #expect(throws: DeviceLoopError.self) {
            try await AppCommands.terminate(target, bundleID: "com.example.notinstalled")
        }
        #expect(error?.code == .appNotInstalled)
    }

    @Test func pasteboardRoundTripIsByteIdentical() async throws {
        let text = "family \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}\nCafe\u{0301} a\u{0308}\u{0323}\n"
        _ = try await SettingsCommands.pasteboardCopy(target, text: text)
        let pasted = try await SettingsCommands.pasteboardPaste(target)
        #expect(pasted.json["text"]?.string.map { Array($0.utf8) } == Array(text.utf8))
    }

    @Test func screenshotReturnsPointSizedJPEG() async throws {
        let output = FileManager.default.temporaryDirectory.appending(path: "deviceloop-parity-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await UICommands.screenshot(target, scale: .points, output: output)
        let image = try #require(result.images.first)
        let source = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.mimeType == "image/jpeg")
        #expect(Double(decoded.width) == result.json["pointWidth"]?.number)
        #expect(result.files == [output])
    }

    private func launch(_ bundleID: String, restart: Bool) async throws -> CommandResult {
        try await AppCommands.launch(
            target, bundleID: bundleID, arguments: [], environment: [:], console: false, terminateExisting: restart)
    }

    private func stop(_ bundleID: String) async throws {
        do {
            _ = try await AppCommands.terminate(target, bundleID: bundleID)
        } catch let error as DeviceLoopError where error.code == .appNotRunning {}
    }
}
