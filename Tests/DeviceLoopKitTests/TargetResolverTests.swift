//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct TargetResolverTests {
    let targets: [Target]

    init() throws {
        let url = try #require(Bundle.module.url(forResource: "Resources/devicectl/list-devices", withExtension: "json"))
        let json = try JSONValue(data: Data(contentsOf: url))
        targets = (json.value(at: "result.devices")?.array ?? []).compactMap(Target.init(devicectl:))
    }

    @Test func decodesDevicesAndSimulators() throws {
        let iPhone = try #require(targets.first { $0.name == "Test iPhone 15 Pro Max" })
        #expect(iPhone.kind == .device)
        #expect(iPhone.osVersion == "27.0")
        #expect(iPhone.tunnelAddress == "fd85:efc2:a0aa::1")
        #expect(iPhone.isReady)
        #expect(iPhone.supports(Capability.screenshot))
        #expect(!iPhone.supports(Capability.screenRecording))

        let simulator = try #require(targets.first { $0.name == "iPhone Duo" })
        #expect(simulator.kind == .simulator)
        #expect(simulator.bootState == "booted")
        #expect(simulator.supports(Capability.screenRecording))
    }

    @Test func devicesRowsCarryIdentityAndTransport() throws {
        let names = ["Test iPhone 13 Pro", "Test iPhone 17 Pro Max", "iPhone Duo"]
        let rows = try names.map { name in DeviceCommands.TargetRow(try #require(targets.first { $0.name == name })) }
        #expect(Set(rows.map(\.udid)).count == 3)
        #expect(Set(rows.map(\.identifier)).count == 3)
        #expect(rows[0].udid != rows[0].identifier && rows[1].udid != rows[1].identifier)
        #expect(rows.map(\.transport) == ["wired", "localNetwork", "sameMachine"])
    }

    @Test func unavailableDeviceRowIsNotReadyWithAReason() throws {
        let row = DeviceCommands.TargetRow(try #require(targets.first { $0.name == "Test iPhone 11" }))
        #expect(row.connectionState == "unavailable")
        #expect(!row.ready)
        #expect(row.notReadyReasons == ["device is unavailable"])
    }

    @Test func nameSharedByTwoReadyTargetsIsAmbiguous() throws {
        let renamed = targets.map { target in
            var target = target
            if target.name == "Test iPhone 15 Pro Max" { target.name = "iPhone Duo" }
            return target
        }
        let phone = try #require(targets.first { $0.name == "Test iPhone 15 Pro Max" })
        let simulator = try #require(targets.first { $0.name == "iPhone Duo" })
        let error = #expect(throws: DeviceLoopError.self) { try TargetResolver.resolve("iPhone Duo", in: renamed) }
        #expect(error?.code == .deviceAmbiguous)
        #expect(error?.alternatives.sorted() == ["iPhone Duo [\(phone.udid)]", "iPhone Duo [\(simulator.udid)]"].sorted())
    }

    @Test func decodesOSBuild() throws {
        let phone = try #require(targets.first { $0.name == "Test iPhone 13 Pro" })
        #expect(phone.osBuild == "22H352")
    }

    @Test func decodesOSBuildFromEitherField() {
        #expect(targets.first { $0.name == "Test iPhone 15 Pro Max" }?.osBuild == "24A5424a")
        #expect(targets.first { $0.name == "iPhone 18 Pro" && $0.osVersion == "27.0" }?.osBuild == "24A434")
    }

    @Test func connectingDeviceIsReadAgainUntilItConnects() async throws {
        let phone = try #require(targets.first { $0.name == "Test iPhone 15 Pro Max" })
        var connecting = phone
        connecting.connectionState = "connecting"
        let listings = [[connecting], [connecting], [phone]]
        var calls = 0
        let target = try await TargetResolver.resolve(phone.udid) {
            calls += 1
            return listings[min(calls, listings.count) - 1]
        }
        #expect(calls == 3)
        #expect(target.isReady)
    }

    @Test func disconnectedDeviceIsReadAgainRightAfterACapture() async throws {
        let phone = try #require(targets.first { $0.name == "Test iPhone 15 Pro Max" })
        var dropped = phone
        dropped.connectionState = "disconnected"
        let listings = [[dropped], [phone]]
        var calls = 0
        let target = try await TargetResolver.resolve(
            phone.udid,
            list: {
                calls += 1
                return listings[min(calls, listings.count) - 1]
            },
            lastCaptureEnded: Date().timeIntervalSince1970)
        #expect(calls == 2)
        #expect(target.isReady)
    }

    @Test func disconnectedDeviceWithoutARecentCaptureIsNotWaitedFor() async throws {
        var dropped = try #require(targets.first { $0.name == "Test iPhone 15 Pro Max" })
        dropped.connectionState = "disconnected"
        var calls = 0
        _ = try await TargetResolver.resolve(
            dropped.udid,
            list: {
                calls += 1
                return [dropped]
            },
            lastCaptureEnded: nil)
        #expect(calls == 1)
    }

    @Test func usbSelectorWaitsForADeviceThatDroppedAfterACapture() async throws {
        let phone = try #require(targets.first { $0.name == "Test iPhone 15 Pro Max" })
        var dropped = phone
        dropped.connectionState = "disconnected"
        let listings = [[dropped], [phone]]
        var calls = 0
        let target = try await TargetResolver.resolve(
            "usb",
            list: {
                calls += 1
                return listings[min(calls, listings.count) - 1]
            },
            lastCaptureEnded: Date().timeIntervalSince1970)
        #expect(calls == 2)
        #expect(target.udid == phone.udid)
    }

    @Test func unmatchedSelectorWithoutARecentCaptureFailsAtOnce() async throws {
        var dropped = try #require(targets.first { $0.name == "Test iPhone 15 Pro Max" })
        dropped.connectionState = "disconnected"
        var calls = 0
        let error = await #expect(throws: DeviceLoopError.self) {
            try await TargetResolver.resolve(
                "usb",
                list: {
                    calls += 1
                    return [dropped]
                },
                lastCaptureEnded: nil)
        }
        #expect(error?.code == .deviceNotFound)
        #expect(calls == 1)
    }

    @Test func networkListingRightAfterACaptureIsReadAgainUntilWired() async throws {
        let phone = try #require(targets.first { $0.name == "Test iPhone 15 Pro Max" })
        var onNetwork = phone
        onNetwork.transport = "localNetwork"
        let listings = [[onNetwork], [phone]]
        var calls = 0
        let target = try await TargetResolver.resolve(
            phone.name,
            list: {
                calls += 1
                return listings[min(calls, listings.count) - 1]
            },
            lastCaptureEnded: Date().timeIntervalSince1970)
        #expect(calls == 2)
        #expect(target.transport == "wired")
    }

    @Test func networkDeviceIsUsedWhenTheWaitRunsOut() async throws {
        let phone = try #require(targets.first { $0.name == "Test iPhone 17 Pro Max" && $0.kind == .device })
        var calls = 0
        let target = try await TargetResolver.resolve(
            phone.udid,
            list: {
                calls += 1
                return [phone]
            },
            connecting: .zero,
            lastCaptureEnded: Date().timeIntervalSince1970)
        #expect(calls == 1)
        #expect(target.transport == "localNetwork")
    }

    @Test func picksExactNameOverSubstring() throws {
        let target = try TargetResolver.resolve("iPhone 17 Pro Max", in: targets)
        #expect(target.kind == .simulator)
    }

    @Test func resolvesByUDIDPrefix() throws {
        let target = try TargetResolver.resolve("00008130", in: targets)
        #expect(target.name == "Test iPhone 15 Pro Max")
    }

    @Test func usbSelectorRequiresOneConnectedDevice() {
        let error = #expect(throws: DeviceLoopError.self) { try TargetResolver.resolve("usb", in: targets) }
        #expect(error?.code == .deviceAmbiguous)
    }

    @Test func usbSelectorSkipsNetworkDevices() throws {
        let twoPhones = targets.filter { ["Test iPhone 15 Pro Max", "Test iPhone 17 Pro Max"].contains($0.name) }
        #expect(try TargetResolver.resolve("usb", in: twoPhones).name == "Test iPhone 15 Pro Max")
        let error = #expect(throws: DeviceLoopError.self) { try TargetResolver.resolve("device", in: twoPhones) }
        #expect(error?.code == .deviceAmbiguous)
    }

    @Test func nameMatchesWithStraightApostrophe() throws {
        var phone = try #require(targets.first { $0.name == "Test iPhone 15 Pro Max" })
        phone.name = "Ana\u{2019}s\u{00A0}iPhone"
        #expect(try TargetResolver.resolve("ana's iphone", in: [phone]).udid == phone.udid)
        #expect(try TargetResolver.resolve("Ana's", in: [phone]).udid == phone.udid)
    }

    @Test func noSelectorWithSeveralReadyTargetsIsAmbiguous() {
        let error = #expect(throws: DeviceLoopError.self) { try TargetResolver.resolve(nil, in: targets) }
        #expect(error?.code == .deviceAmbiguous)
        #expect(error?.alternatives.isEmpty == false)
    }

    @Test func noMatchPointsAtTheFullDeviceList() {
        let notReady = targets.filter { !$0.isReady }
        #expect(!notReady.isEmpty)
        for selector in [nil, "no such device"] {
            let error = #expect(throws: DeviceLoopError.self) { try TargetResolver.resolve(selector, in: notReady) }
            #expect(error?.code == .deviceNotFound)
            #expect(error?.fix?.contains("`deviceloop devices --all`") == true)
            #expect(error?.fix?.contains("simctl boot") == (selector == nil))
        }
    }

    @Test func watchIsNotDrivable() {
        let error = #expect(throws: DeviceLoopError.self) { try TargetResolver.resolve("Test Apple Watch", in: targets) }
        #expect(error?.code == .deviceNotFound)
    }

    @Test func devicesNamesTheTargetDeviceLoopDeviceSelects() throws {
        let iPhone = try #require(targets.first { $0.name == "Test iPhone 13 Pro" })
        let listed = try DeviceCommands.list(all: true, targets: targets, selector: "Test iPhone 13 Pro")
        #expect(listed.json["defaultDevice"] == .string(iPhone.udid))
        #expect(listed.text.split(separator: "\n").first?.hasSuffix(", DEVICELOOP_DEVICE picks Test iPhone 13 Pro") == true)
        for unset in [nil, "", "  "] {
            let listed = try DeviceCommands.list(all: true, targets: targets, selector: unset)
            #expect(listed.json["defaultDevice"] == nil && listed.json["defaultDeviceError"] == nil)
            #expect(!listed.text.contains("DEVICELOOP_DEVICE"))
        }
    }

    @Test func devicesSaysWhenDeviceLoopDeviceMatchesNoTargetOrSeveral() throws {
        let missing = try DeviceCommands.list(all: true, targets: targets, selector: "no such device")
        #expect(missing.json["defaultDevice"] == nil)
        #expect(missing.json["defaultDeviceError"] == "device_not_found")
        #expect(missing.text.split(separator: "\n").first?.hasSuffix(#", DEVICELOOP_DEVICE "no such device" matches no target"#) == true)
        let several = try DeviceCommands.list(all: true, targets: targets, selector: "Test iPhone")
        #expect(several.json["defaultDeviceError"] == "device_ambiguous")
        #expect(several.text.split(separator: "\n").first?.hasSuffix(#", DEVICELOOP_DEVICE "Test iPhone" matches several targets"#) == true)
    }
}
