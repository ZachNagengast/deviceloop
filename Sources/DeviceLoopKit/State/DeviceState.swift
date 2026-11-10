//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// One read of a target's identity, readiness and settings.
public struct DeviceState: Codable, Sendable {
    public var schema = "deviceloop.device-state/1"
    public var udid: String
    /// ISO 8601 time the capture started.
    public var capturedAt: String
    public var fields: [String: StateField]
}

/// One value in a `DeviceState` and where it came from.
public struct StateField: Codable, Sendable, Equatable {
    public enum Availability: String, Codable, Sendable {
        /// Read from the target.
        case observed
        /// No source, or the read failed.
        case unknown
        /// The target lacks the capability.
        case unsupported
        /// The target is offline or locked.
        case unavailable
    }

    public enum Scope: String, Codable, Sendable {
        case device
        case simulator
        case app
    }

    /// `settable` when devicectl or simctl can change the value.
    public enum Mutability: String, Codable, Sendable {
        case readOnly
        case settable
    }

    public enum Sensitivity: String, Codable, Sendable {
        case normal
        case identifying
        case personal
    }

    /// Nil unless observed.
    public var value: JSONValue?
    public var availability: Availability
    /// Why the value was not observed.
    public var reason: String?
    /// Command the value comes from, for example `devicectl device info appearance`.
    public var source: String
    /// ISO 8601 time the source returned.
    public var observedAt: String?
    public var scope: Scope
    public var mutability: Mutability
    public var sensitivity: Sensitivity
    /// DeviceLoop can set the observed value back.
    public var restorable: Bool
}

extension DeviceState {
    typealias DevicectlRead = @Sendable ([String]) async throws -> JSONValue
    typealias SimctlRead = @Sendable ([String]) async throws -> String

    /// Reads every field the target supports, in parallel. A failed read is unknown.
    static func capture(_ target: Target) async -> DeviceState {
        await capture(
            target,
            devicectl: { try await Devicectl.run($0, target: target, timeout: .seconds(20)) },
            simctl: { try await Simctl.run($0, timeout: .seconds(20)).stdoutString }
        )
    }

    static func capture(_ target: Target, devicectl: DevicectlRead, simctl: SimctlRead) async -> DeviceState {
        let capturedAt = timestamp()
        let scope: StateField.Scope = target.isSimulator ? .simulator : .device

        func read(_ capability: String, _ subcommand: [String], options: [String] = []) async -> Reading {
            await Reading.read(target, capability, source: "devicectl device " + subcommand.joined(separator: " ")) {
                try await devicectl(["device"] + subcommand + ["-d", target.udid] + options)
            }
        }
        async let lock = read(Capability.lockState, ["info", "lockState"])
        async let ddi = read(Capability.ddiMetadata, ["info", "ddiServices"], options: ["--no-auto-mount-ddis"])
        async let appearance = read(Capability.uiStyle, ["info", "appearance"])
        async let orientation = read(Capability.orientation, ["orientation", "get"])
        async let voiceOver = read(Capability.voiceOver, ["info", "voiceover"])
        async let audio = read(Capability.audioOutput, ["info", "audio"])
        async let statusBar = Reading.read(target, Capability.statusBar, source: "simctl status_bar list") {
            .array(statusBarOverrides(try await simctl(["status_bar", target.udid, "list"])).map(JSONValue.string))
        }

        func field(
            _ reading: Reading,
            mutability: StateField.Mutability = .settable,
            restorable: Bool = false,
            _ extract: (JSONValue) -> JSONValue?
        ) -> StateField {
            let value = reading.result.flatMap(extract)
            let missing = reading.result != nil && value == nil
            return StateField(
                value: value,
                availability: missing ? .unknown : reading.availability,
                reason: missing ? "\(reading.source) did not report it" : reading.reason,
                source: reading.source,
                observedAt: value == nil ? nil : reading.observedAt,
                scope: scope,
                mutability: mutability,
                sensitivity: .normal,
                restorable: restorable
            )
        }

        func identity(_ value: JSONValue?, sensitivity: StateField.Sensitivity = .normal) -> StateField {
            StateField(
                value: value,
                availability: value == nil ? .unknown : .observed,
                reason: value == nil ? "devicectl list devices did not report it" : nil,
                source: "devicectl list devices",
                observedAt: value == nil ? nil : capturedAt,
                scope: scope,
                mutability: .readOnly,
                sensitivity: sensitivity,
                restorable: false
            )
        }

        func unknown(
            _ reason: String, mutability: StateField.Mutability, sensitivity: StateField.Sensitivity = .normal
        ) -> StateField {
            StateField(
                availability: .unknown, reason: reason, source: "none", scope: scope, mutability: mutability,
                sensitivity: sensitivity, restorable: false)
        }

        var fields = [
            "name": identity(.string(target.name), sensitivity: .identifying),
            "model": identity(.string(target.model)),
            "productType": identity(.string(target.productType)),
            "osVersion": identity(.string(target.osVersion)),
            "osBuild": identity(target.osBuild.map(JSONValue.string)),
            "ready": identity(.bool(target.isReady)),
            "connection": identity(.string(DeviceCommands.state(target))),
            "location": unknown("devicectl and simctl cannot read the simulated location", mutability: .settable, sensitivity: .personal),
            "pasteboard": unknown("DeviceLoop does not capture pasteboard contents", mutability: .settable, sensitivity: .personal),
            "battery": unknown("devicectl and simctl do not report the battery", mutability: .readOnly),
            "thermalState": unknown("devicectl and simctl do not report the thermal state", mutability: .readOnly),
            "lowPowerMode": unknown("devicectl and simctl do not report Low Power Mode", mutability: .readOnly),
        ]
        fields["lockState"] = field(await lock, mutability: .readOnly) { result in
            guard let passcodeRequired = result["passcodeRequired"] else { return nil }
            return ["passcodeRequired": passcodeRequired, "unlockedSinceBoot": result["unlockedSinceBoot"] ?? .null]
        }
        fields["ddiUsable"] = field(await ddi, mutability: .readOnly) { $0.value(at: "ddiMetadata.isUsable") }

        let appearanceReading = await appearance
        let appearancePaths = [
            ("userInterfaceStyle", "userInterfaceStyle"),
            ("textSize", "textSize"),
            ("largerAccessibilitySizesEnabled", "largerAccessibilitySizesEnabled"),
            ("increaseContrast", "increaseContrast"),
            ("reduceMotion", "reduceMotion.enabled"),
            ("reduceTransparency", "reduceTransparency.enabled"),
            ("showBorders", "showBorders.enabled"),
            ("colorFilter", "colorFilter.enabled"),
        ]
        for (name, path) in appearancePaths {
            fields[name] = field(appearanceReading, restorable: name == "userInterfaceStyle") { $0.value(at: path) }
        }
        fields["orientation"] = field(await orientation, restorable: true) {
            SettingsCommands.currentOrientation($0).map(JSONValue.string)
        }
        fields["voiceOver"] = field(await voiceOver) { $0["enabled"] }
        fields["volume"] = field(await audio) { $0["volume"] }
        fields["statusBarOverrides"] = field(await statusBar) { $0 }

        return DeviceState(udid: target.udid, capturedAt: capturedAt, fields: fields)
    }

    /// Override lines from `simctl status_bar <udid> list`, empty when there are none.
    static func statusBarOverrides(_ output: String) -> [String] {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "Current Status Bar Overrides:" && !$0.allSatisfy { $0 == "=" } }
    }

    static func timestamp() -> String {
        Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// The outcome of one source command, shared by the fields it feeds.
    struct Reading: Sendable {
        var source: String
        var result: JSONValue?
        var availability = StateField.Availability.observed
        var reason: String?
        var observedAt: String?

        /// Runs `run` when the target is ready and has `capability`, and records why not otherwise.
        static func read(
            _ target: Target, _ capability: String, source: String, _ run: () async throws -> JSONValue
        ) async -> Reading {
            guard target.isReady else {
                return Reading(source: source, availability: .unavailable, reason: "\(target.name) is \(DeviceCommands.state(target))")
            }
            guard target.supports(capability) else {
                return Reading(source: source, availability: .unsupported, reason: "missing capability \(capability)")
            }
            do {
                let result = try await run()
                return Reading(source: source, result: result, observedAt: timestamp())
            } catch let error as DeviceLoopError {
                let availability: StateField.Availability =
                    switch error.code {
                        case .deviceOffline, .deviceLocked: .unavailable
                        case .unsupportedOnTarget: .unsupported
                        default: .unknown
                    }
                return Reading(source: source, availability: availability, reason: error.message)
            } catch {
                return Reading(source: source, availability: .unknown, reason: "\(error)")
            }
        }
    }
}
