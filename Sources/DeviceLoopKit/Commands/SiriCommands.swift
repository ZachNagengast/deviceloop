//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation

/// Siri requests through the runner on an unlocked device. Siri is the only public way to lock the screen and set the
/// connectivity and power toggles, brightness and volume, and DeviceLoop cannot read most of these settings back.
public enum SiriCommands {
    /// System toggles with no other public API. The raw value is the Siri noun.
    public enum Toggle: String, Sendable, CaseIterable {
        case wifi = "Wi-Fi"
        case bluetooth = "Bluetooth"
        case lowPowerMode = "Low Power Mode"
        case doNotDisturb = "Do Not Disturb"
        case airplaneMode = "Airplane Mode"

        public init?(cli: String) {
            switch cli.lowercased() {
                case "wifi", "wi-fi": self = .wifi
                case "bluetooth": self = .bluetooth
                case "lowpower", "low-power", "low_power", "lowpowermode": self = .lowPowerMode
                case "dnd", "donotdisturb", "do-not-disturb", "do_not_disturb": self = .doNotDisturb
                case "airplane", "airplanemode": self = .airplaneMode
                default: return nil
            }
        }
    }

    /// A `system_control` request, checked before anything reaches the device.
    public enum Control: Equatable, Sendable {
        case toggle(Toggle, on: Bool)
        case brightness(Int)
        case volume(Int)

        public init(setting: String, value: String) throws {
            switch setting {
                case "brightness", "volume":
                    guard let percent = Int(value) else {
                        throw DeviceLoopError(.badArguments, "\(setting) needs a number, not \(value).", fix: "Pass value as 0 to 100.")
                    }
                    self = setting == "brightness" ? .brightness(percent) : .volume(percent)
                default:
                    guard let toggle = Toggle(cli: setting) else {
                        throw DeviceLoopError(.badArguments, "Unknown setting \(setting).")
                    }
                    guard let on = ["on": true, "off": false][value.lowercased()] else {
                        throw DeviceLoopError(.badArguments, "\(setting) needs on or off, not \(value).", fix: "Pass value as on or off.")
                    }
                    self = .toggle(toggle, on: on)
            }
        }
    }

    /// Says `text` to Siri verbatim. With `wait`, polls the receipt until XCTest returns, then looks for `expect` in `app`.
    public static func say(
        _ target: Target, text: String, wait: Duration? = nil, expect: ElementQuery? = nil, app: String? = nil
    ) async throws -> CommandResult {
        if let wait, wait <= .zero {
            throw DeviceLoopError(.badArguments, "The wait timeout must be above zero.", fix: "Pass --timeout in seconds, for example 180.")
        }
        return try await send(target, phrase: text, note: false, wait: wait, expect: expect, app: app)
    }

    /// Parses `id=X` or `label=Y` for `siri say --expect`.
    public static func expectation(_ text: String) throws -> ElementQuery {
        if text.hasPrefix("id="), text.count > 3 { return ElementQuery(id: String(text.dropFirst(3))) }
        if text.hasPrefix("label="), text.count > 6 { return ElementQuery(label: String(text.dropFirst(6))) }
        throw DeviceLoopError(
            .badArguments, "Cannot expect \(text).", fix: "Pass --expect id=<identifier> or --expect label=<exact label>.")
    }

    /// Journaled as the case name, for example `wifi`, while a state scope is open.
    public static func toggle(_ target: Target, _ setting: Toggle, on: Bool) async throws -> CommandResult {
        try requireSiri(target)
        let state = on ? "on" : "off"
        return try await ChangeJournal(udid: target.udid).record(
            field: "\(setting)", requested: .string(state), unreadable: "DeviceLoop cannot read \(setting.rawValue) back."
        ) { try await send(target, phrase: "turn \(state) \(setting.rawValue)", note: true) }
    }

    public static func brightness(_ target: Target, percent: Int) async throws -> CommandResult {
        try await setLevel("brightness", on: target, percent: percent, unreadable: "DeviceLoop cannot read brightness back.")
    }

    public static func volume(_ target: Target, percent: Int) async throws -> CommandResult {
        try await setLevel("volume", on: target, percent: percent, unreadable: "DeviceLoop does not read volume back after Siri sets it.")
    }

    /// Asks Siri to set `field` to `percent`, clamped to 0-100, journaled as `field`.
    private static func setLevel(_ field: String, on target: Target, percent: Int, unreadable: String) async throws -> CommandResult {
        try requireSiri(target)
        let percent = max(0, min(100, percent))
        let journal = ChangeJournal(udid: target.udid)
        return try await journal.record(field: field, requested: .number(Double(percent)), unreadable: unreadable) {
            try await send(target, phrase: "set \(field) to \(percent) percent", note: true)
        }
    }

    /// Locks the screen, confirmed with devicectl within `verifySeconds` because the runner connection drops when it locks.
    public static func lock(_ target: Target, verifySeconds: Int = 8) async throws -> CommandResult {
        let window = try lockWindow(seconds: verifySeconds)
        guard !target.isSimulator else {
            throw DeviceLoopError.unsupported("Locking", on: target, alternatives: ["Simulators have no lock screen"])
        }
        let session = try await UICommands.connect(target)
        return try await lock(target, client: session.client, window: window) {
            try await Devicectl.run(Devicectl.device(target, "info", "lockState"), target: target, timeout: .seconds(10))
        }
    }

    static func lockWindow(seconds: Int) throws -> Duration {
        guard (1 ... 300).contains(seconds) else {
            throw DeviceLoopError(
                .badArguments, "The lock verification window must be between 1 and 300 seconds, not \(seconds).",
                fix: "Pass --verify-seconds as 1 to 300, for example 8.")
        }
        return .seconds(seconds)
    }

    /// Sends the lock once, then polls `lockState` until it shows passcodeRequired or `window` ends.
    static func lock(
        _ target: Target, client: RunnerClient, window: Duration, interval: Duration = .seconds(1),
        lockState: () async throws -> JSONValue
    ) async throws -> CommandResult {
        var operation: OperationReference?
        do {
            operation = try await client.post(
                RunnerWire.Path.siri, SiriRequest(text: "lock the screen"), as: ActionResult.self, timeout: 15
            ).operation
        } catch let error as DeviceLoopError where error.code == .actionOutcomeUnknown {
            // A lock can sever the connection. Verify its effect without submitting it again.
            if let id = error.operationID, let epoch = error.sessionEpoch {
                operation = OperationReference(id: id, sessionEpoch: epoch, phase: "unknown")
            }
        }
        var json: [String: JSONValue] = ["operation": try operation.map { try JSONValue(encoding: $0) } ?? .null]
        let deadline = ContinuousClock.now + window
        var reason: String
        repeat {
            try await Task.sleep(for: interval)
            do {
                if try await lockState()["passcodeRequired"]?.bool == true {
                    json["lockVerified"] = true
                    return CommandResult(text: "\(target.summary)\nlocked", json: .object(json))
                }
                reason =
                    "devicectl did not report passcodeRequired within \(window). "
                    + "A device with no passcode never does, so its lock cannot be verified."
            } catch {
                reason = "devicectl could not read the lock state: \((error as? DeviceLoopError)?.message ?? "\(error)")"
            }
        } while ContinuousClock.now < deadline
        json["lockVerified"] = false
        json["reason"] = .string(reason)
        var lines = [target.summary, "asked Siri to lock the screen", "lock not verified: \(reason)"]
        lines.append(
            operation.map {
                "Do not send it again. Check the device, or read `deviceloop runner operation \($0.id) --epoch \($0.sessionEpoch)`."
            } ?? "Do not send it again. Check the device.")
        return CommandResult(text: lines.joined(separator: "\n"), json: .object(json))
    }

    static func send(
        _ target: Target, phrase: String, note: Bool, wait: Duration? = nil, expect: ElementQuery? = nil, app: String? = nil
    ) async throws -> CommandResult {
        try requireSiri(target)
        let session = try await UICommands.connect(target)
        return try await send(target, client: session.client, phrase: phrase, note: note, wait: wait, expect: expect, app: app)
    }

    static func send(
        _ target: Target, client: RunnerClient, phrase: String, note: Bool, wait: Duration?, expect: ElementQuery?, app: String?,
        interval: Duration = .seconds(1)
    ) async throws -> CommandResult {
        // Read before Siri, because the runner answers only health and receipts while Siri runs.
        let languages = try? await client.get(RunnerWire.Path.info, as: InfoResult.self, timeout: 10).preferredLanguages
        let result = try await client.post(RunnerWire.Path.siri, SiriRequest(text: phrase), as: ActionResult.self, timeout: 10)
        var lines = [target.summary, "accepted Siri request: \(phrase)"]
        var json: [String: JSONValue] = [
            "phrase": .string(phrase),
            "verified": false,
            "deviceLanguages": languages.map { .array($0.map(JSONValue.string)) } ?? .null,
            "siriLanguage": "unknown",
            "siriEnabled": "unknown",
        ]
        if let operation = result.operation, let wait {
            let receipt = try await finished(operation, client: client, timeout: wait, interval: interval)
            let response = receipt.responseJSON.flatMap { try? JSONValue(data: Data($0.utf8)) }
            lines += RunnerCommands.operationLines(operation.id, result: receipt)
            json["operation"] = try JSONValue(encoding: receipt.operation)
            json["responseStatus"] = receipt.responseStatus.map { .number(Double($0)) } ?? .null
            json["response"] = response ?? .null
            json["issues"] = response?["issues"] ?? []
            if let expect {
                if app == nil { await UICommands.focusForeground(target, client: client) }
                var expectation: [String: JSONValue] = [
                    "query": try JSONValue(encoding: expect), "app": app.map(JSONValue.string) ?? .null,
                ]
                do {
                    let found = try await client.post(RunnerWire.Path.find, FindRequest(app: app, query: expect), as: FindResult.self)
                    let selector = expect.id.map { "id=\($0)" } ?? "label=\(expect.label ?? "")"
                    lines.append(
                        found.matches.first.map { "verified: found \(UICommands.describe($0))" }
                            ?? "not verified: no element with \(selector) in \(app ?? "the app in front")")
                    json["verified"] = .bool(!found.matches.isEmpty)
                } catch let error as DeviceLoopError {
                    lines.append("not verified: the find failed with \(error.code.rawValue): \(error.message)")
                    expectation["error"] = try JSONValue(encoding: error)
                }
                json["expectation"] = .object(expectation)
            } else {
                lines.append("not verified: the receipt shows that XCTest returned, not what Siri did.")
            }
        } else if let operation = result.operation {
            lines.append(
                "Operation \(operation.id) is pending. Inspect it with `deviceloop runner operation \(operation.id) --epoch \(operation.sessionEpoch)`."
            )
            lines.append(
                "UI commands stay busy until XCTest returns, which can take minutes on a device. `deviceloop screenshot` works meanwhile."
            )
            json["operation"] = try JSONValue(encoding: operation)
        }
        lines.append("device languages: \(languages?.joined(separator: ", ") ?? "unknown"). Siri's language and enabled state are unknown.")
        if note { lines.append("DeviceLoop cannot read this setting back, so check the phone to confirm.") }
        return CommandResult(text: lines.joined(separator: "\n"), json: .object(json))
    }

    /// Polls the receipt until it finishes. A lost receipt or a timeout throws an unknown outcome with the operation ID.
    static func finished(
        _ operation: OperationReference, client: RunnerClient, timeout: Duration, interval: Duration
    ) async throws -> OperationStatusResult {
        let deadline = ContinuousClock.now + timeout
        while true {
            let receipt: OperationStatusResult
            do {
                receipt = try await client.get(RunnerWire.Path.operations + operation.id, as: OperationStatusResult.self, timeout: 5)
            } catch {
                try Task.checkCancellation()
                let detail = (error as? DeviceLoopError)?.message ?? "\(error)"
                throw unknownOutcome(operation, "Lost the receipt for Siri operation \(operation.id).", detail: detail)
            }
            if receipt.operation.phase == "finished" { return receipt }
            guard ContinuousClock.now + interval < deadline else {
                throw unknownOutcome(operation, "Siri operation \(operation.id) was still running after \(timeout).")
            }
            try await Task.sleep(for: interval)
        }
    }

    private static func unknownOutcome(_ operation: OperationReference, _ message: String, detail: String? = nil) -> DeviceLoopError {
        var error = DeviceLoopError(
            .actionOutcomeUnknown, message,
            fix: "Read the receipt later, or inspect the device, before sending another request. Do not resubmit this one.",
            detail: detail)
        error.operationID = operation.id
        error.sessionEpoch = operation.sessionEpoch
        return error
    }

    /// Throws when `target` is not an iPhone or iPad that is booted or connected.
    private static func requireSiri(_ target: Target) throws {
        guard target.isDrivable else {
            throw DeviceLoopError.unsupported("Siri", on: target, alternatives: ["Use an iPhone or iPad"])
        }
        try DeviceQueries.requireReady(target)
    }
}
