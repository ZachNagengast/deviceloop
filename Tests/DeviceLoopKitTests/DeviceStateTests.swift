//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Synchronization
import Testing

@testable import DeviceLoopKit

private func recorded(_ name: String) throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: "Resources/devicectl/\(name)", withExtension: "json"))
    return try #require(try JSONValue(data: Data(contentsOf: url))["result"])
}

/// Answers `devicectl device info appearance` with `info-appearance-simulator.json` and so on.
private let recordedDevicectl: DeviceState.DevicectlRead = { arguments in
    try recorded("\(arguments[1])-\(arguments[2])-simulator")
}

private let recordedSimctl: DeviceState.SimctlRead = { _ in
    let url = try #require(Bundle.module.url(forResource: "Resources/devicectl/simctl-status-bar-list", withExtension: "txt"))
    return try String(contentsOf: url, encoding: .utf8)
}

private let simulatorCapabilities: Set<String> = [
    Capability.uiStyle, Capability.orientation, Capability.voiceOver, Capability.audioOutput, Capability.statusBar,
    Capability.pasteboard,
]

private func target(kind: Target.Kind = .simulator, bootState: String = "booted", capabilities: Set<String>) -> Target {
    Target(
        udid: "00000000-0000-0000-0000-000000000000",
        identifier: "00000000-0000-0000-0000-000000000000",
        name: "Test Target",
        kind: kind,
        deviceType: "iPhone",
        platform: "iOS",
        model: "iPhone 17 Pro",
        productType: "iPhone18,1",
        osVersion: "27.0",
        osBuild: "24A434",
        connectionState: bootState == "booted" ? "connected" : "disconnected",
        bootState: bootState,
        capabilities: capabilities
    )
}

@Suite struct DeviceStateTests {
    @Test func recordedSimulatorReadsAreObserved() async throws {
        let state = await DeviceState.capture(
            target(capabilities: simulatorCapabilities), devicectl: recordedDevicectl, simctl: recordedSimctl)
        let expected: [String: JSONValue] = [
            "userInterfaceStyle": "light", "textSize": "Large", "largerAccessibilitySizesEnabled": false, "increaseContrast": false,
            "reduceMotion": false, "reduceTransparency": false, "showBorders": false, "colorFilter": false,
            "orientation": "portrait", "voiceOver": false, "volume": 60, "osBuild": "24A434",
            "statusBarOverrides": [
                "Time: 9:41", "DataNetworkType: 1", "WiFi Mode: 3, WiFi Bars: 2", "Battery State: 2, Battery Level: 80, Not Charging: 0",
            ],
        ]
        for (name, value) in expected {
            let field = try #require(state.fields[name])
            #expect(field.value == value, "\(name)")
            #expect(field.availability == .observed, "\(name)")
            #expect(field.observedAt != nil, "\(name)")
        }
        #expect(state.schema == "deviceloop.device-state/1")
        #expect(state.fields["userInterfaceStyle"]?.source == "devicectl device info appearance")
    }

    @Test func missingCapabilityIsUnsupported() async {
        let state = await DeviceState.capture(
            target(capabilities: [Capability.uiStyle]), devicectl: recordedDevicectl, simctl: recordedSimctl)
        #expect(state.fields["voiceOver"]?.availability == .unsupported)
        #expect(state.fields["voiceOver"]?.reason == "missing capability \(Capability.voiceOver)")
        #expect(state.fields["voiceOver"]?.value == nil)
    }

    @Test func thrownDevicectlErrorIsUnknown() async {
        let failing: DeviceState.DevicectlRead = { _ in throw DeviceLoopError(.deviceError, "devicectl timed out.") }
        let state = await DeviceState.capture(target(capabilities: simulatorCapabilities), devicectl: failing, simctl: recordedSimctl)
        #expect(state.fields["userInterfaceStyle"]?.availability == .unknown)
        #expect(state.fields["userInterfaceStyle"]?.reason == "devicectl timed out.")
        #expect(state.fields["voiceOver"]?.value == nil)
    }

    @Test func keyMissingFromResultIsUnknown() async {
        let styleOnly: DeviceState.DevicectlRead = { _ in ["userInterfaceStyle": "dark"] }
        let state = await DeviceState.capture(target(capabilities: [Capability.uiStyle]), devicectl: styleOnly, simctl: recordedSimctl)
        #expect(state.fields["userInterfaceStyle"]?.value == "dark")
        #expect(state.fields["textSize"]?.availability == .unknown)
        #expect(state.fields["textSize"]?.reason == "devicectl device info appearance did not report it")
    }

    @Test func pasteboardIsNeverRead() async throws {
        let commands = Mutex<[String]>([])
        let logging: DeviceState.DevicectlRead = { arguments in
            commands.withLock { $0.append(arguments.joined(separator: " ")) }
            return try await recordedDevicectl(arguments)
        }
        let state = await DeviceState.capture(target(capabilities: simulatorCapabilities), devicectl: logging, simctl: recordedSimctl)
        #expect(!commands.withLock { $0 }.contains { $0.contains("pasteboard") })
        #expect(state.fields["pasteboard"]?.value == nil)
        #expect(state.fields["pasteboard"]?.availability == .unknown)
    }

    @Test func lockedDeviceKeepsLockStateObserved() async {
        let locked: DeviceState.DevicectlRead = { arguments in
            guard arguments.contains("lockState") else { throw DeviceLoopError(.deviceLocked, "Test Target is locked.") }
            return ["passcodeRequired": true, "unlockedSinceBoot": true, "deviceIdentifier": "x"]
        }
        let phone = target(kind: .device, capabilities: [Capability.lockState, Capability.uiStyle])
        let state = await DeviceState.capture(phone, devicectl: locked, simctl: recordedSimctl)
        #expect(state.fields["lockState"]?.value == ["passcodeRequired": true, "unlockedSinceBoot": true])
        #expect(state.fields["userInterfaceStyle"]?.availability == .unavailable)
    }

    @Test func shutdownTargetReadsNothing() async {
        let calls = Mutex(0)
        let counting: DeviceState.DevicectlRead = { arguments in
            calls.withLock { $0 += 1 }
            return try await recordedDevicectl(arguments)
        }
        let state = await DeviceState.capture(
            target(bootState: "shutdown", capabilities: simulatorCapabilities), devicectl: counting, simctl: recordedSimctl)
        #expect(calls.withLock { $0 } == 0)
        #expect(state.fields["orientation"]?.availability == .unavailable)
        #expect(state.fields["ready"]?.value == false)
    }

    @Test func emptyStatusBarListHasNoOverrides() {
        #expect(DeviceState.statusBarOverrides("Current Status Bar Overrides:\n=============================\n") == [])
    }

    @Test func orientationFallsBackToNonFlat() throws {
        #expect(SettingsCommands.currentOrientation(try recorded("orientation-get-simulator")) == "portrait")
    }
}

/// Runs against a booted simulator: DEVICELOOP_TEST_SIMULATOR=<udid> xcrun swift test --filter DeviceStateLiveTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEVICELOOP_TEST_SIMULATOR"] != nil), .sharedSimulator)
struct DeviceStateLiveTests {
    @Test func captureObservesSimulatorSettings() async throws {
        let target = try await TargetResolver.resolve(ProcessInfo.processInfo.environment["DEVICELOOP_TEST_SIMULATOR"])
        let state = await DeviceState.capture(target)
        for name in ["userInterfaceStyle", "textSize", "orientation", "voiceOver", "volume", "statusBarOverrides", "osBuild"] {
            #expect(state.fields[name]?.availability == .observed, "\(name): \(state.fields[name]?.reason ?? "")")
        }
    }
}
