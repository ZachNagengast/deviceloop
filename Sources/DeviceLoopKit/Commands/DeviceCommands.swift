//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import CryptoKit
import Foundation

public enum DeviceCommands {
    /// `deviceloop devices`: every simulator and device, ready ones first.
    public static func list(all: Bool) async throws -> CommandResult {
        try list(all: all, targets: try await Devicectl.listTargets(), selector: ProcessInfo.processInfo.environment["DEVICELOOP_DEVICE"])
    }

    /// The `devices` table of `targets`, with a header that names the target `selector` picks. `selector` is the value of
    /// `DEVICELOOP_DEVICE`.
    static func list(all: Bool, targets: [Target], selector: String?) throws -> CommandResult {
        let shown = targets.filter { all || ($0.isDrivable && $0.isReady) }
            .sorted { sortKey($0) < sortKey($1) }
        let readyCount = shown.filter(\.isReady).count
        var header = "\(readyCount) ready"
        if all {
            header += ", \(shown.count - readyCount) not ready"
        } else if targets.count > shown.count {
            header += ", \(targets.count - shown.count) more with --all"
        }
        var payload = ListPayload(devices: shown.map(TargetRow.init))
        if let selector = selector?.trimmingCharacters(in: .whitespaces), !selector.isEmpty {
            do {
                let selected = try TargetResolver.resolve(selector, in: targets)
                payload.defaultDevice = selected.udid
                header += ", DEVICELOOP_DEVICE picks \(selected.name)"
            } catch let error as DeviceLoopError {
                payload.defaultDeviceError = error.code.rawValue
                let matches = error.code == .deviceAmbiguous ? "matches several targets" : "matches no target"
                header += ", DEVICELOOP_DEVICE \"\(selector)\" \(matches)"
            }
        }
        let rows = shown.map { [$0.name, $0.kind.rawValue, "\($0.platform) \($0.osVersion)", state($0), $0.udid] }
        return try CommandResult(text: ([header] + ParityText.table(rows)).joined(separator: "\n"), payload: payload)
    }

    /// `deviceloop info`: model, OS, connection, lock state, screen, capabilities that matter.
    public static func info(_ target: Target) async throws -> CommandResult {
        try DeviceQueries.requireReady(target)
        async let displayInfo = optionalDisplays(target)
        async let lockState = optionalLockState(target)
        let displays = await displayInfo
        let lock = await lockState

        var lines = [target.summary, "model: \(target.model) (\(target.productType))", "udid: \(target.udid)", "state: \(state(target))"]
        if let passcodeRequired = lock?["passcodeRequired"]?.bool {
            lines.append("lock: " + (passcodeRequired ? "locked, unlock the device to drive it" : "unlocked"))
        }
        if let screen = displays?.visible {
            let points = "\(screen.pointWidth)x\(screen.pointHeight) pt @\(ParityText.number(screen.pointScale))x"
            let orientation = displays?.orientation.map { ", \($0)" } ?? ""
            lines.append("screen: \(points), \(screen.pixelWidth)x\(screen.pixelHeight) px\(orientation)")
        }
        if let all = displays?.displays, all.count > 1 {
            let names = all.map { "\($0.name) \($0.pixelWidth)x\($0.pixelHeight) px\($0.active ? "" : " (inactive)")" }
            lines.append("displays: " + names.joined(separator: ", "))
        }
        let capabilities = capabilities(target)
        let supported = capabilities.filter { $0.status == .available }.map(\.name)
        lines.append("supports: " + (supported.isEmpty ? "none" : supported.joined(separator: ", ")))
        let groups: [(CapabilityStatus.Status, String)] = [
            (.unavailable, "missing"), (.needsOwnerAction, "needs owner action"), (.unknown, "unknown"),
        ]
        for (status, label) in groups {
            let entries = capabilities.filter { $0.status == status }.map { "\($0.name) (\($0.reason ?? status.rawValue))" }
            if !entries.isEmpty { lines.append("\(label): " + entries.joined(separator: ", ")) }
        }

        let payload = InfoPayload(
            target: target,
            displays: displays?.displays ?? [],
            orientation: displays?.orientation,
            passcodeRequired: lock?["passcodeRequired"]?.bool,
            unlockedSinceBoot: lock?["unlockedSinceBoot"]?.bool,
            capabilities: capabilities
        )
        return try CommandResult(text: lines.joined(separator: "\n"), payload: payload)
    }

    /// `deviceloop view`: opens the Device Hub live screen so a person can watch.
    public static func view(_ target: Target) async throws -> CommandResult {
        try DeviceQueries.requireReady(target)
        // Simulators carry no screenViewingURL, but Device Hub opens them by identifier with the same URL.
        guard let url = target.screenViewingURL ?? (target.isSimulator ? "devices://device/open?id=\(target.identifier)" : nil) else {
            throw DeviceLoopError.unsupported(
                "Live screen viewing",
                on: target,
                capability: "com.apple.coredevice.feature.viewdevicescreen",
                alternatives: ["deviceloop screenshot"]
            )
        }
        let result = try await Shell.run(["/usr/bin/open", url], timeout: .seconds(30))
        guard result.succeeded else {
            throw DeviceLoopError(
                .internalError,
                "Could not open \(url).",
                fix: "Run `open '\(url)'` in Terminal to see why.",
                detail: result.stderrString,
                device: target.name
            )
        }
        return CommandResult(text: "\(target.summary)\nOpened Device Hub: \(url)", json: ["opened": .string(url)])
    }

    /// Full-resolution PNG through devicectl or simctl, used when the runner is not up.
    public static func screenshotPNG(_ target: Target, to path: URL) async throws {
        try await screenshotPNG(target, display: await optionalDisplays(target)?.visible, to: path)
    }

    /// Captures `display`, or the primary display when nil. Simulators fall back to `simctl io screenshot`.
    static func screenshotPNG(_ target: Target, display: DeviceDisplay?, to path: URL) async throws {
        try DeviceQueries.requireReady(target)
        let displayID = display?.uniqueID
        guard target.supports(Capability.screenshot) || target.isSimulator else {
            throw DeviceLoopError.unsupported("Screenshots", on: target, capability: Capability.screenshot)
        }
        if target.supports(Capability.screenshot) {
            let arguments =
                Devicectl.device(target, "capture", "screenshot") + ["--destination", path.path]
                + (displayID.map { ["--display-unique-id", $0] } ?? [])
            do {
                _ = try await Devicectl.run(arguments, target: target, timeout: .seconds(30))
                return
            } catch {
                guard target.isSimulator else { throw error }
            }
        }
        try await Simctl.run(["io", target.udid, "screenshot"] + (display.map { ["--display=\($0.name)"] } ?? []) + [path.path])
    }

    static func optionalDisplays(_ target: Target) async -> DeviceDisplays? {
        guard target.supports(Capability.displayInfo) else { return nil }
        return try? await DeviceQueries.displays(target)
    }

    private static func optionalLockState(_ target: Target) async -> JSONValue? {
        guard target.supports(Capability.lockState) else { return nil }
        return try? await Devicectl.run(Devicectl.device(target, "info", "lockState"), target: target)
    }

    private static func sortKey(_ target: Target) -> (Int, Int, String) {
        (target.isReady ? 0 : 1, target.kind == .device ? 0 : 1, target.name)
    }

    /// `booted` for simulators, the transport for connected devices, plus anything blocking use.
    static func state(_ target: Target) -> String {
        var parts: [String]
        if target.isSimulator {
            parts = [target.bootState ?? "unknown"]
        } else {
            parts = [target.connectionState == "connected" ? (target.transport ?? "connected") : target.connectionState]
            if !target.paired { parts.append("not paired") }
            if target.developerModeEnabled == false { parts.append("developer mode off") }
        }
        return parts.joined(separator: ", ")
    }

    /// Device settings only its owner can change: pairing and Developer Mode.
    static func ownerBlockers(_ target: Target) -> [String] {
        [(!target.paired, "not paired with this Mac"), (target.developerModeEnabled == false, "Developer Mode is off")]
            .filter(\.0).map(\.1)
    }

    /// Why `target` is not ready, empty when it is.
    static func notReadyReasons(_ target: Target) -> [String] {
        guard !target.isReady else { return [] }
        if target.isSimulator { return ["simulator is \(target.bootState ?? "not booted")"] }
        return ["device is \(target.connectionState)"] + ownerBlockers(target)
    }

    /// What `info` reports for `target`, from its devicectl record and the stored signing team.
    static func capabilities(_ target: Target, team: String? = DeviceLoopConfig.team()) -> [CapabilityStatus] {
        func feature(_ name: String, _ capability: String) -> CapabilityStatus {
            let feature = capability.replacing("com.apple.coredevice.feature.", with: "")
            guard target.supports(capability) else {
                let reason = "devicectl does not list \(feature) for this target"
                return CapabilityStatus(name, .unavailable, reason: reason, backend: "devicectl \(feature)")
            }
            return CapabilityStatus(name, .available, backend: "devicectl \(feature)")
        }

        var screenshot = feature("screenshot", Capability.screenshot)
        var video = CapabilityStatus("video", .available, backend: "AVFoundation USB screen capture")
        var terminate = feature("terminate", Capability.processControl)
        var runner = CapabilityStatus("ui runner", .available, backend: "XCUITest runner")
        if target.isSimulator {
            if screenshot.status != .available { screenshot = CapabilityStatus("screenshot", .available, backend: "simctl io screenshot") }
            video.backend = "simctl io recordVideo"
            terminate = CapabilityStatus("terminate", .available, backend: "simctl terminate")
        } else {
            if target.transport != "wired" {
                video.status = .unavailable
                video.reason = "device screen video needs a USB connection"
            }
            let blockers = ownerBlockers(target) + (team == nil ? ["no signing team"] : [])
            let passcode = "the device can ask for its passcode to allow UI Automation"
            runner.status = blockers.isEmpty ? .unknown : .needsOwnerAction
            runner.reason = blockers.isEmpty ? passcode : blockers.joined(separator: ", ")
        }

        return [
            screenshot,
            video,
            feature("location", Capability.simulateLocation),
            feature("orientation", Capability.orientation),
            feature("appearance", Capability.uiStyle),
            feature("text size and contrast", Capability.appearanceSettings),
            feature("pasteboard", Capability.pasteboard),
            feature("install", Capability.installApp),
            feature("launch", Capability.applicationControl),
            terminate,
            feature("lock state", Capability.lockState),
            runner,
            CapabilityStatus("hardware buttons", .unknown, reason: "only the UI runner can read them", backend: "XCUITest runner"),
            CapabilityStatus("posture", .unavailable, reason: "DeviceLoop has no backend for it"),
        ]
    }

    struct TargetRow: Encodable {
        var name: String
        var udid: String
        var identifier: String
        var kind: String
        var platform: String
        var osVersion: String
        var model: String
        var transport: String?
        var connectionState: String
        var paired: Bool
        var developerModeEnabled: Bool?
        var state: String
        var ready: Bool
        var notReadyReasons: [String]

        init(_ target: Target) {
            name = target.name
            udid = target.udid
            identifier = target.identifier
            kind = target.kind.rawValue
            platform = target.platform
            osVersion = target.osVersion
            model = target.model
            transport = target.transport
            connectionState = target.connectionState
            paired = target.paired
            developerModeEnabled = target.developerModeEnabled
            state = DeviceCommands.state(target)
            ready = target.isReady
            notReadyReasons = DeviceCommands.notReadyReasons(target)
        }
    }

    private struct ListPayload: Encodable {
        var devices: [TargetRow]
        /// The UDID of the target `DEVICELOOP_DEVICE` picks.
        var defaultDevice: String?
        /// The error code when `DEVICELOOP_DEVICE` matches no target or several.
        var defaultDeviceError: String?
    }

    private struct InfoPayload: Encodable {
        var target: Target
        var displays: [DeviceDisplay]
        var orientation: String?
        var passcodeRequired: Bool?
        var unlockedSinceBoot: Bool?
        var capabilities: [CapabilityStatus]
    }
}

/// One `info` capability: whether it works on a target, why not, and the tool behind it.
struct CapabilityStatus: Encodable, Equatable, Sendable {
    enum Status: String, Encodable, Sendable {
        case available
        case unavailable
        case needsOwnerAction
        case unknown
    }

    var name: String
    var status: Status
    var reason: String?
    var backend: String?

    init(_ name: String, _ status: Status, reason: String? = nil, backend: String? = nil) {
        self.name = name
        self.status = status
        self.reason = reason
        self.backend = backend
    }
}

public enum AppCommands {
    /// Installed apps, the user's only unless `includeSystem`, and only those whose name or bundle ID contains `matching`.
    public static func list(_ target: Target, includeSystem: Bool, matching: String? = nil) async throws -> CommandResult {
        try DeviceQueries.requireReady(target)
        let apps = try await DeviceQueries.apps(target).filter { app in
            (includeSystem || !app.systemApp)
                && matching.map { app.name.localizedCaseInsensitiveContains($0) || app.bundleID.localizedCaseInsensitiveContains($0) }
                    ?? true
        }
        let header =
            "\(apps.count) app\(apps.count == 1 ? "" : "s")" + (matching.map { " matching \"\($0)\"" } ?? "")
            + (includeSystem ? "" : " installed by the user, --system adds Apple apps")
        let rows = apps.map { [$0.bundleID, $0.name, [$0.version, $0.build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")] }
        return try CommandResult(
            text: ([target.summary, header] + ParityText.table(rows)).joined(separator: "\n"), payload: ["apps": apps])
    }

    /// `deviceloop apps --running`: running apps with pids, and the foreground ones when a UI runner is already up.
    public static func running(_ target: Target) async throws -> CommandResult {
        try DeviceQueries.requireReady(target)
        let running = try await DeviceQueries.runningApps(target)
        let foreground = try await UICommands.foreground(target, candidates: running.keys.sorted())
        return try runningReport(target, running: running, foreground: foreground)
    }

    static func runningReport(_ target: Target, running: [String: [Int32]], foreground: ForegroundReport) throws -> CommandResult {
        let apps = running.sorted { $0.key < $1.key }
        let header = "\(apps.count) running app\(apps.count == 1 ? "" : "s")"
        let rows = apps.map { [$0.key, $0.value.map(String.init).joined(separator: ", ")] }
        return CommandResult(
            text: ([target.summary, header] + ParityText.table(rows) + [foreground.line]).joined(separator: "\n"),
            json: [
                "running": .array(apps.map { ["bundleID": .string($0.key), "pids": .array($0.value.map { .number(Double($0)) })] }),
                "foreground": try JSONValue(encoding: foreground),
            ])
    }

    public static func install(_ target: Target, path: URL) async throws -> CommandResult {
        try DeviceQueries.require(Capability.installApp, "Installing apps", on: target)
        let path = path.absoluteURL
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw DeviceLoopError(.badArguments, "Nothing at \(path.path).", fix: "Pass the path to an .app bundle or an .ipa file.")
        }
        var unpacked: URL?
        defer { if let unpacked { try? FileManager.default.removeItem(at: unpacked) } }
        var app = path
        switch path.pathExtension.lowercased() {
            case "app":
                break
            case "ipa":
                let directory = FileManager.default.temporaryDirectory.appending(path: "deviceloop-ipa-\(UUID().uuidString)")
                unpacked = directory
                app = try await unpack(ipa: path, into: directory)
            default:
                throw DeviceLoopError(
                    .badArguments, "\(path.lastPathComponent) is not an .app bundle or an .ipa file.",
                    fix: "Pass the path to an .app bundle or an .ipa file.")
        }
        var artifact = try AppArtifact(bundle: app)
        try artifact.check(for: target)
        let codesign = try await Shell.run(["/usr/bin/codesign", "-dv", "--verbose=2", app.path], timeout: .seconds(60))
        artifact.readSignature(codesign: codesign.stderrString)

        let result = try await Devicectl.run(
            Devicectl.device(target, "install", "app") + [app.path], target: target, timeout: .seconds(600))
        let bundleIDs = InstalledApp.bundleIDs(installResult: result)
        try artifact.verify(installed: try await DeviceQueries.installedApp(target, bundleID: artifact.bundleID), on: target)

        let label = AppArtifact.label(version: artifact.version, build: artifact.build)
        let identity = artifact.version == nil && artifact.build == nil ? "" : " \(label)"
        let team = artifact.team.map { ", team \($0)" } ?? ""
        let text =
            "\(target.summary)\nInstalled \(artifact.bundleID)\(identity) from \(path.lastPathComponent), verified"
            + "\nsigning: \(artifact.signing ?? "unsigned")\(team)"
        var json = try JSONValue(encoding: artifact).object ?? [:]
        json["installed"] = .array(bundleIDs.map(JSONValue.string))
        json["path"] = .string(path.path)
        json["verified"] = true
        return CommandResult(text: text, json: .object(json))
    }

    /// Extracts `ipa` into `directory` and returns the one app bundle in its Payload folder.
    static func unpack(ipa: URL, into directory: URL) async throws -> URL {
        let unzip = try await Shell.run(["/usr/bin/ditto", "-x", "-k", ipa.path, directory.path], timeout: .seconds(300))
        guard unzip.succeeded else {
            throw DeviceLoopError(
                .badArguments, "Could not unzip \(ipa.lastPathComponent).",
                fix: "Pass an .ipa exported by Xcode, or the .app bundle itself.", detail: unzip.stderrString)
        }
        let payload = directory.appending(path: "Payload")
        let bundles = ((try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "app" }
        guard bundles.count == 1 else {
            throw DeviceLoopError(
                .badArguments,
                "\(ipa.lastPathComponent) has \(bundles.count) .app bundles in Payload, expected one.",
                fix: "Pass an .ipa exported for this target, or the .app bundle itself."
            )
        }
        return bundles[0]
    }

    public static func uninstall(_ target: Target, bundleID: String) async throws -> CommandResult {
        try Validate.bundleID(bundleID)
        try DeviceQueries.require(Capability.uninstallApp, "Uninstalling apps", on: target)
        guard let app = try await DeviceQueries.installedApp(target, bundleID: bundleID) else {
            throw DeviceQueries.appNotInstalled(bundleID, on: target)
        }
        _ = try await Devicectl.run(Devicectl.device(target, "uninstall", "app") + [bundleID], target: target, timeout: .seconds(120))
        if try await DeviceQueries.installedApp(target, bundleID: bundleID) != nil {
            throw DeviceLoopError(
                .deviceError,
                "\(target.summary) still lists \(bundleID) after uninstall.",
                fix: "Run `deviceloop uninstall \(bundleID)` again, or delete the app on the device.",
                device: target.name
            )
        }
        return CommandResult(text: "\(target.summary)\nUninstalled \(bundleID) (\(app.name))", json: ["uninstalled": .string(bundleID)])
    }

    /// With `console`, streams the app's stdout and stderr (and os_log via OS_ACTIVITY_DT_MODE) to `consoleOutput` until it
    /// exits, and saves each line after its host receive time to a log artifact. Ctrl-C terminates the app. Throws
    /// `app_crashed` when the app ends by a crash signal and its report appears. Compares the app's pids before and after to
    /// report `launched`, `activated` or `relaunched`.
    public static func launch(
        _ target: Target,
        bundleID: String,
        arguments: [String],
        environment: [String: String],
        console: Bool,
        terminateExisting: Bool,
        consoleOutput: FileHandle = .standardOutput
    ) async throws -> CommandResult {
        try Validate.bundleID(bundleID)
        try DeviceQueries.require(Capability.applicationControl, "Launching apps", on: target)
        var variables = environment
        if console, variables["OS_ACTIVITY_DT_MODE"] == nil {
            variables["OS_ACTIVITY_DT_MODE"] = "YES"
        }
        let before = try await DeviceQueries.runningApps(target)[bundleID] ?? []
        if console, !terminateExisting, !before.isEmpty {
            FileHandle.standardError.write(Data((consoleNotConnected(bundleID, pids: before) + "\n").utf8))
        }
        // devicectl fails to find the new pid (CoreDeviceError 10004) when --console meets --terminate-existing.
        if console, terminateExisting {
            do {
                _ = try await terminate(target, bundleID: bundleID)
            } catch let error as DeviceLoopError where error.code == .appNotRunning {}
        }
        let log = console ? try Paths.newArtifact("log-\(bundleID)", extension: "log") : nil
        let logFile = try log.map { url in
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            return try FileHandle(forWritingTo: url)
        }
        defer { try? logFile?.close() }
        let launchedAt = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        let result = try await start(
            target, bundleID: bundleID, arguments: arguments, environment: variables,
            console: logFile.map { file -> @Sendable (String) -> Void in { echo($0, to: consoleOutput, log: file) } },
            terminateExisting: terminateExisting && !console)
        let pid = processID(in: result)
        let outcome = launchOutcome(pid: pid, before: before)
        let line = outcomeLine(
            outcome, bundleID: bundleID, pid: pid, before: before, passedOptions: !arguments.isEmpty || !environment.isEmpty,
            console: console)
        var provenance: [String: JSONValue] = [
            "bundleID": .string(bundleID),
            "pid": pid.map { .number(Double($0)) } ?? .null,
            "outcome": .string(outcome),
            "previousPids": .array(before.map { .number(Double($0)) }),
            "launchedAt": .string(launchedAt),
            "arguments": .array(arguments.map(JSONValue.string)),
            "environmentKeys": .array(variables.keys.sorted().map(JSONValue.string)),
        ]
        guard let log else {
            let after = try await DeviceQueries.runningApps(target)[bundleID] ?? []
            guard let pid, after.contains(pid) else {
                throw DeviceLoopError(
                    .appNotRunning,
                    "\(bundleID) is not running on \(target.summary) after launch.",
                    fix: "Run `deviceloop launch \(bundleID) --console` to see its output, and `deviceloop crashes` for a crash report.",
                    detail: pid.map { "devicectl reported pid \($0)" },
                    device: target.name
                )
            }
            return CommandResult(text: "\(target.summary)\n\(line)\nlaunchedAt \(launchedAt)", json: .object(provenance))
        }
        provenance["log"] = .string(log.path)
        var lines = [target.summary, line, "launchedAt \(launchedAt)", exitLine(bundleID, pid: pid, result: result)]
        if let note = try await CrashCommands.checkForCrash(
            target, bundleID: bundleID, result: result, launchedAt: launchedAt, exitedAt: Date(), log: log.path)
        {
            lines.append(note)
        }
        lines.append("saved \(log.path)")
        return CommandResult(text: lines.joined(separator: "\n"), json: consoleJSON(result, adding: provenance), files: [log])
    }

    /// Writes a console line to `output` and appends it to `log` after its host receive time.
    static func echo(_ line: String, to output: FileHandle, log: FileHandle) {
        output.write(Data((line + "\n").utf8))
        log.write(Data((stamped(line, at: Date()) + "\n").utf8))
    }

    /// The warning for `--console` on an app already running as `pids`, since devicectl connects a new process only.
    static func consoleNotConnected(_ bundleID: String, pids: [Int32]) -> String {
        "\(bundleID) is already running as pid \(pids.map(String.init).joined(separator: ", ")), so its output is not connected. "
            + "Add --restart to capture it."
    }

    /// `Launched <bundle ID>, pid N`, with the pids a relaunch replaced and what an activation left out.
    static func outcomeLine(
        _ outcome: String, bundleID: String, pid: Int32?, before: [Int32], passedOptions: Bool, console: Bool
    ) -> String {
        var line = "\(outcome.capitalized) \(bundleID)\(pid.map { ", pid \($0)" } ?? "")"
        switch outcome {
            case "relaunched": line += ", replacing pid \(before.map(String.init).joined(separator: ", "))"
            case "activated":
                line += ", already running"
                let skipped = [
                    passedOptions ? "arguments and environment did not apply" : nil, console ? "its output was not captured" : nil,
                ]
                .compactMap { $0 }
                if !skipped.isEmpty { line += ", so " + skipped.joined(separator: " and ") }
            default: break
        }
        return line
    }

    /// `line` after `time` in ISO 8601 UTC with milliseconds, the format of launchedAt.
    static func stamped(_ line: String, at time: Date) -> String {
        time.ISO8601Format(.init(includingFractionalSeconds: true)) + " " + line
    }

    /// `<bundle ID> (pid N) exited: <terminationResult fields>` from a `--console` launch result.
    static func exitLine(_ bundleID: String, pid: Int32?, result: JSONValue) -> String {
        let ending = (result["terminationResult"]?.object ?? [:]).sorted { $0.key < $1.key }
            .compactMap { key, value -> String? in
                if let number = value.number { return "\(key)=\(ParityText.number(number))" }
                if let string = value.string { return "\(key)=\(string)" }
                return value.bool == true ? key : nil
            }
        return "\(bundleID)\(pid.map { " (pid \($0))" } ?? "") exited" + (ending.isEmpty ? "" : ": " + ending.joined(separator: " "))
    }

    /// The `--console` result with `provenance` added and without the environment values devicectl echoes in launchOptions.
    static func consoleJSON(_ result: JSONValue, adding provenance: [String: JSONValue]) -> JSONValue {
        var json = (result.object ?? [:]).merging(provenance) { _, new in new }
        json["launchOptions"] = result["launchOptions"]?.object.map { .object($0.filter { $0.key != "environmentVariables" }) }
        return .object(json)
    }

    /// The app pid in a `devicectl device process launch` or `openURL` result.
    static func processID(in result: JSONValue) -> Int32? {
        result.value(at: "process.processIdentifier")?.number.map { Int32($0) }
    }

    /// `activated` when devicectl returned a pid that was already running, `relaunched` when other pids were.
    static func launchOutcome(pid: Int32?, before: [Int32]) -> String {
        if let pid, before.contains(pid) { return "activated" }
        return before.isEmpty ? "launched" : "relaunched"
    }

    /// Runs `devicectl device process launch` and returns its result. With a `console` line sink, returns after the app exits.
    static func start(
        _ target: Target,
        bundleID: String,
        arguments: [String],
        environment: [String: String],
        console: (@Sendable (String) -> Void)?,
        terminateExisting: Bool
    ) async throws -> JSONValue {
        let command = try launchCommand(
            target, bundleID: bundleID, environment: environment, console: console != nil, terminateExisting: terminateExisting)
        do {
            if let console {
                return try await Devicectl.runAttached(command, passthrough: arguments, target: target, lines: console) {
                    _ = try? await terminate(target, bundleID: bundleID)
                }
            }
            return try await Devicectl.runCapturing(command, passthrough: arguments, target: target).result
        } catch let error as DeviceLoopError where error.detail == "com.apple.dt.CoreDeviceError 10002" {
            if try await DeviceQueries.installedApp(target, bundleID: bundleID) == nil {
                throw DeviceQueries.appNotInstalled(bundleID, on: target)
            }
            throw error
        }
    }

    /// `devicectl device process launch` arguments, without the app arguments that go after `--`.
    static func launchCommand(
        _ target: Target, bundleID: String, environment: [String: String], console: Bool, terminateExisting: Bool
    ) throws -> [String] {
        try Validate.bundleID(bundleID)
        var command = Devicectl.device(target, "process", "launch")
        if !environment.isEmpty {
            let json = try JSONValue.object(environment.mapValues(JSONValue.string)).data()
            command += ["-e", String(decoding: json, as: UTF8.self)]
        }
        return command + (terminateExisting ? ["--terminate-existing"] : []) + (console ? ["--console"] : []) + [bundleID]
    }

    /// SIGKILL like `simctl terminate`, since foreground apps ignore SIGTERM. Simulators use simctl because
    /// devicectl cannot signal simulator pids (CoreDeviceError 10014).
    public static func terminate(_ target: Target, bundleID: String) async throws -> CommandResult {
        try Validate.bundleID(bundleID)
        try DeviceQueries.requireReady(target)
        if target.isSimulator {
            do {
                try await Simctl.run(["terminate", target.udid, bundleID])
            } catch let error as DeviceLoopError where (error.detail ?? "").contains("found nothing to terminate") {
                if try await DeviceQueries.installedApp(target, bundleID: bundleID) == nil {
                    throw DeviceQueries.appNotInstalled(bundleID, on: target)
                }
                throw appNotRunning(bundleID, on: target)
            }
            try await waitUntilStopped(bundleID, on: target)
            return CommandResult(text: "\(target.summary)\nTerminated \(bundleID)", json: ["terminated": .string(bundleID)])
        }
        try DeviceQueries.require(Capability.processControl, "Terminating apps", on: target)
        async let processes = Devicectl.run(Devicectl.device(target, "info", "processes"), target: target)
        guard let app = try await DeviceQueries.installedApp(target, bundleID: bundleID) else {
            throw DeviceQueries.appNotInstalled(bundleID, on: target)
        }
        let pids = RunningApps.match(processes: try await processes, apps: [app])[bundleID] ?? []
        guard !pids.isEmpty else { throw appNotRunning(bundleID, on: target) }
        for pid in pids {
            _ = try await Devicectl.run(
                Devicectl.device(target, "process", "terminate") + ["--pid", String(pid), "--kill"], target: target)
        }
        try await waitUntilStopped(bundleID, on: target)
        let text = "\(target.summary)\nTerminated \(bundleID) (pid \(pids.map(String.init).joined(separator: ", ")))"
        return CommandResult(text: text, json: ["terminated": .string(bundleID), "pids": .array(pids.map { .number(Double($0)) })])
    }

    /// Polls the running apps for up to 3 s and throws `action_outcome_unknown` while `bundleID` still has pids.
    private static func waitUntilStopped(_ bundleID: String, on target: Target) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while true {
            let pids = try await DeviceQueries.runningApps(target)[bundleID] ?? []
            if pids.isEmpty { return }
            guard ContinuousClock.now < deadline else {
                throw DeviceLoopError(
                    .actionOutcomeUnknown,
                    "\(bundleID) is still running on \(target.summary) 3 s after terminate.",
                    fix: "Run `deviceloop terminate \(bundleID)` again.",
                    detail: "pid \(pids.map(String.init).joined(separator: ", "))",
                    device: target.name
                )
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Names the app that owns the pid devicectl returns, or `unknown` when no running app has that pid.
    public static func openURL(_ target: Target, url: String) async throws -> CommandResult {
        let pid = try await open(target, url: url)
        let running = (try? await DeviceQueries.runningApps(target)) ?? [:]
        let handler = pid.flatMap { pid in running.first { $0.value.contains(pid) }?.key }
        let text = "\(target.summary)\nOpened \(url) in \(handler ?? "an unknown app")\(pid.map { ", pid \($0)" } ?? "")"
        return CommandResult(
            text: text,
            json: ["url": .string(url), "pid": pid.map { .number(Double($0)) } ?? .null, "handledBy": .string(handler ?? "unknown")])
    }

    /// Runs `devicectl device process openURL` and returns the pid devicectl reports for the handler.
    static func open(_ target: Target, url: String) async throws -> Int32? {
        try DeviceQueries.require(Capability.applicationControl, "Opening URLs", on: target)
        guard let scheme = URL(string: url)?.scheme else {
            throw DeviceLoopError(
                .badArguments, "\(url) is not a URL.", fix: "Pass a URL with a scheme, for example https://apple.com or myapp://route.")
        }
        do {
            return processID(in: try await Devicectl.run(Devicectl.device(target, "process", "openURL") + [url], target: target))
        } catch let error as DeviceLoopError where error.detail == "com.apple.dt.CoreDeviceError 10007" {
            throw DeviceLoopError(
                .appNotInstalled,
                "No app on \(target.summary) opens \(scheme): URLs.",
                fix: "Install the app that registers the \(scheme) scheme, or check the URL.",
                device: target.name
            )
        }
    }

    /// Bundle IDs of running user apps, for foreground detection.
    public static func runningBundleIDs(_ target: Target) async throws -> [String] {
        try DeviceQueries.requireReady(target)
        return try await DeviceQueries.runningApps(target).keys.sorted()
    }

    static func appNotRunning(_ bundleID: String, on target: Target) -> DeviceLoopError {
        DeviceLoopError(
            .appNotRunning,
            "\(bundleID) is not running on \(target.summary).",
            fix: "Launch it with `deviceloop launch \(bundleID)`.",
            device: target.name
        )
    }
}

public enum SettingsCommands {
    /// `latitude`/`longitude` set a location, both nil clears it.
    public static func location(_ target: Target, latitude: Double?, longitude: Double?) async throws -> CommandResult {
        try DeviceQueries.require(Capability.simulateLocation, "Simulated location", on: target)
        let arguments: [String]
        let requested: JSONValue
        switch (latitude, longitude) {
            case (nil, nil):
                arguments = Devicectl.device(target, "simulate", "location", "clear")
                requested = ["cleared": true]
            case (let latitude?, let longitude?):
                guard (-90 ... 90).contains(latitude), (-180 ... 180).contains(longitude) else {
                    throw DeviceLoopError(
                        .badArguments, "\(latitude),\(longitude) is not a coordinate.", fix: "Latitude is -90 to 90, longitude -180 to 180."
                    )
                }
                arguments =
                    Devicectl.device(target, "simulate", "location", "coordinate")
                    + ["--latitude=\(latitude)", "--longitude=\(longitude)"]
                requested = ["latitude": .number(latitude), "longitude": .number(longitude)]
            default:
                throw DeviceLoopError(
                    .badArguments, "Pass both latitude and longitude, or neither to clear the location.",
                    fix: "Example: deviceloop location 37.3349,-122.0090")
        }
        return try await ChangeJournal(udid: target.udid).record(
            field: "location", requested: requested, unreadable: "devicectl and simctl cannot read the simulated location."
        ) {
            _ = try await Devicectl.run(arguments, target: target)
            return locationResult(target, latitude: latitude, longitude: longitude)
        }
    }

    /// Result of setting `latitude`,`longitude`, or of clearing the location when both are nil.
    static func locationResult(_ target: Target, latitude: Double?, longitude: Double?) -> CommandResult {
        let previous = "Previous simulated location unknown: devicectl cannot read it"
        guard let latitude, let longitude else {
            return CommandResult(
                text: "\(target.summary)\nLocation cleared, including any simulated location another tool set\n\(previous)",
                json: ["cleared": true, "previousKnown": false]
            )
        }
        return CommandResult(
            text: "\(target.summary)\nLocation set to \(latitude),\(longitude)\n\(previous)",
            json: ["latitude": .number(latitude), "longitude": .number(longitude), "previousKnown": false]
        )
    }

    /// `mode` is `light` or `dark`. Nil reads the current appearance.
    public static func appearance(_ target: Target, mode: String?) async throws -> CommandResult {
        try DeviceQueries.require(Capability.uiStyle, "Appearance", on: target)
        guard let mode = mode?.lowercased() else {
            var result = try await Devicectl.run(Devicectl.device(target, "info", "appearance"), target: target)
            if case .object(var fields) = result {
                fields["deviceIdentifier"] = nil
                result = .object(fields)
            }
            var parts = ["appearance: \(result["userInterfaceStyle"]?.string ?? "unknown")"]
            if let textSize = result["textSize"]?.string { parts.append("text size \(textSize)") }
            for (key, label) in [("reduceMotion", "reduce motion"), ("reduceTransparency", "reduce transparency")] {
                if let enabled = result.value(at: "\(key).enabled")?.bool { parts.append("\(label) \(enabled ? "on" : "off")") }
            }
            if let contrast = result["increaseContrast"]?.bool { parts.append("increase contrast \(contrast ? "on" : "off")") }
            return CommandResult(text: "\(target.summary)\n" + parts.joined(separator: ", "), json: result)
        }
        guard ["light", "dark"].contains(mode) else {
            throw DeviceLoopError(
                .badArguments, "Appearance is light or dark, got \(mode).",
                fix: "Use light or dark, or omit it to read the current appearance.")
        }
        return try await ChangeJournal(udid: target.udid).record(
            field: "userInterfaceStyle", requested: .string(mode), source: "devicectl device info appearance",
            read: { try await readStyle(target) },
            dispatch: {
                let style = try await setStyle(target, mode)["userInterfaceStyle"]?.string ?? mode
                return CommandResult(text: "\(target.summary)\nAppearance set to \(style)", json: ["userInterfaceStyle": .string(style)])
            }
        )
    }

    /// `value` is `portrait`, `portraitUpsideDown`, `landscapeLeft` or `landscapeRight`. Nil reads it.
    /// Setting reads the orientation before and after and reports both.
    public static func orientation(_ target: Target, value: String?) async throws -> CommandResult {
        try DeviceQueries.require(Capability.orientation, "Orientation", on: target)
        let orientations = ["portrait", "portraitUpsideDown", "landscapeLeft", "landscapeRight"]
        guard let value else {
            let state = try await readOrientation(target)
            return CommandResult(
                text: "\(target.summary)\norientation: \(state.orientation)\(state.locked == true ? " (rotation lock on)" : "")",
                json: ["orientation": .string(state.orientation), "locked": state.locked.map(JSONValue.bool) ?? .null]
            )
        }
        guard let orientation = orientations.first(where: { $0.lowercased() == value.lowercased() }) else {
            throw DeviceLoopError(
                .badArguments, "Unknown orientation \(value).", fix: "Use one of: \(orientations.joined(separator: ", ")).")
        }
        return try await ChangeJournal(udid: target.udid).record(
            field: "orientation", requested: .string(orientation), source: "devicectl device orientation get",
            read: { try await orientationValue(target) },
            dispatch: {
                let previous = try await readOrientation(target)
                try await setOrientation(target, orientation)
                let observed = try await readOrientation(target)
                let verified = observed.orientation == orientation
                let line =
                    verified
                    ? "Orientation set to \(orientation), was \(previous.orientation)"
                    : "Orientation \(orientation) requested but the device reports \(observed.orientation), was \(previous.orientation)"
                return CommandResult(
                    text: "\(target.summary)\n\(line)",
                    json: [
                        "previous": .string(previous.orientation),
                        "requested": .string(orientation),
                        "observed": .string(observed.orientation),
                        "verified": .bool(verified),
                        "locked": observed.locked.map(JSONValue.bool) ?? .null,
                    ]
                )
            }
        )
    }

    private static func readOrientation(_ target: Target) async throws -> DeviceOrientation {
        DeviceOrientation(devicectl: try await Devicectl.run(Devicectl.device(target, "orientation", "get"), target: target))
    }

    static func readStyle(_ target: Target) async throws -> JSONValue? {
        try await Devicectl.run(Devicectl.device(target, "info", "appearance"), target: target)["userInterfaceStyle"]
    }

    static func orientationValue(_ target: Target) async throws -> JSONValue? {
        currentOrientation(try await Devicectl.run(Devicectl.device(target, "orientation", "get"), target: target)).map(JSONValue.string)
    }

    private static func setStyle(_ target: Target, _ mode: String) async throws -> JSONValue {
        try await Devicectl.run(Devicectl.device(target, "settings", "appearance") + ["--mode", mode], target: target)
    }

    private static func setOrientation(_ target: Target, _ orientation: String) async throws {
        _ = try await Devicectl.run(Devicectl.device(target, "orientation", "set") + [orientation], target: target)
    }

    /// Reads and sets `field` without journaling. Nil for fields DeviceLoop cannot set back.
    static func inverse(_ field: String, on target: Target) -> ChangeJournal.Inverse? {
        switch field {
            case "userInterfaceStyle":
                ChangeJournal.Inverse(
                    read: { try await readStyle(target) },
                    set: { _ = try await setStyle(target, StateCommands.text($0)) }
                )
            case "orientation":
                ChangeJournal.Inverse(
                    read: { try await orientationValue(target) },
                    set: { try await setOrientation(target, StateCommands.text($0)) }
                )
            default:
                nil
        }
    }

    /// The orientation `DeviceOrientation` reads from `devicectl device orientation get`, nil when unknown.
    static func currentOrientation(_ result: JSONValue) -> String? {
        let orientation = DeviceOrientation(devicectl: result).orientation
        return orientation == "unknown" ? nil : orientation
    }

    public static func pasteboardCopy(_ target: Target, text: String) async throws -> CommandResult {
        try DeviceQueries.require(Capability.pasteboard, "Pasteboard", on: target)
        let characters: JSONValue = ["characters": .number(Double(text.count))]
        return try await ChangeJournal(udid: target.udid).record(
            field: "pasteboard", requested: characters, unreadable: "DeviceLoop does not capture pasteboard contents."
        ) {
            let file = FileManager.default.temporaryDirectory.appending(path: "deviceloop-pasteboard-\(UUID().uuidString).txt")
            try Data(text.utf8).write(to: file, options: .atomic)
            defer { try? FileManager.default.removeItem(at: file) }
            _ = try await Devicectl.run(pasteboardCopyArguments(target, file: file), target: target)
            return pasteboardCopyResult(target, text: text)
        }
    }

    static func pasteboardCopyResult(_ target: Target, text: String) -> CommandResult {
        CommandResult(
            text: "\(target.summary)\nCopied \(text.count) characters to the pasteboard, replacing its contents without saving them",
            json: ["characters": .number(Double(text.count)), "previousSaved": false]
        )
    }

    static func pasteboardCopyArguments(_ target: Target, file: URL) -> [String] {
        Devicectl.device(target, "pasteboard", "copy") + ["--file", file.path]
    }

    static func pasteboardPasteArguments(_ target: Target) -> [String] {
        Devicectl.device(target, "pasteboard", "paste")
    }

    public static func pasteboardPaste(_ target: Target) async throws -> CommandResult {
        try DeviceQueries.require(Capability.pasteboard, "Pasteboard", on: target)
        let (result, stdout) = try await Devicectl.runCapturing(pasteboardPasteArguments(target), target: target)
        let text = String(decoding: stdout, as: UTF8.self)
        return CommandResult(
            text: "\(target.summary)\n\(text)",
            json: ["text": .string(text), "contentType": result["contentType"] ?? .null]
        )
    }
}

public enum CrashCommands {
    /// Reports dated before `since`, an ISO 8601 time such as launchedAt, are left out. Undated ones are kept and flagged.
    public static func list(_ target: Target, process: String?, limit: Int, since: String?) async throws -> CommandResult {
        if let since { _ = try time(since) }
        return try listing(target, reports: try await allReports(target), process: process, limit: limit, since: since)
    }

    /// The `crashes` result for `reports` read from `target`.
    static func listing(_ target: Target, reports: [CrashReport], process: String?, limit: Int, since: String?) throws -> CommandResult {
        let earliest = try since.map(time)
        let matching = CrashReport.select(reports, process: process, since: earliest)
        let shown = Array(matching.prefix(max(limit, 0)))
        let source = target.isSimulator ? "~/Library/Logs/DiagnosticReports" : "the device crash logs"
        var header = "\(matching.count) report\(matching.count == 1 ? "" : "s")"
        header += "\(process.map { " for \($0)" } ?? "")\(since.map { " since \($0)" } ?? "") in \(source)"
        if shown.count < matching.count { header += ", newest \(shown.count) shown" }
        let undated = matching.filter { $0.date == nil }.count
        if earliest != nil, undated > 0 { header += ", \(undated) undated kept" }
        let rows = shown.map { [$0.date.map(displayDate) ?? "undated", $0.kind, $0.name] }
        return try CommandResult(
            text: ([target.summary, header] + ParityText.table(rows)).joined(separator: "\n"), payload: ["reports": shown])
    }

    /// Copies report `name` into `directory`, or into the artifacts folder when nil.
    /// A different file already at the destination is replaced only with `overwrite`.
    public static func pull(_ target: Target, name: String, to directory: URL?, overwrite: Bool = false) async throws -> CommandResult {
        try Validate.reportName(name)
        try DeviceQueries.requireReady(target)
        let destination = try pullDestination(for: name, in: directory, artifacts: "crashes")

        let report: Data
        let source: String
        if target.isSimulator {
            let file = diagnosticReports.appending(path: name)
            guard let contents = try? Data(contentsOf: file), contents.range(of: Data(target.udid.utf8)) != nil else {
                throw DeviceLoopError(
                    .badArguments, "No report \(name) for \(target.summary).", fix: "Run `deviceloop crashes` for the names.")
            }
            report = contents
            source = file.path
        } else {
            try DeviceQueries.require(Capability.transferFiles, "Pulling crash logs", on: target)
            let download = FileManager.default.temporaryDirectory.appending(path: "deviceloop-crash-\(UUID().uuidString).ips")
            defer { try? FileManager.default.removeItem(at: download) }
            let arguments =
                Devicectl.device(target, "copy", "from")
                + ["--domain-type", "systemCrashLogs", "--source", name, "--destination", download.path]
            _ = try await Devicectl.run(arguments, target: target, timeout: .seconds(120))
            report = try Data(contentsOf: download)
            source = "systemCrashLogs"
        }
        return try store(report, name: name, source: source, target: target, at: destination, overwrite: overwrite)
    }

    /// Saves a pulled report and describes it with its sha256, `.ips` header fields and the pid from its body.
    /// Fields a malformed report lacks are null. Reports stay unsymbolicated.
    static func store(_ data: Data, name: String, source: String, target: Target, at destination: URL, overwrite: Bool) throws
        -> CommandResult
    {
        try save(data, to: destination, overwrite: overwrite)
        let report = CrashReport(name: name, contents: data, modified: nil)
        let header = CrashReport.header(of: data)
        let bundleID = header?["bundleID"]?.string
        let version = header?["app_version"]?.string
        let build = header?["build_version"]?.string
        let pid = CrashReport.body(of: data)?["pid"]?.number.map { Int($0) }
        let digest = sha256(data)
        let when = report.date.map { " at \(displayDate($0))" } ?? ""
        var lines = [target.summary, "\(report.process) \(report.kind)\(when), \(data.count) bytes"]
        if let bundleID {
            lines.append(
                bundleID + (version.map { " \($0)" } ?? "") + (build.map { " (\($0))" } ?? "") + (pid.map { ", pid \($0)" } ?? ""))
        }
        lines += ["sha256 \(digest)", "saved \(destination.path)"]
        let json: JSONValue = try [
            "report": JSONValue(encoding: report), "path": .string(destination.path), "sha256": .string(digest),
            "udid": .string(target.udid), "source": .string(source), "bundleID": bundleID.map(JSONValue.string) ?? .null,
            "appVersion": version.map(JSONValue.string) ?? .null, "buildVersion": build.map(JSONValue.string) ?? .null,
            "incidentID": header?["incident_id"]?.string.map(JSONValue.string) ?? .null, "pid": pid.map { .number(Double($0)) } ?? .null,
            "symbolicated": false,
        ]
        return CommandResult(text: lines.joined(separator: "\n"), json: json, files: [destination])
    }

    /// Seconds after an app exits that `checkForCrash` keeps looking for its report.
    static let reportWait: TimeInterval = 45

    /// The terminating signal in a `--console` result when its default action creates a core image, nil otherwise.
    static func crashSignal(in result: JSONValue) -> Int32? {
        guard let signal = result.value(at: "terminationResult.terminatingSignal")?.number.map({ Int32($0) }),
            [SIGQUIT, SIGILL, SIGTRAP, SIGABRT, SIGEMT, SIGFPE, SIGBUS, SIGSEGV, SIGSYS].contains(signal)
        else { return nil }
        return signal
    }

    /// When `result` shows a crash signal, polls until `reportWait` after `exitedAt` for the report `CrashReport.blamed`
    /// picks and throws `app_crashed` naming it. Returns a line saying none appeared, or nil when the app did not crash.
    static func checkForCrash(
        _ target: Target, bundleID: String, result: JSONValue, launchedAt: String, exitedAt: Date, log: String
    ) async throws -> String? {
        guard let signal = crashSignal(in: result), let app = try? await DeviceQueries.installedApp(target, bundleID: bundleID),
            let executable = executable(of: app)
        else { return nil }
        let pid = AppCommands.processID(in: result)
        let since = try time(launchedAt)
        while true {
            let reports = (try? await allReports(target)) ?? []
            if let report = CrashReport.blamed(
                reports, executable: executable, since: since, pid: pid, pidOf: { reportPID($0, on: target) })
            {
                throw DeviceLoopError(
                    .appCrashed,
                    "\(bundleID)\(pid.map { " (pid \($0))" } ?? "") crashed on \(target.summary) with signal \(signal), "
                        + "report \(report.name).",
                    fix: "Pull the report with `deviceloop crashes pull \(report.name)`.",
                    detail: "output saved in \(log)",
                    device: target.name
                )
            }
            guard Date() < exitedAt + reportWait else { break }
            try await Task.sleep(for: .seconds(1))
        }
        return "no crash report for \(executable) within \(Int(reportWait)) s, check later with: "
            + "deviceloop crashes --process \(executable) --since \(launchedAt)"
    }

    /// CFBundleExecutable when the installed bundle is on this Mac, as on a simulator, else the bundle folder name.
    static func executable(of app: InstalledApp) -> String? {
        guard let url = URL(string: app.url) else { return nil }
        return (try? AppArtifact(bundle: url))?.executable ?? url.deletingPathExtension().lastPathComponent
    }

    /// The pid in the body of a report on the Mac. Nil on a device, where reading the body needs a pull.
    private static func reportPID(_ report: CrashReport, on target: Target) -> Int32? {
        guard target.isSimulator, let data = try? Data(contentsOf: diagnosticReports.appending(path: report.name)) else { return nil }
        return CrashReport.body(of: data)?["pid"]?.number.map { Int32($0) }
    }

    /// An ISO 8601 time with or without fractional seconds, such as `2026-11-08T21:59:40.778Z`.
    static func time(_ text: String) throws -> Date {
        let parsed =
            (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle()))
        guard let parsed else {
            throw DeviceLoopError(
                .badArguments, "since takes an ISO 8601 time such as 2026-11-08T21:59:40.778Z, got \(text).",
                fix: "Pass the launchedAt that `deviceloop launch` prints.")
        }
        return parsed
    }

    /// The last path component of `name` in `directory`, or in `Paths.artifacts/<artifacts>` when nil, creating the folder.
    static func pullDestination(for name: String, in directory: URL?, artifacts: String) throws -> URL {
        let folder: URL
        if let directory {
            folder = directory.absoluteURL
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } else {
            folder = try Paths.ensureDirectory(Paths.artifacts.appending(path: artifacts, directoryHint: .isDirectory))
        }
        return folder.appending(path: (name as NSString).lastPathComponent)
    }

    /// The lowercase hex SHA-256 of `data`.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Writes `data` to `destination` unless the same bytes are already there. A different file is
    /// replaced only with `overwrite`, and a directory is never replaced.
    static func save(_ data: Data, to destination: URL, overwrite: Bool) throws {
        guard (try? Data(contentsOf: destination)) != data else { return }
        do {
            try data.write(to: destination, options: overwrite ? .atomic : .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            throw DeviceLoopError(
                .badArguments, "\(destination.path) already exists.", fix: "Move or rename the existing file, then pull again.")
        }
    }

    private static var diagnosticReports: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
    }

    /// Device: the `systemCrashLogs` file domain. Simulator: `.ips` files on the Mac that name its UDID.
    private static func allReports(_ target: Target) async throws -> [CrashReport] {
        try DeviceQueries.requireReady(target)
        guard target.isSimulator else {
            try DeviceQueries.require(Capability.listFiles, "Crash logs", on: target)
            let arguments = Devicectl.device(target, "info", "files") + ["--domain-type", "systemCrashLogs"]
            return CrashReport.list(devicectl: try await Devicectl.run(arguments, target: target))
        }
        let marker = Data(target.udid.utf8)
        let root = diagnosticReports
        let names = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []
        return names.filter { $0.hasSuffix(".ips") }.compactMap { name in
            let url = root.appending(path: name)
            guard let data = try? Data(contentsOf: url), data.range(of: marker) != nil else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return CrashReport(name: name, contents: data, modified: modified)
        }
    }

    private static func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

/// Text layout shared by the parity commands.
enum ParityText {
    /// Rows padded into columns two spaces apart. The last column is not padded.
    static func table(_ rows: [[String]]) -> [String] {
        guard let columns = rows.map(\.count).max() else { return [] }
        let widths = (0 ..< columns).map { column in rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { index, cell in
                index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
    }

    /// `3` for 3.0, `2.5` for 2.5.
    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}
