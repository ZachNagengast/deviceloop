//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// Runs `xcrun devicectl` and decodes its `--json-output` file.
public enum Devicectl {
    /// Runs `devicectl <arguments> --json-output <tmp>` and returns the `result` object.
    /// A failed outcome becomes a `DeviceLoopError` with the CoreDevice error translated.
    public static func run(
        _ arguments: [String],
        target: Target? = nil,
        timeout: Duration = .seconds(60)
    ) async throws -> JSONValue {
        try await runCapturing(arguments, target: target, timeout: timeout).result
    }

    /// Maps a devicectl `error` object to a DeviceLoop error with a fix line.
    public static func translate(_ error: JSONValue, target: Target?) -> DeviceLoopError {
        let domain = error["domain"]?.string ?? "unknown"
        let code = Int(error["code"]?.number ?? 0)
        let userInfo = error["userInfo"]
        let description =
            userInfo?.value(at: "NSLocalizedDescription.string")?.string ?? "devicectl failed (\(domain) \(code))."
        let detail = "\(domain) \(code)"
        let device = target?.name

        if domain == "com.apple.dt.CoreDeviceError" {
            switch code {
                case 1000:
                    return DeviceLoopError(
                        .deviceNotFound,
                        description,
                        fix: "Run `deviceloop devices` to see what is connected.",
                        detail: detail,
                        device: device
                    )
                case 1001:
                    let capability = userInfo?.value(at: "CapabilityFeatureIdentifier.string")?.string
                    let name = userInfo?.value(at: "CapabilityName.string")?.string ?? "This feature"
                    return DeviceLoopError(
                        .unsupportedOnTarget,
                        "\(name) is not supported on \(target?.summary ?? "this target").",
                        detail: capability.map { "missing capability \($0)" } ?? detail,
                        device: device
                    )
                case 4016:
                    return DeviceLoopError(
                        .deviceOffline,
                        description,
                        fix: "Connect the device with a cable (or join the same network), unlock it, and retry.",
                        detail: detail,
                        device: device
                    )
                default:
                    break
            }
        }
        return DeviceLoopError(.deviceError, description, detail: detail, device: device)
    }

    /// All simulators and devices CoreDevice knows about.
    public static func listTargets() async throws -> [Target] {
        let result = try await run(["list", "devices"], timeout: .seconds(30))
        return (result["devices"]?.array ?? []).compactMap(Target.init(devicectl:))
    }
}

extension Target {
    /// Builds a target from one entry of `devicectl list devices` JSON (the `properties` dictionary).
    public init?(devicectl entry: JSONValue) {
        guard let properties = entry["properties"], let hardware = properties["hardware"],
            let udid = hardware["udid"]?.string
        else { return nil }
        let connection = properties["connection"]
        let state = properties["state"]
        let reality = hardware["reality"]?.string ?? "physical"
        let developerMode: Bool? =
            switch state?["developerModeStatus"] {
                case .some(.object(let status)): status["enabled"] != nil
                case .some(.string(let status)): status == "enabled"
                default: nil
            }

        self.init(
            udid: udid,
            identifier: entry["identifier"]?.string ?? udid,
            name: state?["name"]?.string ?? entry.value(at: "deviceProperties.name")?.string ?? udid,
            kind: reality == "simulated" ? .simulator : .device,
            deviceType: hardware["deviceType"]?.string ?? "unknown",
            platform: hardware["platform"]?.string ?? "unknown",
            model: hardware["marketingName"]?.string ?? hardware["productType"]?.string ?? "unknown",
            productType: hardware["productType"]?.string ?? "unknown",
            osVersion: properties.value(at: "software.osVersionNumber.stringValue")?.string
                ?? entry.value(at: "deviceProperties.osVersionNumber")?.string ?? "unknown",
            osBuild: properties.value(at: "software.osBuildVersions.buildVersion.name")?.string
                ?? entry.value(at: "deviceProperties.osBuildUpdate")?.string,
            connectionState: connection?["state"]?.string ?? "unknown",
            bootState: state?["bootState"]?.string ?? entry.value(at: "deviceProperties.bootState")?.string,
            transport: connection?["transportType"]?.string,
            paired: connection?["pairingState"]?.string == "paired",
            developerModeEnabled: developerMode,
            tunnelAddress: connection?["tunnelIPAddressString"]?.string,
            screenViewingURL: connection?.value(at: "screenViewingURL.relative")?.string,
            hasActionButton: hardware["hasActionButton"]?.bool ?? false,
            capabilities: Set((entry["capabilities"]?.array ?? []).compactMap { $0["featureIdentifier"]?.string })
        )
    }
}
