//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Synchronization

/// One MCP tool: its schema, annotations, and the Kit command it calls.
struct MCPTool: Sendable {
    var name: String
    var title: String
    var description: String
    var properties: [String: JSONValue]
    var required: [String] = []
    var readOnly: Bool
    var destructive = false
    var idempotent = false
    var openWorld = false
    /// Asks Claude Code to load the schema upfront instead of through tool search.
    var alwaysLoad = false
    /// Whether a returned result is sent with `isError` true.
    var failed: @Sendable (CommandResult) -> Bool = { _ in false }
    var run: @Sendable (MCPArguments) async throws -> CommandResult

    /// A tool that acts on one target, with the shared `device` argument. Calls are journaled in the target's active run.
    /// With `savingResult` false, the journal leaves out the result JSON. `transform` changes the result after it is journaled.
    static func device(
        name: String,
        title: String,
        description: String,
        properties: [String: JSONValue] = [:],
        required: [String] = [],
        readOnly: Bool,
        destructive: Bool = false,
        idempotent: Bool = false,
        openWorld: Bool = false,
        savingResult: Bool = true,
        transform: @escaping @Sendable (CommandResult) -> CommandResult = { $0 },
        failed: @escaping @Sendable (CommandResult) -> Bool = { _ in false },
        run: @escaping @Sendable (Target, MCPArguments) async throws -> CommandResult
    ) -> MCPTool {
        MCPTool(
            name: name,
            title: title,
            description: description,
            properties: properties.merging(["device": Param.device]) { own, _ in own },
            required: required,
            readOnly: readOnly,
            destructive: destructive,
            idempotent: idempotent,
            openWorld: openWorld,
            failed: failed
        ) { arguments in
            let target = try await arguments.target()
            let result = try await arguments.record(target.udid, savingResult: savingResult, failed: failed) {
                try await run(target, arguments)
            }
            return transform(result)
        }
    }

    var definition: JSONValue {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        var tool: [String: JSONValue] = [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": .object(schema),
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(idempotent),
                "openWorldHint": .bool(openWorld),
            ],
        ]
        if alwaysLoad { tool["_meta"] = ["anthropic/alwaysLoad": true] }
        return .object(tool)
    }

    /// Validates the arguments, runs the command, and renders the MCP result. Failures become `isError` results.
    /// Appends one line per call to `log`.
    func call(
        _ arguments: JSONValue, serverVersion: String = "dev", resolve: @escaping MCPArguments.Resolve = TargetResolver.resolve,
        log: URL = Paths.mcpLog
    ) async -> JSONValue {
        let started = Date()
        let device = ResolvedDevice()
        let response: JSONValue
        var status = "ok"
        do {
            var validated = try validate(arguments, device: device)
            validated.serverVersion = serverVersion
            validated.resolve = resolve
            let result = try await run(validated)
            let isError = failed(result)
            if isError { status = "failed" }
            response = MCPServer.toolResult(result, isError: isError)
        } catch {
            let failure = error as? DeviceLoopError ?? DeviceLoopError(.internalError, "\(error)")
            status = Task.isCancelled ? "cancelled" : failure.code.rawValue
            response = MCPServer.toolResult(failure)
        }
        MCPActivityLog.append(
            tool: name, arguments: arguments, deviceName: device.name.withLock { $0 }, status: status, started: started, to: log)
        return response
    }

    private func validate(_ arguments: JSONValue, device: ResolvedDevice) throws -> MCPArguments {
        let values: [String: JSONValue]
        switch arguments {
            case .null: values = [:]
            case .object(let object): values = object.filter { $0.value != .null }
            default: throw DeviceLoopError(.badArguments, "\(name) arguments must be a JSON object.")
        }
        let usage =
            "Arguments for \(name): "
            + properties.keys.sorted().map { required.contains($0) ? "\($0) (required)" : $0 }.joined(separator: ", ") + "."
        if let unknown = values.keys.sorted().first(where: { properties[$0] == nil }) {
            throw DeviceLoopError(.badArguments, "\(name) has no argument \(unknown).", fix: usage)
        }
        if let missing = required.first(where: { values[$0] == nil }) {
            throw DeviceLoopError(.badArguments, "\(name) needs \(missing).", fix: usage)
        }
        return MCPArguments(tool: name, values: values, device: device)
    }
}

/// The device name `MCPArguments.target()` resolved, for the activity log.
final class ResolvedDevice: Sendable {
    let name = Mutex<String?>(nil)
}

/// Typed access to `tools/call` arguments. Wrong types throw `bad_arguments`.
struct MCPArguments: Sendable {
    typealias Resolve = @Sendable (String?) async throws -> Target

    var tool: String
    var values: [String: JSONValue]
    var device = ResolvedDevice()
    /// The server version, recorded in the provenance of runs started over MCP.
    var serverVersion = "dev"
    var resolve: Resolve = TargetResolver.resolve

    func target() async throws -> Target {
        try await target(string("device"))
    }

    /// Resolves `selector`, or `$DEVICELOOP_DEVICE` when it is nil, and records the device name for the activity log.
    func target(_ selector: String?) async throws -> Target {
        let target = try await resolve(selector)
        device.name.withLock { $0 = target.name }
        return target
    }

    /// Runs `body` journaled as this tool call in the active run of `udid`. The `text` argument and a type `step` with its
    /// text are journaled as `[hidden]`. An inline `flow` is journaled as the activity log records it, and its typed text
    /// as `[hidden]` in the result. A result for which `failed` is true is journaled as an error.
    func record(
        _ udid: String?, savingResult: Bool = true, failed: (CommandResult) -> Bool = { _ in false },
        _ body: () async throws -> CommandResult
    ) async throws -> CommandResult {
        var journaled = values
        var hidden = [values["text"]?.string].compactMap { $0 }
        if let step = values["step"]?.string, let typed = (try? UIStep.parse(step))?.typedText { hidden += [step, typed] }
        if let flow = values["flow"] {
            let redacted = MCPActivityLog.redacted(flow: flow)
            journaled["flow"] = redacted.flow
            hidden += redacted.typed
        }
        return try await RunRecorder.record(
            udid, command: tool, args: .object(journaled), hiding: hidden, savingResult: savingResult, failed: failed, body)
    }

    func string(_ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard let string = value.string else { throw wrongType(key, "a string") }
        return string
    }

    func require(_ key: String) throws -> String {
        guard let value = try string(key) else { throw DeviceLoopError(.badArguments, "\(tool) needs \(key).") }
        return value
    }

    /// The element target in `key`, with HTML entities such as `&amp;` decoded.
    func elementTarget(_ key: String) throws -> ElementTarget? {
        try string(key).map { try UIStep.parseTarget(Self.decodingEntities($0)) }
    }

    func requireElementTarget(_ key: String) throws -> ElementTarget {
        try UIStep.parseTarget(Self.decodingEntities(require(key)))
    }

    /// `text` with `&lt;`, `&gt;`, `&quot;`, `&#34;`, `&#39;`, `&#x27;`, `&apos;` and `&amp;` replaced by the characters
    /// they stand for.
    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let entities = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#34;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"),
            ("&amp;", "&"),
        ]
        return entities.reduce(text) { decoded, entity in decoded.replacingOccurrences(of: entity.0, with: entity.1) }
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        guard let bool = value.bool else { throw wrongType(key, "true or false") }
        return bool
    }

    func int(_ key: String) throws -> Int? {
        guard let value = values[key] else { return nil }
        guard let number = value.number, number.rounded() == number, abs(number) < 1e9 else { throw wrongType(key, "an integer") }
        return Int(number)
    }

    func number(_ key: String) throws -> Double? {
        guard let value = values[key] else { return nil }
        guard let number = value.number else { throw wrongType(key, "a number") }
        return number
    }

    func strings(_ key: String) throws -> [String]? {
        guard let value = values[key] else { return nil }
        guard let strings = value.array?.compactMap(\.string), strings.count == value.array?.count else {
            throw wrongType(key, "an array of strings")
        }
        return strings
    }

    /// The `region` analysis area.
    func region() throws -> CGRect? {
        try string("region").map(VideoCommands.area)
    }

    /// The `masks` analysis areas.
    func masks() throws -> [CGRect] {
        try (strings("masks") ?? []).map(VideoCommands.area)
    }

    /// A file URL with `~` expanded.
    static func fileURL(_ path: String) -> URL {
        URL(filePath: NSString(string: path).expandingTildeInPath)
    }

    /// An array of `{key, value}` objects.
    func environment(_ key: String) throws -> [String: String] {
        guard let value = values[key] else { return [:] }
        let expected = "an array of {\"key\": ..., \"value\": ...} objects with string values"
        guard let items = value.array else { throw wrongType(key, expected) }
        var environment: [String: String] = [:]
        for item in items {
            guard let name = item["key"]?.string, let setting = item["value"]?.string else { throw wrongType(key, expected) }
            environment[name] = setting
        }
        return environment
    }

    private func wrongType(_ key: String, _ expected: String) -> DeviceLoopError {
        DeviceLoopError(.badArguments, "\(tool) argument \(key) must be \(expected).")
    }
}

/// JSON Schema fragments for tool parameters.
enum Param {
    static let device = string(
        "A UDID, a name or a unique part of it, `booted` (the booted simulator), `usb` (the cable-connected device) or `device` "
            + "(any connected device). Optional when exactly one is ready.")

    static let region = string("Analyze only this area, `x,y,w,h` in source pixels, widened to whole analysis tiles.")

    static let masks = strings(
        "Areas to ignore, each `x,y,w,h` in source pixels, widened to whole analysis tiles, for example a spinner or a clock.")

    static func string(_ description: String, oneOf values: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if !values.isEmpty { schema["enum"] = .array(values.map(JSONValue.string)) }
        return .object(schema)
    }

    static func boolean(_ description: String, default value: Bool = false) -> JSONValue {
        ["type": "boolean", "description": .string(description), "default": .bool(value)]
    }

    static func integer(_ description: String, default value: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "integer", "description": .string(description)]
        if let value { schema["default"] = .number(Double(value)) }
        return .object(schema)
    }

    static func number(_ description: String) -> JSONValue {
        ["type": "number", "description": .string(description)]
    }

    static func number(_ description: String, default value: Double) -> JSONValue {
        ["type": "number", "description": .string(description), "default": .number(value)]
    }

    static func strings(_ description: String) -> JSONValue {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }

    static func keyValues(_ description: String) -> JSONValue {
        [
            "type": "array",
            "description": .string(description),
            "items": [
                "type": "object",
                "properties": ["key": ["type": "string"], "value": ["type": "string"]],
                "required": ["key", "value"],
                "additionalProperties": false,
            ],
        ]
    }
}

/// The tools this server lists, in `tools/list` order.
enum MCPTools {
    static let all = core + stateTools + prepareTools + testTools + logs + container + trace + ui + flow + runs

    static let core: [MCPTool] = [
        MCPTool(
            name: "device_list",
            title: "List devices",
            description:
                "List iPhones, iPads and simulators paired with this Mac, ready ones first. Pass a name or UDID from it as `device` to other tools.",
            properties: ["all": Param.boolean("Include shut-down simulators, unavailable devices and other platforms.")],
            readOnly: true,
            alwaysLoad: true
        ) { arguments in
            try await DeviceCommands.list(all: arguments.bool("all") ?? false)
        },
        .device(
            name: "device_info",
            title: "Device info",
            description: """
                Model, OS, connection, lock state, screen size, and each capability with its status \
                (available, unavailable, needsOwnerAction or unknown) and reason.
                """,
            readOnly: true
        ) { target, _ in
            try await DeviceCommands.info(target)
        },
        MCPTool(
            name: "device_doctor",
            title: "Check setup",
            description: """
                Check Xcode, signing, pairing, Developer Mode, connection, lock state, developer disk image services and the UI runner \
                session, with one fix line per problem. Use it when a call fails with a setup or connection error.
                """,
            properties: [
                "device": Param.string(
                    "A UDID, a name or a unique part of it, `booted`, `usb` or `device`. Defaults to DEVICELOOP_DEVICE. Without either, checks every device, booted simulator and simulator with an open state scope."
                )
            ],
            readOnly: true
        ) { arguments in
            guard let selector = try arguments.string("device") ?? ProcessInfo.processInfo.environment["DEVICELOOP_DEVICE"] else {
                return try await SetupCommands.doctor(nil)
            }
            return try await SetupCommands.doctor(arguments.target(selector))
        },
        .device(
            name: "device_view",
            title: "Show device screen",
            description:
                "Open the live screen of a device or simulator in Device Hub on the Mac so a person can watch. Returns no image, use screen_capture for that.",
            readOnly: false,
            idempotent: true
        ) { target, _ in
            try await DeviceCommands.view(target)
        },
        .device(
            name: "screen_capture",
            title: "Screenshot",
            description: """
                Screenshot a device or simulator. The image is at point size, so its pixels are screen points. \
                The full-resolution PNG is saved in the DeviceLoop artifacts folder and its path returned.
                """,
            properties: [
                "scale": Param.string(
                    "`points` (default) or `native` pixels for the returned image.", oneOf: ScreenshotScale.allCases.map(\.rawValue))
            ],
            readOnly: true
        ) { target, arguments in
            let scaleName = try arguments.string("scale") ?? ScreenshotScale.points.rawValue
            guard let scale = ScreenshotScale(rawValue: scaleName) else {
                throw DeviceLoopError(.badArguments, "screen_capture scale must be points or native, got \(scaleName).")
            }
            return try await UICommands.screenshot(target, scale: scale, output: nil)
        },
        .device(
            name: "app_list",
            title: "List apps",
            description: """
                List apps installed on a device or simulator with bundle ID, name and version. A phone can have hundreds, so \
                pass name to look for one. With running, list running apps with pids instead, and the foreground ones when a UI \
                runner is already running, else foreground unknown with the reason, without starting a runner.
                """,
            properties: [
                "include_system": Param.boolean("Include system apps."),
                "name": Param.string("Only apps whose name or bundle ID contains this text."),
                "running": Param.boolean("List running apps, system apps included, with pids and the foreground app."),
            ],
            readOnly: true
        ) { target, arguments in
            if try arguments.bool("running") ?? false { return try await AppCommands.running(target) }
            return try await AppCommands.list(
                target, includeSystem: arguments.bool("include_system") ?? false, matching: arguments.string("name"))
        },
        .device(
            name: "app_install",
            title: "Install app",
            description:
                "Install an .app bundle or .ipa on a device or simulator. Rejects a build for the other kind of target or one that needs a newer iOS. Reports the bundle ID, version, build and signing, and checks the version and build against the installed app.",
            properties: ["path": Param.string("Path to the .app bundle or .ipa file on this Mac.")],
            required: ["path"],
            readOnly: false,
            idempotent: true
        ) { target, arguments in
            try await AppCommands.install(target, path: MCPArguments.fileURL(arguments.require("path")))
        },
        .device(
            name: "app_uninstall",
            title: "Uninstall app",
            description: "Uninstall an app and delete its data from a device or simulator.",
            properties: ["bundle_id": Param.string("Bundle ID, for example com.example.app.")],
            required: ["bundle_id"],
            readOnly: false,
            destructive: true,
            idempotent: true
        ) { target, arguments in
            try await AppCommands.uninstall(target, bundleID: arguments.require("bundle_id"))
        },
        .device(
            name: "app_launch",
            title: "Launch app",
            description: """
                Launch an app by bundle ID, with optional launch arguments and environment variables. Reports launched, \
                relaunched, or activated when it was already running and the arguments and environment did not apply.
                """,
            properties: [
                "bundle_id": Param.string("Bundle ID, for example com.apple.Preferences."),
                "arguments": Param.strings("Launch arguments passed to the app."),
                "env": Param.keyValues("Environment variables for the app."),
                "restart": Param.boolean("Terminate a running instance first."),
            ],
            required: ["bundle_id"],
            readOnly: false
        ) { target, arguments in
            try await AppCommands.launch(
                target,
                bundleID: arguments.require("bundle_id"),
                arguments: arguments.strings("arguments") ?? [],
                environment: arguments.environment("env"),
                console: false,
                terminateExisting: arguments.bool("restart") ?? false
            )
        },
        .device(
            name: "app_terminate",
            title: "Terminate app",
            description: "Terminate a running app by bundle ID.",
            properties: ["bundle_id": Param.string("Bundle ID, for example com.example.app.")],
            required: ["bundle_id"],
            readOnly: false,
            idempotent: true
        ) { target, arguments in
            try await AppCommands.terminate(target, bundleID: arguments.require("bundle_id"))
        },
        .device(
            name: "url_open",
            title: "Open URL",
            description: """
                Open a URL or deep link on a device or simulator, for example https://apple.com or myapp://route. \
                Reports the bundle ID of the app that handled it, or unknown.
                """,
            properties: ["url": Param.string("The URL to open.")],
            required: ["url"],
            readOnly: false,
            openWorld: true
        ) { target, arguments in
            try await AppCommands.openURL(target, url: arguments.require("url"))
        },
        .device(
            name: "device_set",
            title: "Change device settings",
            description: """
                Set the simulated location, light or dark appearance, or orientation of a device or simulator. \
                Pass one or more of the fields. A field that fails is reported and the others still apply. \
                Orientation returns `previous`, `requested`, `observed` and `verified`. Pass `previous` back to restore it. \
                Location returns `previousKnown` false because devicectl cannot read the simulated location. \
                `clear` removes any simulated location, including one another tool set. \
                While a state_scope is open on the target, each change is journaled with its original value. \
                Location is journaled unknown, and a strict scope refuses it.
                """,
            properties: [
                "location": Param.string("`LAT,LON` in degrees, for example 37.3349,-122.0090, or `clear`."),
                "appearance": Param.string("Light or dark appearance.", oneOf: ["light", "dark"]),
                "orientation": Param.string(
                    "Screen orientation.",
                    oneOf: ["portrait", "portraitUpsideDown", "landscapeLeft", "landscapeRight"]
                ),
            ],
            readOnly: false,
            destructive: true,
            idempotent: true,
            failed: { $0.json["ok"] == false },
            run: applySettings
        ),
        .device(
            name: "pasteboard",
            title: "Pasteboard",
            description: """
                Copy text to the pasteboard of a device or simulator, or read what is on it. \
                Copy replaces the contents without saving them. A strict state_scope refuses copy.
                """,
            properties: [
                "action": Param.string("`copy` sets the pasteboard to `text`, `paste` returns its contents.", oneOf: ["copy", "paste"]),
                "text": Param.string("Text for `copy`."),
            ],
            required: ["action"],
            readOnly: false,
            destructive: true,
            idempotent: true,
            savingResult: false
        ) { target, arguments in
            switch try arguments.require("action") {
                case "copy": return try await SettingsCommands.pasteboardCopy(target, text: arguments.require("text"))
                case "paste": return try await SettingsCommands.pasteboardPaste(target)
                case let action: throw DeviceLoopError(.badArguments, "pasteboard action must be copy or paste, got \(action).")
            }
        },
        .device(
            name: "crash_list",
            title: "Crash reports",
            description: "List crash reports of a device or simulator, newest first. crash_pull copies one to the Mac.",
            properties: [
                "process": Param.string("Only reports for this process name."),
                "limit": Param.integer("Maximum reports to list.", default: 20),
                "since": Param.string(
                    "ISO 8601 time, such as the launchedAt from app_launch. Reports dated earlier are left out, undated ones are kept."),
            ],
            readOnly: true
        ) { target, arguments in
            try await CrashCommands.list(
                target, process: arguments.string("process"), limit: arguments.int("limit") ?? 20, since: arguments.string("since"))
        },
        .device(
            name: "crash_pull",
            title: "Pull crash report",
            description: """
                Copy one crash report from a device or simulator to the DeviceLoop artifacts folder and return its path, sha256, \
                udid and source, its bundleID, appVersion, buildVersion and incidentID from the header, and its pid. Reports are \
                not symbolicated. Open them in Xcode with the app's dSYM for that.
                """,
            properties: ["name": Param.string("Report name from crash_list, for example MyApp-2026-10-22-131927.ips.")],
            required: ["name"],
            readOnly: false,
            idempotent: true
        ) { target, arguments in
            try await CrashCommands.pull(target, name: arguments.require("name"), to: nil)
        },
        MCPTool(
            name: "video_record",
            title: "Record screen",
            description:
                "Record the screen in the background. `start` returns a handle. `stop` with that handle saves the video and analyzes its motion.",
            properties: [
                "action": Param.string("`start` or `stop`.", oneOf: ["start", "stop"]),
                "handle": Param.string("Handle returned by `start`, required for `stop`."),
                "analyze": Param.boolean("Analyze motion on `stop`.", default: true),
                "region": Param.region,
                "masks": Param.masks,
                "device": Param.device,
            ],
            required: ["action"],
            readOnly: false
        ) { arguments in
            switch try arguments.require("action") {
                case "start":
                    let target = try await arguments.target()
                    return try await arguments.record(target.udid) { try await VideoCommands.startRecording(target) }
                case "stop":
                    let handle = try arguments.require("handle")
                    let analyze = try arguments.bool("analyze") ?? true
                    let region = try arguments.region()
                    let masks = try arguments.masks()
                    return try await arguments.record(VideoCommands.recordingDevice(handle)) {
                        try await VideoCommands.stopRecording(handle: handle, analyze: analyze, region: region, masks: masks)
                    }
                case let action: throw DeviceLoopError(.badArguments, "video_record action must be start or stop, got \(action).")
            }
        },
        .device(
            name: "video_capture",
            title: "Capture animation",
            description: """
                Record around one step and report how the screen moved: latency, motion segments, last change time and \
                visual gap candidates, plus a contact sheet image. Gap candidates come from repeated or missing video frames \
                and are not native hitch metrics. Steps are tap, doubletap, hold, swipe, drag, type, press, launch, open \
                and sleep. With `instruments` on a device, an Animation Hitches trace of `app` runs around the capture and \
                each candidate gets a `traceVerdict` from the trace's displayed-surface gaps. The trace adds its start, save \
                and export time to the call and needs about 7 GB of free disk with the default waits.
                """,
            properties: [
                "step": Param.string(
                    "The step to run, for example `tap id=login`, `swipe up`, `launch com.apple.Preferences` or `sleep 500`."),
                "app": Param.string("Bundle ID of the app the step acts on. Defaults to the app in front."),
                "pre_ms": Param.integer("Record this long before the step.", default: 300),
                "wait_ms": Param.integer("Keep recording this long after the step.", default: 1500),
                "keep_video": Param.boolean("Keep the raw video next to the contact sheet. A failed capture always keeps it."),
                "instruments": Param.boolean("Record an Animation Hitches trace of `app` around the capture. Devices only."),
                "keep_trace": Param.boolean("Keep the `instruments` trace and its table of contents."),
                "region": Param.region,
                "masks": Param.masks,
            ],
            required: ["step"],
            readOnly: false,
            destructive: true
        ) { target, arguments in
            try await VideoCommands.capture(
                target,
                step: UIStep.parse(arguments.require("step")),
                app: arguments.string("app"),
                preMs: arguments.int("pre_ms") ?? 300,
                waitMs: arguments.int("wait_ms") ?? 1500,
                keepVideo: arguments.bool("keep_video") ?? false,
                region: arguments.region(),
                masks: arguments.masks(),
                instruments: arguments.bool("instruments") ?? false,
                keepTrace: arguments.bool("keep_trace") ?? false
            )
        },
        MCPTool(
            name: "video_inspect",
            title: "Analyze video",
            description:
                "Analyze an MP4 or MOV screen recording on this Mac: motion segments, last change, visual gap candidates and a contact sheet image.",
            properties: [
                "path": Param.string("Path to the video file."),
                "sheet": Param.boolean("Return a contact sheet image.", default: true),
                "region": Param.region,
                "masks": Param.masks,
            ],
            required: ["path"],
            readOnly: true
        ) { arguments in
            try await VideoCommands.inspect(
                MCPArguments.fileURL(arguments.require("path")), sheet: arguments.bool("sheet") ?? true,
                region: arguments.region(), masks: arguments.masks())
        },
        .device(
            name: "device_lock",
            title: "Lock the screen",
            description: """
                Lock the device screen through Siri. The device must be unlocked to run. DeviceLoop cannot unlock it afterwards, \
                so this cuts off further UI control until a person unlocks it. Returns lockVerified false with a reason when \
                devicectl does not report the lock within 8 seconds. A device with no passcode cannot be verified. Do not send \
                the lock again then.
                """,
            readOnly: false,
            destructive: true
        ) { target, _ in
            try await SiriCommands.lock(target)
        },
        .device(
            name: "system_control",
            title: "System control",
            description: """
                Change a system setting that has no direct API, through Siri. The device must be unlocked. DeviceLoop cannot \
                read these back, so take a screenshot to confirm. `setting` is wifi, bluetooth, low_power, do_not_disturb, \
                airplane, brightness or volume. `value` is on or off for a toggle, or 0 to 100 for brightness and volume. \
                Airplane over Wi-Fi drops the device connection. An open state_scope journals the change with the original \
                unknown, and a strict one refuses it.
                """,
            properties: [
                "setting": Param.string(
                    "The setting to change.",
                    oneOf: ["wifi", "bluetooth", "low_power", "do_not_disturb", "airplane", "brightness", "volume"]
                ),
                "value": Param.string("on or off for a toggle, or 0 to 100 for brightness and volume."),
            ],
            required: ["setting", "value"],
            readOnly: false,
            destructive: true
        ) { target, arguments in
            switch try SiriCommands.Control(setting: arguments.require("setting"), value: arguments.require("value")) {
                case .toggle(let toggle, let on): return try await SiriCommands.toggle(target, toggle, on: on)
                case .brightness(let percent): return try await SiriCommands.brightness(target, percent: percent)
                case .volume(let percent): return try await SiriCommands.volume(target, percent: percent)
            }
        },
        .device(
            name: "device_siri",
            title: "Ask Siri",
            description: """
                Say text to Siri on the device, for example "open Calculator" or "start a 5 minute timer". The device must be \
                unlocked. Siri can also place calls, send messages and change settings, so confirm the text before running it.
                """,
            properties: ["text": Param.string("What to say to Siri.")],
            required: ["text"],
            readOnly: false,
            destructive: true
        ) { target, arguments in
            try await SiriCommands.say(target, text: arguments.require("text"))
        },
        .device(
            name: "device_operation",
            title: "Inspect operation receipt",
            description:
                "Read the runner receipt for an accepted request or an error, without sending input. A finished receipt reports execution, not the effect. A missing receipt leaves the outcome unknown.",
            properties: [
                "id": Param.string("Operation UUID from the accepted request or error."),
                "epoch": Param.string("Runner session epoch returned with that operation."),
            ],
            required: ["id", "epoch"],
            readOnly: true
        ) { target, arguments in
            try await RunnerCommands.operation(target, id: arguments.require("id"), epoch: arguments.require("epoch"))
        },
    ]

    typealias SettingChange = (name: String, apply: () async throws -> CommandResult)

    /// Applies each setting given. With several, a failed one is reported and the others still apply.
    static func applySettings(_ target: Target, _ arguments: MCPArguments) async throws -> CommandResult {
        var changes: [SettingChange] = []
        if let location = try arguments.string("location") {
            let (latitude, longitude) = try parseLocation(location)
            changes.append(("location", { try await SettingsCommands.location(target, latitude: latitude, longitude: longitude) }))
        }
        if let mode = try arguments.string("appearance") {
            changes.append(("appearance", { try await SettingsCommands.appearance(target, mode: mode) }))
        }
        if let orientation = try arguments.string("orientation") {
            changes.append(("orientation", { try await SettingsCommands.orientation(target, value: orientation) }))
        }
        guard !changes.isEmpty else {
            throw DeviceLoopError(
                .badArguments, "device_set needs location, appearance or orientation.", fix: "For example: {\"appearance\": \"dark\"}")
        }
        if changes.count == 1 { return try await changes[0].apply() }
        return try await combine(changes, on: target)
    }

    /// Runs every change and merges the results. A partial failure starts the text with `ERROR partial` and sets `ok` false.
    /// Throws the first error when every change fails.
    static func combine(_ changes: [SettingChange], on target: Target) async throws -> CommandResult {
        var combined = CommandResult(text: target.summary)
        var payload: [String: JSONValue] = [:]
        var firstError: DeviceLoopError?
        var failed: [String] = []
        for change in changes {
            do {
                let result = try await change.apply()
                let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                for line in lines.first == target.summary ? Array(lines.dropFirst()) : lines {
                    combined.text += "\n" + line
                }
                payload[change.name] = result.json
                combined.images += result.images
                combined.files += result.files
            } catch let error as DeviceLoopError {
                firstError = firstError ?? error
                failed.append(change.name)
                combined.text += "\n" + error.rendered
                payload[change.name] = ["error": try JSONValue(encoding: error)]
            }
        }
        if let firstError, failed.count == changes.count { throw firstError }
        if !failed.isEmpty {
            combined.text = "ERROR partial: \(failed.joined(separator: ", ")) failed, the rest applied\n" + combined.text
            payload["ok"] = false
            payload["failed"] = .array(failed.map(JSONValue.string))
        }
        combined.json = .object(payload)
        return combined
    }

    /// `LAT,LON`, or `clear` as nil coordinates.
    static func parseLocation(_ text: String) throws -> (latitude: Double?, longitude: Double?) {
        if text.lowercased() == "clear" { return (nil, nil) }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let latitude = parts[0], let longitude = parts[1], (-90 ... 90).contains(latitude),
            (-180 ... 180).contains(longitude)
        else {
            throw DeviceLoopError(
                .badArguments, "device_set location must be LAT,LON or clear, got \(text).", fix: "For example: 37.3349,-122.0090")
        }
        return (latitude, longitude)
    }
}
