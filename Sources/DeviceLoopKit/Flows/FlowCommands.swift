//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation

public enum FlowCommands {
    /// Reads a flow file. Throws bad_arguments when it cannot be read or is not JSON.
    public static func load(_ path: String) throws -> JSONValue {
        let url = URL(filePath: path).absoluteURL
        guard let contents = try? Data(contentsOf: url) else {
            throw DeviceLoopError(.badArguments, "Could not read \(url.path).", fix: "Pass the path of a flow JSON file.")
        }
        do {
            return try JSONValue(data: contents)
        } catch DecodingError.dataCorrupted(let context) {
            let reason = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            throw DeviceLoopError(.badArguments, "\(url.path) is not valid JSON.", fix: "Fix the JSON syntax in the file.", detail: reason)
        }
    }

    /// `deviceloop flow validate`: checks a flow without a device.
    public static func validate(_ json: JSONValue) throws -> CommandResult {
        let flow = try Flow(json)
        let text = [
            "flow \(flow.name) is valid: \(flow.setup.count) setup, \(flow.steps.count) steps, \(flow.cleanup.count) cleanup",
            "needs \(flow.requirements.joined(separator: ", "))",
        ]
        let payload: JSONValue = [
            "name": .string(flow.name),
            "setup": .number(Double(flow.setup.count)),
            "steps": .number(Double(flow.steps.count)),
            "cleanup": .number(Double(flow.cleanup.count)),
            "requirements": .array(flow.requirements.map(JSONValue.string)),
        ]
        return CommandResult(text: text.joined(separator: "\n"), json: payload)
    }

    /// Runs a flow on `target` over one runner session. Saves flow.json, result.json and screenshots in a new
    /// directory under `artifacts/flows`, named `runID` or a new ID. While a run records, both files have the flow's typed
    /// text as `[hidden]`. A flow that fails returns its result, it does not throw. A target that lacks a requirement, or
    /// a missing or mismatched app, throws before any input is sent.
    /// `app` and `timeoutMs` replace the flow's app.bundleID and timeoutMs before validation. Holds the target's flow
    /// lock from the first device query to the end, so other DeviceLoop UI commands and flow runs fail with device_busy.
    public static func run(
        _ target: Target, flow original: JSONValue, app: String? = nil, timeoutMs: Int? = nil, runID: String? = nil,
        progress: @escaping FlowEngine.Progress = { _ in }
    ) async throws -> CommandResult {
        let json = overriding(original, app: app, timeoutMs: timeoutMs)
        let flow = try Flow(json)
        let requirements = flow.requirements
        try check(requirements, on: target)
        let appPath = flow.appPath.map { URL(filePath: $0).absoluteURL }
        if let appPath {
            guard FileManager.default.fileExists(atPath: appPath.path) else {
                throw DeviceLoopError(
                    .badArguments, "appPath: nothing at \(appPath.path).", fix: "Set appPath to the .app or .ipa to install.")
            }
            try await check(appPath, against: flow.app, on: target)
        }
        let runID = runID ?? newRunID()
        return try await SessionLock.withFlowLock(runID, on: target) {
            var installed: InstalledApp?
            if appPath == nil {
                installed = try await identify(flow.app, on: target)
            }
            let session = try await UICommands.connect(target, insideFlow: true)
            if requirements.contains(where: { $0.hasSuffix(" button") }) {
                let info = try await session.client.get(RunnerWire.Path.info, as: InfoResult.self, timeout: 10)
                try check(requirements, on: target, buttons: info.hardwareButtons)
            }

            let directory = try newRunDirectory(runID)
            let flowFile = directory.appending(path: "flow.json")
            try saving(json, from: json).data(pretty: true).write(to: flowFile)
            if let appPath {
                do {
                    _ = try await AppCommands.uninstall(target, bundleID: flow.app.bundleID)
                } catch let error as DeviceLoopError where error.code == .appNotInstalled {}
                _ = try await AppCommands.install(target, path: appPath)
                installed = try await identify(flow.app, on: target)
            }
            // activate would start a stopped app with the arguments of the runner's last launch of it.
            let state = try await session.client.post(
                RunnerWire.Path.appState, AppRequest(app: flow.app.bundleID), as: AppStateResult.self)
            let mode = flow.reset != .none || state.state == "notRunning" ? "launch" : "activate"
            let start = AppRequest(app: flow.app.bundleID, mode: mode, arguments: flow.app.arguments, environment: flow.app.environment)
            _ = try await session.client.post(RunnerWire.Path.appLaunch, start, as: ActionResult.self)
            let executor = FlowExecutor(target: target, client: session.client, app: flow.app.bundleID, directory: directory)
            var result = await FlowEngine.run(flow, progress: progress) { try await executor.execute($0) }
            result.app = installed.map { FlowResult.App(bundleID: $0.bundleID, version: $0.version, build: $0.build) }
            let isolation: FlowResult.Isolation =
                switch flow.reset {
                    case .none: .none
                    case .relaunch: .processRestart
                    case .reinstall: .reinstalled
                }
            result.isolation = isolation
            result.notReset = (isolation == .reinstalled ? [] : ["app data"]) + ["keychain", "iCloud and server data", "permission grants"]
            result.screenshots = await executor.screenshots
            result.failureScreenshot = await executor.failureScreenshot

            let resultFile = directory.appending(path: "result.json")
            try saving(JSONValue(encoding: result), from: json).data(pretty: true).write(to: resultFile)
            let files =
                [flowFile, resultFile]
                + (result.screenshots + [result.failureScreenshot].compactMap { $0 }).map { directory.appending(path: $0) }
            let lines = (result.steps + result.cleanup).map { record in
                let error = record.error.map { ": \($0.code.rawValue) \($0.message)" } ?? ""
                return "\(record.phase.rawValue)[\(record.index)] \(record.kind) \(record.status.rawValue)\(error)"
            }
            let version = [installed?.version, installed?.build.map { "(\($0))" }].compactMap { $0 }
            let app = (["app", flow.app.bundleID] + version).joined(separator: " ") + ", isolation \(isolation.rawValue)"
            let text = [target.summary, "flow \(flow.name) \(result.status.rawValue)", app] + lines + files.map { "saved \($0.path)" }
            return try CommandResult(text: text.joined(separator: "\n"), payload: result, files: files)
        }
    }

    /// The text of each type step in `flow`, longest first.
    public static func typedText(_ flow: JSONValue) -> [String] {
        MCPActivityLog.redacted(flow: flow).typed.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    /// `json` with the typed text of `flow` as `[hidden]` while a run records, else `json`.
    static func saving(_ json: JSONValue, from flow: JSONValue) -> JSONValue {
        RunStore.current == nil ? json : RunRecorder.hide(RunRecorder.forms(hiding: typedText(flow)), in: json)
    }

    /// `json` with app.bundleID and timeoutMs replaced when given.
    static func overriding(_ json: JSONValue, app: String?, timeoutMs: Int?) -> JSONValue {
        guard var root = json.object else { return json }
        if let app, var fields = root["app"]?.object {
            fields["bundleID"] = .string(app)
            root["app"] = .object(fields)
        }
        if let timeoutMs { root["timeoutMs"] = .number(Double(timeoutMs)) }
        return .object(root)
    }

    /// Throws unsupported_on_target for the first of `requirements` that `target` lacks. Button requirements are
    /// checked only when `buttons`, the runner's hardware buttons, is given.
    static func check(_ requirements: [String], on target: Target, buttons: [String]? = nil) throws {
        for requirement in requirements {
            switch requirement {
                case "ui runner":
                    guard target.isDrivable else {
                        throw DeviceLoopError.unsupported("UI automation", on: target, alternatives: ["Use an iPhone or iPad"])
                    }
                case "install":
                    try DeviceQueries.require(Capability.installApp, "Installing apps", on: target)
                case "uninstall":
                    try DeviceQueries.require(Capability.uninstallApp, "Uninstalling apps", on: target)
                default:
                    let button = String(requirement.prefix { $0 != " " })
                    guard let buttons, !buttons.contains(button) else { continue }
                    var error = DeviceLoopError.unsupported("The \(button) button", on: target)
                    error.fix = "Use a target that has the \(button) button, or remove the steps and requires entry that need it."
                    error.detail = "hardware buttons: \(buttons.isEmpty ? "none" : buttons.joined(separator: ", "))"
                    throw error
            }
        }
    }

    /// The installed flow app. Throws app_not_installed when it is missing or differs from the pinned version or build.
    static func identify(_ app: Flow.App, on target: Target) async throws -> InstalledApp {
        guard let installed = try await DeviceQueries.installedApp(target, bundleID: app.bundleID) else {
            throw DeviceQueries.appNotInstalled(app.bundleID, on: target)
        }
        try checkPins(app, version: installed.version, build: installed.build, on: target)
        return installed
    }

    /// Reads the .app or .ipa at `appPath` on the Mac. Throws bad_arguments when its bundle ID is not `app.bundleID`
    /// or it differs from the version or build `app` pins.
    static func check(_ appPath: URL, against app: Flow.App, on target: Target) async throws {
        var unpacked: URL?
        defer { if let unpacked { try? FileManager.default.removeItem(at: unpacked) } }
        var bundle = appPath
        if appPath.pathExtension.lowercased() == "ipa" {
            let directory = FileManager.default.temporaryDirectory.appending(path: "deviceloop-ipa-\(UUID().uuidString)")
            unpacked = directory
            bundle = try await AppCommands.unpack(ipa: appPath, into: directory)
        }
        let artifact = try AppArtifact(bundle: bundle)
        guard artifact.bundleID == app.bundleID else {
            throw DeviceLoopError(
                .badArguments, "appPath: \(appPath.path) is \(artifact.bundleID), and the flow app is \(app.bundleID).",
                fix: "Set appPath to a build of \(app.bundleID), or change app.bundleID in the flow file.")
        }
        try checkPins(app, version: artifact.version, build: artifact.build, appPath: appPath, on: target)
    }

    /// Throws when `version` or `build` differs from the one `app` pins: app_not_installed for the installed app, and
    /// bad_arguments for the bundle at `appPath` they were read from.
    static func checkPins(_ app: Flow.App, version: String?, build: String?, appPath: URL? = nil, on target: Target) throws {
        if let pinned = app.version, pinned != version {
            throw pinMismatch(app.bundleID, "version", pinned: pinned, found: version, appPath: appPath, on: target)
        }
        if let pinned = app.build, pinned != build {
            throw pinMismatch(app.bundleID, "build", pinned: pinned, found: build, appPath: appPath, on: target)
        }
    }

    private static func pinMismatch(
        _ bundleID: String, _ field: String, pinned: String, found: String?, appPath: URL?, on target: Target
    ) -> DeviceLoopError {
        let place = appPath.map { "is at \($0.path)" } ?? "is installed on \(target.summary)"
        let fix = appPath == nil ? "Install \(field) \(pinned)" : "Point appPath at \(field) \(pinned)"
        return DeviceLoopError(
            appPath == nil ? .appNotInstalled : .badArguments,
            "\(bundleID) \(field) \(found ?? "unknown") \(place), the flow pins \(field) \(pinned).",
            fix: "\(fix), or change app.\(field) in the flow file.",
            device: target.name
        )
    }

    /// Why `matches`, every element the query found, fail `assertion`, or nil when it holds.
    /// `enabled` is the one match's enabled state, which /v1/find does not report.
    static func failure(of assertion: FlowAssertion, query: ElementQuery, matches: [FoundElement], enabled: Bool? = nil) -> DeviceLoopError?
    {
        let element = describe(query)
        let checkFix = "Check the failure screenshot in the flow run directory, or raise the step timeoutMs."
        if assertion == .gone {
            guard !matches.isEmpty else { return nil }
            return DeviceLoopError(
                .assertionFailed, "\(element) still matches \(matches.count) element\(matches.count == 1 ? "" : "s").", fix: checkFix)
        }
        guard let match = matches.first else {
            return DeviceLoopError(
                .elementNotFound, "No element matches \(element).",
                fix: "Check the query against deviceloop ui tree, or raise the step timeoutMs.")
        }
        guard matches.count == 1 else {
            return DeviceLoopError(
                .elementAmbiguous, "\(matches.count) elements match \(element).",
                fix: "Add a type, or select by an id only one element has.",
                detail: matches.prefix(5).map(UICommands.describe).joined(separator: "\n"))
        }
        switch assertion {
            case .exists, .gone:
                return nil
            case .hittable:
                guard match.hittable != true else { return nil }
                return DeviceLoopError(
                    .elementNotHittable, "\(element) is not hittable.", fix: "Scroll it into view or dismiss what covers it.")
            case .enabled:
                guard enabled != true else { return nil }
                return DeviceLoopError(.assertionFailed, "\(element) is not enabled.", fix: checkFix)
            case .label(let expected):
                return mismatch("label", match.label, expected, on: element, fix: checkFix)
            case .value(let expected):
                return mismatch("value", match.value, expected, on: element, fix: checkFix)
        }
    }

    private static func mismatch(_ field: String, _ actual: String?, _ expected: String, on element: String, fix: String)
        -> DeviceLoopError?
    {
        guard !ElementQuery.forms(of: expected).contains(actual ?? "") else { return nil }
        let has = actual.map { "\(field) \"\(UITree.escaped($0))\"" } ?? "no \(field)"
        return DeviceLoopError(.assertionFailed, "\(element) has \(has), expected \"\(UITree.escaped(expected))\".", fix: fix)
    }

    /// The query in the `ui` step grammar, for example `id=login type=button`.
    static func describe(_ query: ElementQuery) -> String {
        [
            query.id.map { "id=\($0)" }, query.label.map { "\"\($0)\"" }, query.labelContains.map { "label~=\($0)" },
            query.type.map { "type=\($0)" },
        ]
        .compactMap { $0 }.joined(separator: " ")
    }

    /// A new run ID such as `flow-20261108-131927-3f9a2c`.
    static func newRunID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "flow-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6).lowercased())"
    }

    /// A new 0700 directory `artifacts/flows/<runID>`.
    static func newRunDirectory(_ runID: String) throws -> URL {
        try Paths.ensureDirectory(Paths.artifacts.appending(path: "flows/\(runID)", directoryHint: .isDirectory))
    }
}

/// Runs flow steps over one runner session. Requests name the flow app, or the app a launch step started.
actor FlowExecutor {
    let target: Target
    let client: RunnerClient
    let directory: URL
    private var app: String
    private(set) var screenshots: [String] = []
    private(set) var failureScreenshot: String?

    init(target: Target, client: RunnerClient, app: String, directory: URL) {
        self.target = target
        self.client = client
        self.app = app
        self.directory = directory
    }

    /// Performs one step within its `timeoutMs`. The first step that throws also saves failure.png.
    func execute(_ step: FlowStep) async throws {
        do {
            try await perform(step)
        } catch {
            if failureScreenshot == nil, (try? await screenshot("failure.png")) != nil {
                failureScreenshot = "failure.png"
            }
            throw error
        }
    }

    private func perform(_ step: FlowStep) async throws {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(step.timeoutMs))
        let timeout = Double(step.timeoutMs) / 1000
        switch step.action {
            case .ui(let action):
                _ = try await UICommands.runFlowStep(action, app: app, client: client, timeoutMs: step.timeoutMs)
                if case .launch(let bundleID, _, _) = action { app = bundleID }
            case .assert(let query, let assertion):
                try await assert(query, assertion, until: deadline)
            case .settle(let quietMs):
                // Leaves the runner up to a second to report its own timeout before the HTTP timeout.
                let runnerMs = max(step.timeoutMs / 2, step.timeoutMs - 1000)
                let request = WaitStableRequest(app: app, quietMs: quietMs, timeoutMs: runnerMs)
                _ = try await client.post(RunnerWire.Path.waitStable, request, as: ActionResult.self, timeout: timeout)
            case .screenshot(let name):
                let file = "\(screenshots.count + 1)-\(name ?? "screenshot").png"
                try await screenshot(file)
                screenshots.append(file)
            case .alert(let button):
                _ = try await client.post(
                    RunnerWire.Path.alert, AlertActionRequest(button: button), as: ActionResult.self, timeout: timeout)
        }
    }

    /// Polls /v1/find until the query has exactly one match that satisfies `assertion`, or `deadline` passes.
    private func assert(_ query: ElementQuery, _ assertion: FlowAssertion, until deadline: ContinuousClock.Instant) async throws {
        let interval = Duration.milliseconds(200)
        var previousFailure: DeviceLoopError?
        while true {
            let started = ContinuousClock.now
            let failure: DeviceLoopError?
            do {
                failure = try await poll(query, assertion, until: deadline)
            } catch {
                // A poll cut off by the deadline reports what the previous poll saw.
                guard let previousFailure, ContinuousClock.now >= deadline else { throw error }
                throw previousFailure
            }
            guard let failure else { return }
            // Stops before a poll that would likely outlast the deadline.
            guard ContinuousClock.now + interval + started.duration(to: .now) < deadline else { throw failure }
            previousFailure = failure
            try await Task.sleep(for: interval)
        }
    }

    /// One /v1/find with all matches, and why they fail `assertion`, or nil when it holds.
    private func poll(_ query: ElementQuery, _ assertion: FlowAssertion, until deadline: ContinuousClock.Instant) async throws
        -> DeviceLoopError?
    {
        let request = FindRequest(app: app, query: query, all: true)
        let found = try await client.post(RunnerWire.Path.find, request, as: FindResult.self, timeout: seconds(until: deadline))
        var enabled: Bool?
        if assertion == .enabled, found.matches.count == 1 {
            enabled = try await isEnabled(query, until: deadline)
        }
        return FlowCommands.failure(of: assertion, query: query, matches: found.matches, enabled: enabled)
    }

    /// Reads enabled with a zero-timeout /v1/wait, because /v1/find does not report it.
    private func isEnabled(_ query: ElementQuery, until deadline: ContinuousClock.Instant) async throws -> Bool {
        let request = WaitRequest(app: app, query: query, until: "enabled", timeoutMs: 0)
        do {
            _ = try await client.post(RunnerWire.Path.wait, request, as: ActionResult.self, timeout: seconds(until: deadline))
            return true
        } catch let error as DeviceLoopError where error.code == .timeout {
            return false
        }
    }

    /// Saves a devicectl or simctl screenshot in the run directory, without the runner.
    private func screenshot(_ file: String) async throws {
        try await DeviceCommands.screenshotPNG(target, to: directory.appending(path: file))
    }

    private func seconds(until deadline: ContinuousClock.Instant) -> Double {
        max(0.001, ContinuousClock.now.duration(to: deadline) / .seconds(1))
    }
}
