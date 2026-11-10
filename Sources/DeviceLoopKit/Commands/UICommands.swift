//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import CryptoKit
import DeviceLoopProtocol
import Foundation

public enum ScreenshotScale: String, Sendable, CaseIterable {
    /// Image pixels equal points, so coordinates read off the image can be tapped directly.
    case points
    case native
}

public enum UICommands {
    /// `deviceloop screenshot`: devicectl or simctl, so it works while the runner is busy.
    /// Saves the native PNG and returns the scaled image inline.
    public static func screenshot(_ target: Target, scale: ScreenshotScale, output: URL?) async throws -> CommandResult {
        try DeviceQueries.requireReady(target)
        let path: URL
        if let output {
            guard output.pathExtension.lowercased() == "png" else {
                throw DeviceLoopError(.badArguments, "Screenshots are saved as PNG.", fix: "Pass an output path ending in .png.")
            }
            path = output.absoluteURL
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        } else {
            path = try Paths.newArtifact("screenshot", extension: "png")
        }
        let displays = await DeviceCommands.optionalDisplays(target)
        let capturedAt = Date()
        try await DeviceCommands.screenshotPNG(target, display: displays?.visible, to: path)
        return try screenshotResult(target, path: path, displays: displays, scale: scale, capturedAt: capturedAt)
    }

    /// Result for the PNG saved at `path`. `capturedAt` is the host time the capture started.
    static func screenshotResult(
        _ target: Target, path: URL, displays: DeviceDisplays?, scale: ScreenshotScale, capturedAt: Date
    ) throws -> CommandResult {
        let display = displays?.visible
        let png = try Data(contentsOf: path)
        let pixels = try ScreenshotImage.pixelSize(of: path)
        let guessedScale = ScreenshotImage.guessedScale(pixelWidth: pixels.width, pixelHeight: pixels.height, deviceType: target.deviceType)
        let pointScale = display?.pointScale ?? guessedScale
        let points = (
            width: Int((Double(pixels.width) / pointScale).rounded()),
            height: Int((Double(pixels.height) / pointScale).rounded())
        )
        let native =
            "\(pixels.width)x\(pixels.height) px @\(ParityText.number(pointScale))x"
            + (display == nil ? " (scale guessed from the image size)" : "")
        let orientation = displays?.orientation.map { ", device orientation \($0)" } ?? ""
        let image: ImageAttachment
        let line: String
        switch scale {
            case .points:
                let jpeg = try ScreenshotImage.jpeg(from: path, maxPixelSize: max(points.width, points.height))
                image = ImageAttachment(data: jpeg, mimeType: "image/jpeg", path: path)
                line = "image \(points.width)x\(points.height) = screen points, tap coordinates are points. Native \(native)\(orientation)"
            case .native:
                image = ImageAttachment(data: png, mimeType: "image/png", path: path)
                line = "image \(native), divide by \(ParityText.number(pointScale)) for points\(orientation)"
        }
        let payload: JSONValue = [
            "path": .string(path.path),
            "capturedAt": .string(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(capturedAt)),
            "sha256": .string(SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()),
            "scale": .string(scale.rawValue),
            "scaleSource": .string(display == nil ? "guessed" : "displayInfo"),
            "pointScale": .number(pointScale),
            "pixelWidth": .number(Double(pixels.width)),
            "pixelHeight": .number(Double(pixels.height)),
            "pointWidth": .number(Double(points.width)),
            "pointHeight": .number(Double(points.height)),
            "deviceOrientation": displays?.orientation.map(JSONValue.string) ?? .null,
            "display": display.map { .string($0.name) } ?? .null,
        ]
        return CommandResult(text: "\(target.summary)\n\(line)\nsaved \(path.path)", json: payload, images: [image], files: [path])
    }

    /// `deviceloop ui tree`: compact ui-tree/1 text with refs, system alerts first.
    public static func tree(_ target: Target, app: String?, frames: Bool, maxRows: Int?, screenshot: Bool) async throws -> CommandResult {
        if let maxRows, maxRows < 1 {
            throw DeviceLoopError(.badArguments, "The row limit must be 1 or more, got \(maxRows).", fix: "Pass a positive number of rows.")
        }
        let session = try await connect(target, focusing: app)
        let tree = try await session.client.post(RunnerWire.Path.tree, TreeRequest(app: app), as: TreeResult.self)
        let rendered = UITree.render(tree, frames: frames, maxRows: maxRows)
        let shot = try await screenshot ? Self.screenshot(target, scale: .points, output: nil) : nil
        let json = try JSONValue(encoding: tree)
        return CommandResult(
            text: "\(target.summary)\n\(rendered.text)", json: json, images: shot?.images ?? [], files: shot?.files ?? [])
    }

    /// Runs one step and returns its line and result JSON. A sleep runs on the host.
    public static func perform(_ step: UIStep, on target: Target, app: String?) async throws -> CommandResult {
        try step.validate()
        if case .sleep(let ms) = step {
            try await Task.sleep(for: .milliseconds(ms))
            return CommandResult(text: "\(target.summary)\nslept \(ms) ms", json: ["sleptMs": .number(Double(ms))])
        }
        let session = try await connect(target, focusing: app)
        let (line, reply) = try await run(step, app: app, client: session.client)
        return try actionResult(target, line: line, reply: reply, epoch: session.client.epoch)
    }

    /// The step's line and result JSON with the XCTest issues, timing, operation ID and session epoch.
    /// XCTest warnings add one `warning:` line to the text.
    static func actionResult(_ target: Target, line: String, reply: RunnerReply<ActionResult>, epoch: String?) throws -> CommandResult {
        var json = try JSONValue(encoding: reply.result)
        if case .object(var fields) = json {
            fields["issues"] = try JSONValue(encoding: reply.issues)
            fields["timing"] = try reply.timing.map { try JSONValue(encoding: $0) } ?? .null
            fields["operationID"] = reply.operationID.map(JSONValue.string) ?? .null
            fields["sessionEpoch"] = epoch.map(JSONValue.string) ?? .null
            json = .object(fields)
        }
        var lines = [target.summary, line]
        if !reply.issues.isEmpty {
            let messages = reply.issues.map { $0.message.split(whereSeparator: \.isNewline).joined(separator: " ") }
            lines.append("warning: XCTest: \(messages.joined(separator: " | "))")
        }
        return CommandResult(text: lines.joined(separator: "\n"), json: json)
    }

    /// `deviceloop ui do`: runs `steps` over one runner connection through the flow engine, and stops at the first
    /// step that does not pass. Each step passes or fails as it does in a flow. With no `app`, each step acts on the
    /// app in front. `screenshot` captures the screen after the steps, also when one fails.
    public static func perform(_ steps: [UIStep], on target: Target, app: String?, screenshot: Bool) async throws -> CommandResult {
        let timeoutMs = 120_000
        for step in steps {
            try step.validate()
            if case .sleep(let ms) = step, ms > timeoutMs {
                throw DeviceLoopError.usage("Sleep must be at most \(timeoutMs) ms, not \(ms).")
            }
        }
        let session = try await connect(target)
        let output = StepOutput()
        let flowSteps = steps.map { FlowStep(.ui($0), timeoutMs: timeoutMs) }
        let cleanup = screenshot ? [FlowStep(.screenshot(name: nil), timeoutMs: timeoutMs)] : []
        let result = await FlowEngine.run("ui do", timeoutMs: nil, setup: [], steps: flowSteps, cleanup: cleanup) { step in
            switch step.action {
                case .ui(let action):
                    if app == nil, request(for: action, app: nil) != nil { await focusForeground(target, client: session.client) }
                    await output.append(try await runFlowStep(action, app: app, client: session.client, timeoutMs: step.timeoutMs).line)
                case .screenshot:
                    await output.keep(try await Self.screenshot(target, scale: .points, output: nil))
                case .assert, .settle, .alert:
                    break
            }
        }
        var text = [target.summary] + doLines(result, completed: await output.lines)
        var json = try JSONValue(encoding: result)
        guard let shot = await output.screenshot else {
            return CommandResult(text: text.joined(separator: "\n"), json: json)
        }
        text += shot.text.split(separator: "\n").dropFirst().map(String.init)
        if case .object(var fields) = json {
            fields["screenshot"] = shot.json
            json = .object(fields)
        }
        return CommandResult(text: text.joined(separator: "\n"), json: json, images: shot.images, files: shot.files)
    }

    /// The lines of the steps that passed, then the step that stopped the run and a failed screenshot, with their errors.
    static func doLines(_ result: FlowResult, completed: [String]) -> [String] {
        var lines = completed
        if let stop = result.steps.first(where: { $0.status != .passed }) {
            let step = "step \(stop.index + 1)"
            lines.append(result.status == .cancelled ? "cancelled before \(step)" : "\(step) \(stop.kind) \(stop.status.rawValue)")
            if let error = stop.error { lines.append(error.rendered) }
        }
        if let error = result.cleanup.first?.error {
            lines += ["screenshot failed", error.rendered]
        }
        return lines
    }

    public static func find(_ target: Target, app: String?, query: ElementQuery, all: Bool) async throws -> CommandResult {
        try checkType(query)
        let session = try await connect(target, focusing: app)
        let found = try await session.client.post(RunnerWire.Path.find, FindRequest(app: app, query: query, all: all), as: FindResult.self)
        let lines = found.matches.map(describe)
        let header = found.matches.isEmpty ? "no match" : "\(found.matches.count) match\(found.matches.count == 1 ? "" : "es")"
        let json = try JSONValue(encoding: found)
        return CommandResult(text: ([target.summary, header] + lines).joined(separator: "\n"), json: json)
    }

    /// One line for an element: type, label, id, value, frame, and `not hittable` when known.
    static func describe(_ match: FoundElement) -> String {
        var parts = [match.type]
        if let label = match.label { parts.append("\"\(label)\"") }
        if let id = match.id { parts.append("id=\(id)") }
        if let value = match.value, !value.isEmpty { parts.append("value=\(value)") }
        if match.frame.count == 4 { parts.append("[" + match.frame.map { String(Int($0)) }.joined(separator: ",") + "]") }
        if match.hittable == false { parts.append("not hittable") }
        return parts.joined(separator: " ")
    }

    /// `until` is `exists`, `gone`, `hittable`, `enabled` or `stable`.
    public static func wait(
        _ target: Target, app: String?, query: ElementQuery?, until: String, timeoutMs: Int
    ) async throws -> CommandResult {
        guard ["exists", "gone", "hittable", "enabled", "stable"].contains(until) else {
            throw DeviceLoopError.usage("wait --until must be exists, gone, hittable, enabled or stable, got \(until).")
        }
        if until != "stable", query == nil {
            throw DeviceLoopError(
                .badArguments, "wait --until \(until) needs an element.", fix: "Pass --label, --id or --type, or use --until stable.")
        }
        try checkType(query)
        let session = try await connect(target, focusing: app)
        guard until != "stable", let query else {
            let request = WaitStableRequest(app: app, timeoutMs: timeoutMs)
            _ = try await session.client.post(RunnerWire.Path.waitStable, request, as: ActionResult.self)
            return CommandResult(text: "\(target.summary)\nscreen settled", json: ["settled": true])
        }
        let request = WaitRequest(app: app, query: query, until: until, timeoutMs: timeoutMs)
        _ = try await session.client.post(RunnerWire.Path.wait, request, as: ActionResult.self)
        return CommandResult(text: "\(target.summary)\nelement is \(until)", json: ["until": .string(until)])
    }

    /// Throws bad_arguments when `query` names a type that is not an XCUIElement.ElementType case.
    static func checkType(_ query: ElementQuery?) throws {
        guard let type = query?.type, !FlowExport.elementTypes.contains(type) else { return }
        throw DeviceLoopError(
            .badArguments, "\(type) is not an element type.", fix: "Use \(FlowExport.elementTypes.sorted().joined(separator: ", ")).")
    }

    /// Reads the current system alert, or taps one of its buttons when `button` or `action` is set.
    public static func alert(_ target: Target, button: String?, action: String?) async throws -> CommandResult {
        let session = try await connect(target, focusing: nil)
        if button == nil, action == nil {
            let alert = try await session.client.get(RunnerWire.Path.alert, as: AlertResult.self)
            guard alert.present else { return CommandResult(text: "\(target.summary)\nno alert", json: ["present": false]) }
            let text = [target.summary, alert.title ?? "alert", alert.message ?? "", "buttons: \(alert.buttons.joined(separator: ", "))"]
                .filter { !$0.isEmpty }.joined(separator: "\n")
            return CommandResult(text: text, json: try JSONValue(encoding: alert))
        }
        let reply: ActionResult
        do {
            reply = try await session.client.post(
                RunnerWire.Path.alert, AlertActionRequest(button: button, action: action), as: ActionResult.self)
        } catch var error as DeviceLoopError where error.code == .elementAmbiguous {
            error.fix = "Pick one of the listed labels and pass it exactly with --button."
            throw error
        } catch var error as DeviceLoopError where error.code == .elementNotFound {
            error.fix = "Run deviceloop ui alert to read the alert and its buttons."
            throw error
        }
        return alertTapped(target, reply: reply, button: button, action: action)
    }

    /// Names the button the runner tapped. A runner that does not report it falls back to `button`, then `action`.
    static func alertTapped(_ target: Target, reply: ActionResult, button: String?, action: String?) -> CommandResult {
        let label = reply.button ?? button
        let line = label.map { "tapped \"\($0)\"" } ?? "tapped \(action ?? "")"
        return CommandResult(text: "\(target.summary)\n\(line)", json: ["tapped": .string(label ?? action ?? "")])
    }

    /// Taps the inert `point` every `intervalMs` until `durationMs` passes or Ctrl-C, to keep the screen awake. Best effort.
    public static func keepAwake(
        _ target: Target, point: WirePoint, intervalMs: Int, durationMs: Int?, log: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        let options = try KeepAwakeOptions(point: point, intervalMs: intervalMs, durationMs: durationMs)
        try Task.checkCancellation()
        let session = try await connect(target)
        let request = TapRequest(target: ElementTarget(point: point), count: 1)
        log(
            "Best effort only. Verify that \(point.x),\(point.y) is inert in the current app. "
                + "Avoid both top and bottom edges and all side edges. Auto-Lock may still occur.")
        log("Sending one short tap every \(intervalMs / 1000)s to \(target.name). Ctrl-C to stop. Input errors stop immediately.")
        let interrupt = InterruptFlag()
        defer { interrupt.remove() }
        let taps = try await KeepAwakeLoop.run(options: options, interrupt: interrupt) {
            let screen = try await session.client.get(RunnerWire.Path.info, as: InfoResult.self, timeout: 10)
            try options.validateScreen(width: screen.screenWidth, height: screen.screenHeight)
            try Task.checkCancellation()
            _ = try await session.client.post(RunnerWire.Path.tap, request, as: ActionResult.self, timeout: 10)
        }
        return CommandResult(
            text: "\(target.summary)\ncompleted \(taps) tap requests. Continued wakefulness was not verified.",
            json: ["taps": .number(Double(taps)), "wakefulnessVerified": false]
        )
    }

    /// Connects to the runner, forwarding its startup messages (such as the passcode prompt) to stderr.
    /// Throws device_busy while a flow runs on `target`, unless this is that flow's connection.
    static func connect(_ target: Target, insideFlow: Bool = false) async throws -> RunnerSession {
        guard target.isDrivable else {
            throw DeviceLoopError.unsupported("UI automation", on: target, alternatives: ["Use an iPhone or iPad"])
        }
        if !insideFlow { try await SessionLock.checkNoFlow(on: target) }
        return try await RunnerSession.connect(target) { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }

    /// Connects, then points the runner at the foreground app when `app` is nil, best effort.
    /// Without that the runner keeps the app it last launched, or SpringBoard.
    static func connect(_ target: Target, focusing app: String?) async throws -> RunnerSession {
        let session = try await connect(target)
        if app == nil { await focusForeground(target, client: session.client) }
        return session
    }

    /// Points the runner at the foreground app, best effort.
    static func focusForeground(_ target: Target, client: RunnerClient) async {
        guard let running = try? await AppCommands.runningBundleIDs(target) else { return }
        _ = try? await client.post(RunnerWire.Path.appForeground, ForegroundRequest(candidates: running), as: ForegroundResult.self)
    }

    /// Asks a UI runner that is already running which of `candidates` are in the foreground. Does not start one.
    static func foreground(_ target: Target, candidates: [String]) async throws -> ForegroundReport {
        do {
            guard let session = try await RunnerSession.reattach(target, lockTimeout: .seconds(2)) else {
                return ForegroundReport(
                    known: false, reason: "No UI runner is running on \(target.name).",
                    fix: "Start one with `deviceloop runner start --device \(target.udid)`.")
            }
            func foregroundApps() async throws -> [String] {
                let request = ForegroundRequest(candidates: candidates)
                let result = try await session.client.post(RunnerWire.Path.appForeground, request, as: ForegroundResult.self, timeout: 30)
                return withoutSpringBoard(result.foreground)
            }
            var apps = try await foregroundApps()
            if apps.count > 1 {
                // The app a cold launch replaced still reports runningForeground for a moment, so ask once more.
                try await Task.sleep(for: .milliseconds(500))
                apps = try await foregroundApps()
            }
            return ForegroundReport(known: true, apps: apps, scope: "running apps via UI runner")
        } catch let error as DeviceLoopError {
            return ForegroundReport(known: false, reason: error.message, fix: error.fix)
        }
    }

    /// Drops SpringBoard when another app is listed.
    static func withoutSpringBoard(_ apps: [String]) -> [String] {
        let others = apps.filter { $0 != "com.apple.springboard" }
        return others.isEmpty ? apps : others
    }

    /// The runner path and request body the CLI sends for `step`. Nil for `sleep`, which runs on the host.
    static func request(for step: UIStep, app: String?) -> (path: String, body: any Encodable & Sendable)? {
        switch step {
            case .tap(let targetElement, let count, let holdMs):
                return (RunnerWire.Path.tap, TapRequest(app: app, target: targetElement, count: count, holdMs: holdMs))
            case .swipe(let direction, let on, let velocity):
                return (RunnerWire.Path.swipe, SwipeRequest(app: app, target: on, direction: direction, velocity: velocity))
            case .drag(let from, let to, let velocity, let holdMs):
                return (RunnerWire.Path.drag, DragRequest(app: app, from: from, to: to, velocity: velocity, holdMs: holdMs))
            case .type(let text, let into, let clear):
                return (RunnerWire.Path.type, TypeRequest(app: app, text: text, target: into, clear: clear))
            case .press(let button):
                return (RunnerWire.Path.button, ButtonRequest(name: button))
            case .launch(let bundleID, let arguments, let environment):
                return (RunnerWire.Path.appLaunch, AppRequest(app: bundleID, arguments: arguments, environment: environment))
            case .openURL(let url):
                return (RunnerWire.Path.openURL, OpenURLRequest(url: url))
            case .sleep:
                return nil
        }
    }

    /// Maps one step to a runner call and a human line, with the reply's XCTest issues, timing and operation ID.
    /// Nil app means the frontmost app. `timeout` is in seconds.
    static func run(_ step: UIStep, app: String?, client: RunnerClient, timeout: Double = 120) async throws
        -> (line: String, reply: RunnerReply<ActionResult>)
    {
        var reply = RunnerReply(result: ActionResult())
        if let request = request(for: step, app: app) {
            do {
                reply = try await client.postReply(request.path, request.body, as: ActionResult.self, timeout: timeout)
            } catch var error as DeviceLoopError where error.code == .elementNotFound {
                if let query = query(of: step) { error.message = "No element matches \(FlowCommands.describe(query))." }
                throw error
            } catch var error as DeviceLoopError where error.code == .elementAmbiguous && !error.alternatives.isEmpty {
                if let query = query(of: step) {
                    error.message = "More than one element matches \(FlowCommands.describe(query))."
                    error.fix = "Pass the id of the one you mean, or a ref from deviceloop ui tree."
                }
                throw error
            }
        }
        switch step {
            case .tap(_, let count, let holdMs):
                return (whereLine(holdMs != nil ? "held" : count == 2 ? "double tapped" : "tapped", reply.result), reply)
            case .swipe(let direction, _, _):
                return ("swiped \(direction)", reply)
            case .drag(let from, let to, _, _):
                return ("dragged \(Int(from.x)),\(Int(from.y)) to \(Int(to.x)),\(Int(to.y))", reply)
            case .type(let text, let into, let clear):
                guard into != nil else { return ("typed \"\(text)\"", reply) }
                let (line, result) = typed(text, clear: clear, result: reply.result)
                reply.result = result
                return (line, reply)
            case .press(let button):
                return ("pressed \(button)", reply)
            case .launch(let bundleID, _, _):
                return ("launched \(bundleID)", reply)
            case .openURL(let url):
                return ("opened \(url)", reply)
            case .sleep(let ms):
                try await Task.sleep(for: .milliseconds(ms))
                return ("slept \(ms) ms", reply)
        }
    }

    /// Runs a step of a flow or of `ui do` within `timeoutMs`. Throws timeout for a longer sleep, and text_mismatch when
    /// a type step into a field that is not secure does not read back the typed text.
    static func runFlowStep(_ step: UIStep, app: String?, client: RunnerClient, timeoutMs: Int) async throws
        -> (line: String, reply: RunnerReply<ActionResult>)
    {
        if case .sleep(let ms) = step, ms > timeoutMs {
            try await Task.sleep(for: .milliseconds(timeoutMs))
            throw DeviceLoopError(
                .timeout, "The \(ms) ms sleep is longer than the \(timeoutMs) ms left for this step.",
                fix: "Raise timeoutMs in the flow file or shorten the sleep.")
        }
        let outcome = try await run(step, app: app, client: client, timeout: Double(timeoutMs) / 1000)
        let result = outcome.reply.result
        guard case .type(let text, .some, _) = step, result.textVerified == false, result.elementType != "secureTextField" else {
            return outcome
        }
        guard result.readBack != nil else {
            throw DeviceLoopError(
                .textMismatch, "The field could not be read after typing, so the \(text.count) characters typed are not verified.",
                fix: "Check that the step types into a text field.")
        }
        throw DeviceLoopError(
            .textMismatch, "The field does not hold the \(text.count) characters typed.",
            fix: "Clear the field first, or check that the step types into the right field.")
    }

    /// Compares the read-back field text with `text` after a clear, or with the previous text followed by `text`.
    /// A secure field is not verified and its text is not echoed.
    static func typed(_ text: String, clear: Bool, result: ActionResult) -> (line: String, result: ActionResult) {
        var result = result
        if result.elementType == "secureTextField" {
            result.readBack = nil
            result.previousValue = nil
            result.textVerified = false
            return ("typed \(text.count) characters into a secure field, not verified", result)
        }
        let expected = (clear ? "" : result.previousValue ?? "") + text
        result.textVerified = result.readBack == expected
        guard let readBack = result.readBack else { return ("typed \"\(text)\", not verified: the field could not be read", result) }
        if readBack == expected { return ("typed \"\(text)\", field reads \"\(readBack)\"", result) }
        return ("typed \"\(text)\", not verified: field reads \"\(readBack)\", expected \"\(expected)\"", result)
    }

    /// The element query a tap, swipe or type step targets, or nil.
    private static func query(of step: UIStep) -> ElementQuery? {
        switch step {
            case .tap(let target, _, _): target.query
            case .swipe(_, let on, _): on?.query
            case .type(_, let into, _): into?.query
            default: nil
        }
    }

    private static func whereLine(_ verb: String, _ result: ActionResult) -> String {
        guard let point = result.point else { return verb }
        return "\(verb) at \(Int(point.x)),\(Int(point.y))"
    }
}

/// The lines and the screenshot that `ui do` steps produce.
private actor StepOutput {
    var lines: [String] = []
    var screenshot: CommandResult?

    func append(_ line: String) { lines.append(line) }

    func keep(_ shot: CommandResult) { screenshot = shot }
}

public enum RunnerCommands {
    /// Reads a retained receipt without starting a new runner or resubmitting input.
    public static func operation(_ target: Target, id: String, epoch: String) async throws -> CommandResult {
        guard UUID(uuidString: id) != nil, let expected = UUID(uuidString: epoch) else {
            throw DeviceLoopError.usage("Operation ID and epoch must be UUIDs")
        }
        guard let session = try await RunnerSession.reattach(target) else {
            throw DeviceLoopError(
                .actionOutcomeUnknown, "No runner is running on \(target.name), so the receipt is gone.",
                fix: RunnerClient.inspectStateFix, device: target.name)
        }
        guard session.client.epoch.flatMap(UUID.init(uuidString:)) == expected else {
            throw DeviceLoopError(
                .sessionMismatch, "Operation \(id) belongs to a different runner session.",
                fix: RunnerClient.inspectStateFix, device: target.name)
        }
        let result = try await session.client.get(RunnerWire.Path.operations + id, as: OperationStatusResult.self, timeout: 5)
        let lines = [target.summary] + operationLines(id, result: result)
        return CommandResult(text: lines.joined(separator: "\n"), json: try JSONValue(encoding: result))
    }

    /// The receipt's phase and timing, its error or HTTP status, and one line per XCTest issue.
    static func operationLines(_ id: String, result: OperationStatusResult) -> [String] {
        var phase = "operation \(id): \(result.operation.phase)"
        guard let status = result.responseStatus else { return [phase] }
        let envelope = result.responseJSON.flatMap { try? JSONDecoder().decode(WireResponse<WireEmpty>.self, from: Data($0.utf8)) }
        if let ms = envelope?.timing?.ms { phase += " after \(ms) ms" }
        var lines = [phase]
        if let failure = envelope?.error {
            lines.append("\(failure.code) (HTTP \(status)): \(failure.message)")
        } else if status >= 400 {
            lines.append("Runner returned an error (HTTP \(status)).")
        } else {
            lines.append("Execution finished. The effect is not verified.")
        }
        return lines + (envelope?.issues ?? []).map { "XCTest \($0.isFailure ? "failure" : "issue"): \($0.message)" }
    }

    /// Starts the runner now so the first UI command does not pay the build and launch cost.
    public static func start(_ target: Target) async throws -> CommandResult {
        let session = try await UICommands.connect(target)
        let health = try await session.health()
        let hostApp = session.hostApp
        return CommandResult(
            text: "\(target.summary)\nrunner ready on \(session.info.host):\(session.info.port) (xctest \(health.runnerBuild))"
                + (hostApp.map { "\nhost app \($0)" } ?? ""),
            json: [
                "host": .string(session.info.host), "port": .number(Double(session.info.port)),
                "hostApp": hostApp.map(JSONValue.string) ?? .null,
            ]
        )
    }

    public static func stop(_ target: Target) async throws -> CommandResult {
        guard try await RunnerSession.stopExisting(target) else {
            return CommandResult(text: "\(target.summary)\nno runner was running", json: ["stopped": false])
        }
        return CommandResult(text: "\(target.summary)\nrunner stopped", json: ["stopped": true])
    }

    public static func status(_ target: Target) async throws -> CommandResult {
        guard let session = try await RunnerSession.reattach(target) else {
            return CommandResult(text: "\(target.summary)\nrunner not running", json: ["running": false])
        }
        let health = try await session.health()
        let busy = health.busy ? "busy: \(health.currentOp ?? "")" : "idle"
        return CommandResult(
            text: "\(target.summary)\nrunning on \(session.info.host):\(session.info.port), up \(Int(health.uptimeS))s, \(busy)"
                + (session.info.runnerLog.map { "\nrunner log: \($0)" } ?? ""),
            json: try statusJSON(session, health: health)
        )
    }

    /// The health fields with `running`, the runner's host and port, its host app and its xcodebuild log.
    static func statusJSON(_ session: RunnerSession, health: HealthResult) throws -> JSONValue {
        guard case .object(var fields) = try JSONValue(encoding: health) else { return .null }
        fields["running"] = true
        fields["host"] = .string(session.info.host)
        fields["port"] = .number(Double(session.info.port))
        fields["hostApp"] = session.hostApp.map(JSONValue.string) ?? .null
        fields["runnerLog"] = session.info.runnerLog.map(JSONValue.string) ?? .null
        return .object(fields)
    }
}

/// The foreground apps among the running ones, or why they are unknown.
struct ForegroundReport: Encodable, Sendable, Equatable {
    var known: Bool
    /// Every candidate the runner reports in the foreground.
    var apps: [String]?
    var scope: String?
    var reason: String?
    var fix: String?

    var line: String {
        guard let apps, let scope else { return ["foreground: unknown.", reason, fix].compactMap { $0 }.joined(separator: " ") }
        return "foreground: \(apps.isEmpty ? "none" : apps.joined(separator: ", ")) (scope: \(scope))"
    }
}
