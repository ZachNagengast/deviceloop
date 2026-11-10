//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Synchronization
import Testing

@testable import DeviceLoopKit

/// Records devicectl arguments and answers them with `answer`.
final class RecordedDevicectl {
    var calls: [[String]] = []
    let answer: ([String]) throws -> JSONValue

    init(_ answer: @escaping ([String]) throws -> JSONValue = { _ in .null }) {
        self.answer = answer
    }

    func call(_ arguments: [String]) throws -> JSONValue {
        calls.append(arguments)
        return try answer(arguments)
    }
}

@Suite struct PrepareTests {
    func device(paired: Bool = true) -> Target {
        Target(
            udid: "00008130-578D60C5D3FFD610",
            identifier: "6812A417-3B91-576A-A4EB-F81FED731A58",
            name: "Test iPhone",
            kind: .device,
            deviceType: "iPhone",
            platform: "iOS",
            model: "iPhone 15 Pro Max",
            productType: "iPhone16,2",
            osVersion: "27.0",
            connectionState: "connected",
            bootState: "booted",
            transport: "wired",
            paired: paired,
            developerModeEnabled: true,
            tunnelAddress: "fd85:efc2:a0aa::1",
            capabilities: [Capability.lockState]
        )
    }

    /// A `devicectl list devices` result with `target` in `pairingState` and connection `state`.
    func listed(_ target: Target, pairingState: String, state: String = "connected") -> JSONValue {
        let properties: JSONValue = [
            "hardware": ["udid": .string(target.udid), "reality": "physical", "platform": "iOS", "deviceType": "iPhone"],
            "connection": ["pairingState": .string(pairingState), "state": .string(state), "transportType": "wired"],
            "state": ["name": .string(target.name), "bootState": "booted", "developerModeStatus": "enabled"],
        ]
        return ["devices": [["identifier": .string(target.identifier), "properties": properties]]]
    }

    func doctor(_ target: Target, _ checks: [DoctorCheck]) -> DoctorReport {
        DoctorReport(
            header: target.summary,
            host: [DoctorCheck("deviceloop team", .ok, "ABCDE12345")],
            targets: [DoctorReport.Section(target, checks: checks)]
        )
    }

    func execution(_ target: Target, _ devicectl: RecordedDevicectl, wait: Int = 0) -> PrepareRun {
        PrepareRun(
            target: target,
            hostDDI: DoctorCheck("host ddi", .ok, "iOS 27B52"),
            wait: wait,
            poll: .milliseconds(1),
            log: { _ in },
            devicectl: { try devicectl.call($0) }
        )
    }

    @Test func readyDeviceHasAnEmptyPlan() {
        let target = device()
        let checks = DoctorReport.stateChecks(target) + [DoctorCheck("lock", .ok, "unlocked"), DoctorCheck("ddi services", .ok, "usable")]
        #expect(PrepareRun.plan(for: target, doctor: doctor(target, checks), runnerLive: true).isEmpty)
    }

    @Test func simulatorWithoutTeamOrRunnerHasAnEmptyPlan() {
        var target = device()
        target.kind = .simulator
        let report = DoctorReport(
            header: target.summary,
            host: [DoctorCheck("deviceloop team", .warn, "none stored", fix: "deviceloop setup", code: .signingNoTeam)],
            targets: [DoctorReport.Section(target, checks: DoctorReport.stateChecks(target))]
        )
        #expect(PrepareRun.plan(for: target, doctor: report, runnerLive: false).isEmpty)
    }

    @Test func unpairedDeviceWaitsForTheOwnerAndBlocksLaterSteps() async throws {
        let target = device(paired: false)
        let plan = PrepareRun.plan(for: target, doctor: doctor(target, DoctorReport.stateChecks(target)), runnerLive: false)
        #expect(plan.map(\.kind) == [.pair, .unlock, .mountDDI, .uiAutomation])
        #expect(plan.first?.owner == true)

        let devicectl = RecordedDevicectl { _ in self.listed(target, pairingState: "unpaired") }
        var execution = execution(target, devicectl)
        let steps = try await execution.run(plan)
        #expect(steps.map(\.status) == [.needsOwner, .blocked, .blocked, .blocked])
        #expect(devicectl.calls == [["list", "devices"]])
    }

    @Test func unpairedDeviceGetsNoPairRequestWithoutThePairOption() async throws {
        let target = device(paired: false)
        var lists = 0
        let devicectl = RecordedDevicectl { _ in
            lists += 1
            return self.listed(target, pairingState: lists < 2 ? "unpaired" : "paired")
        }
        var execution = execution(target, devicectl, wait: 60)
        let steps = try await execution.run([PrepareStep(.pair, on: target)])
        #expect(steps.map(\.status) == [.done])
        #expect(devicectl.calls == [["list", "devices"], ["list", "devices"]])
    }

    @Test func pairOptionRunsManagePairOnAnUnpairedDeviceAndWaitsUntilPaired() async throws {
        let target = device(paired: false)
        var pairingState = "unpaired"
        let devicectl = RecordedDevicectl { arguments in
            guard arguments.first == "list" else {
                pairingState = "paired"
                return [:]
            }
            return self.listed(target, pairingState: pairingState)
        }
        var execution = execution(target, devicectl, wait: 60)
        execution.pair = true
        let steps = try await execution.run([PrepareStep(.pair, on: target)])
        #expect(steps.map(\.status) == [.done])
        #expect(
            devicectl.calls.map { Array($0.prefix(4)) } == [
                ["list", "devices"], ["manage", "pair", "--device", target.udid], ["list", "devices"],
            ])
    }

    @Test func failedPairRequestIsLoggedAndTheOwnerWaitGoesOn() async throws {
        let target = device(paired: false)
        var lists = 0
        let devicectl = RecordedDevicectl { arguments in
            guard arguments.first == "list" else { throw DeviceLoopError(.deviceError, "The pairing request was declined.") }
            lists += 1
            return self.listed(target, pairingState: lists < 3 ? "unpaired" : "paired")
        }
        var lines: [String] = []
        var execution = execution(target, devicectl, wait: 60)
        execution.pair = true
        execution.log = { lines.append($0) }
        let steps = try await execution.run([PrepareStep(.pair, on: target)])
        #expect(steps.map(\.status) == [.done])
        #expect(lines.last == "devicectl manage pair failed: The pairing request was declined.")
        #expect(devicectl.calls.filter { $0.first == "manage" }.count == 1)
    }

    @Test func pairOptionLeavesAPairedDisconnectedDeviceToTheOwner() async throws {
        var target = device()
        target.connectionState = "disconnected"
        var lists = 0
        let devicectl = RecordedDevicectl { _ in
            lists += 1
            return self.listed(target, pairingState: "paired", state: lists < 2 ? "disconnected" : "connected")
        }
        var execution = execution(target, devicectl, wait: 60)
        execution.pair = true
        let steps = try await execution.run([PrepareStep(.pair, on: target)])
        #expect(steps.map(\.status) == [.done])
        #expect(devicectl.calls == [["list", "devices"], ["list", "devices"]])
    }

    @Test func disconnectedDevicePlansUnlockAfterPair() {
        var target = device()
        target.connectionState = "disconnected"
        target.capabilities = []
        let plan = PrepareRun.plan(for: target, doctor: doctor(target, DoctorReport.stateChecks(target)), runnerLive: true)
        #expect(plan.map(\.kind) == [.pair, .unlock, .mountDDI])
    }

    @Test func dryRunCallsNoDevicectl() async throws {
        let target = device(paired: false)
        let plan = PrepareRun.plan(for: target, doctor: doctor(target, DoctorReport.stateChecks(target)), runnerLive: false)
        let devicectl = RecordedDevicectl()
        var execution = execution(target, devicectl)
        #expect(try await execution.run(plan, dryRun: true) == plan)
        #expect(devicectl.calls.isEmpty)
    }

    @Test func ownerStepIsDoneOnceTheDeviceUnlocksAndTheNextStepRuns() async throws {
        let target = device()
        var lockReads = 0
        let devicectl = RecordedDevicectl { arguments in
            guard arguments.contains("lockState") else { return ["ddiMetadata": ["isUsable": true, "buildUpdate": "27B52"]] }
            lockReads += 1
            return ["passcodeRequired": .bool(lockReads < 3), "unlockedSinceBoot": true]
        }
        var execution = execution(target, devicectl, wait: 60)
        let steps = try await execution.run([PrepareStep(.unlock, on: target), PrepareStep(.mountDDI, on: target)])
        #expect(steps.map(\.status) == [.done, .done])
        #expect(lockReads == 3)
        #expect(devicectl.calls.contains(["device", "info", "ddiServices", "-d", target.udid]))
    }

    @Test func mountDDIMountsThenVerifiesWithoutMounting() async throws {
        let target = device()
        let devicectl = RecordedDevicectl { arguments in
            arguments.contains("--no-auto-mount-ddis") ? ["ddiMetadata": ["isUsable": true, "buildUpdate": "27B52"]] : [:]
        }
        var execution = execution(target, devicectl)
        let steps = try await execution.run([PrepareStep(.mountDDI, on: target)])
        #expect(steps.map(\.status) == [.done])
        #expect(steps.first?.detail == "mounted, usable (27B52)")
        #expect(
            devicectl.calls == [
                ["device", "info", "ddiServices", "-d", target.udid],
                ["device", "info", "ddiServices", "-d", target.udid, "--no-auto-mount-ddis"],
            ])
    }

    @Test func mountDDIThatStaysUnmountedFails() async throws {
        let target = device()
        let devicectl = RecordedDevicectl { _ in ["ddiMetadata": ["isUsable": false]] }
        var execution = execution(target, devicectl)
        let step = try #require(try await execution.run([PrepareStep(.mountDDI, on: target)]).first)
        #expect(step.status == .failed)
        #expect(step.detail == "The developer disk image is still not mounted after devicectl tried to mount it.")
        #expect(devicectl.calls.count == 2)
    }

    @Test func missingOrIncompatibleHostImageIsReportedWithoutMounting() async throws {
        let target = device()
        let image: JSONValue = ["buildUpdate": "27B52", "isUsable": true, "contentIsCompatible": false]
        let results: [JSONValue] = [
            ["platforms": [:]],
            ["platforms": ["iOS": [["ddiMetadata": image, "hostDDI": "file:///Library/Developer/DeveloperDiskImages/iOS_DDI/"]]]],
        ]
        var details: [String?] = []
        for result in results {
            let host = DoctorReport.hostDDICheck(result)
            let devicectl = RecordedDevicectl()
            var execution = execution(target, devicectl)
            execution.hostDDI = host
            let step = try #require(try await execution.run([PrepareStep(.mountDDI, on: target)]).first)
            #expect(step.status == .failed)
            #expect(step.fix == host.fix)
            #expect(devicectl.calls.isEmpty)
            details.append(step.detail)
        }
        #expect(
            details == [
                "no iOS developer disk image on this Mac",
                "iOS 27B52 at /Library/Developer/DeveloperDiskImages/iOS_DDI has incompatible content",
            ])
    }

    @Test func dryRunPairStepNamesTheManagePairRequestOnlyWithThePairOption() async throws {
        let target = device(paired: false)
        var instructions: [String] = []
        for pair in [true, false] {
            let plan = PrepareRun.plan(for: target, doctor: doctor(target, DoctorReport.stateChecks(target)), runnerLive: true, pair: pair)
            var execution = execution(target, RecordedDevicectl())
            instructions.append(try #require(try await execution.run(plan, dryRun: true).first { $0.kind == .pair }).instruction)
        }
        #expect(
            instructions == [
                "DeviceLoop runs xcrun devicectl manage pair --device 00008130-578D60C5D3FFD610. "
                    + "On Test iPhone tap Trust and enter the passcode.",
                "Connect Test iPhone with a cable, unlock it, tap Trust and enter the passcode.",
            ])
    }

    @Test func severalTargetsPrintTheHostChecksOnceAfterTheHeader() {
        var second = device()
        second.udid = "00008110-001A2C3E0A12801E"
        second.name = "Second iPhone"
        let reports = [device(), second].map { target in
            let checks = DoctorReport.stateChecks(target) + [DoctorCheck("ddi services", .warn, "developer disk image not mounted")]
            return PrepareReport(target: target, steps: [], doctor: doctor(target, checks))
        }
        let expected = [
            SetupCommands.hostSummary,
            "ok   deviceloop team: ABCDE12345",
            "Test iPhone (device, iOS 27.0)",
            "plan: nothing to do",
            "ok   pairing: paired",
            "ok   developer mode: enabled",
            "ok   connection: connected over USB",
            "ok   tunnel: fd85:efc2:a0aa::1",
            "warn ddi services: developer disk image not mounted",
            "0 failed, 1 warnings",
            "ready",
            "Second iPhone (device, iOS 27.0)",
            "plan: nothing to do",
            "ok   pairing: paired",
            "ok   developer mode: enabled",
            "ok   connection: connected over USB",
            "ok   tunnel: fd85:efc2:a0aa::1",
            "warn ddi services: developer disk image not mounted",
            "0 failed, 1 warnings",
            "ready",
        ]
        #expect(PrepareCommands.text(reports, dryRun: false).split(separator: "\n").map(String.init) == expected)
    }

    @Test func prefixedLogNamesTheTarget() {
        let lines = Mutex<[String]>([])
        let log = PrepareCommands.prefixedLog({ line in lines.withLock { $0.append(line) } }, for: device())
        log("starting runner")
        #expect(lines.withLock { $0 } == ["Test iPhone: starting runner"])
    }

    @Test func planHasNoStepThatUnpairsCleansResetsOrChangesAPasscode() {
        let kinds = PrepareStep.Kind.allCases.map(\.rawValue)
        #expect(kinds == ["pair", "developerMode", "unlock", "mountDDI", "signingTeam", "uiAutomation"])
    }
}
