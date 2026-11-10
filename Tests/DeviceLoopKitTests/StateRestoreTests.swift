//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

final class FakeSettings {
    var values: [String: JSONValue]
    var reads = 0
    var sets: [String] = []
    var readError: DeviceLoopError?
    var setSticks = true

    init(_ values: [String: JSONValue]) {
        self.values = values
    }

    /// Location has no inverse, like on a real target.
    func inverse(_ field: String) -> ChangeJournal.Inverse? {
        guard field != "location" else { return nil }
        return ChangeJournal.Inverse(
            read: {
                self.reads += 1
                if let error = self.readError { throw error }
                return self.values[field]
            },
            set: { value in
                self.sets.append(field)
                if self.setSticks { self.values[field] = value }
            }
        )
    }
}

private func target(
    udid: String = "00000000-0000-0000-0000-000000000000", bootState: String = "booted",
    capabilities: Set<String> = [Capability.uiStyle, Capability.orientation]
) -> Target {
    Target(
        udid: udid,
        identifier: udid,
        name: "Test Target",
        kind: .simulator,
        deviceType: "iPhone",
        platform: "iOS",
        model: "iPhone 17 Pro",
        productType: "iPhone18,1",
        osVersion: "27.0",
        connectionState: bootState == "booted" ? "connected" : "disconnected",
        bootState: bootState,
        capabilities: capabilities
    )
}

@Suite struct StateRestoreTests {
    let settings = FakeSettings(["userInterfaceStyle": "light", "orientation": "portrait"])

    private func scope(
        udid: String = "00000000-0000-0000-0000-000000000000",
        directory: URL = Paths.home.appending(path: "restore-tests/\(UUID().uuidString)"),
        strict: Bool = false,
        _ body: (ChangeJournal) async throws -> Void
    ) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ChangeJournal(directory: directory)
        _ = try await journal.start(strict: strict) { DeviceState(udid: udid, capturedAt: "2026-11-08T10:00:00.000Z", fields: [:]) }
        try await body(journal)
    }

    /// Journals a change of `field` to `requested`. `dispatch` false leaves a change line without an applied line.
    private func change(
        _ journal: ChangeJournal, _ field: String, to requested: JSONValue, dispatch: Bool = true, interrupted: Bool = false
    ) async throws {
        _ = try? await journal.record(
            field: field, requested: requested, source: "test", read: { self.settings.values[field] },
            dispatch: {
                if dispatch { self.settings.values[field] = requested }
                if !dispatch || interrupted { throw DeviceLoopError(.deviceError, "interrupted") }
                return CommandResult(text: "Test Target")
            }
        )
    }

    private func restore(
        _ journal: ChangeJournal, on target: Target = target(), dryRun: Bool = false, overwriteConflicts: Bool = false,
        acceptResidual: Bool = false, clearLocation: (() async throws -> Void)? = nil
    ) async throws -> CommandResult {
        try await StateCommands.restore(
            target, journal: journal, dryRun: dryRun, overwriteConflicts: overwriteConflicts, acceptResidual: acceptResidual,
            clearLocation: clearLocation, inverse: settings.inverse)
    }

    private func outcomes(_ journal: ChangeJournal) throws -> [ChangeJournal.Cleanup.Outcome] {
        try JSONDecoder().decode(ChangeJournal.Cleanup.self, from: Data(contentsOf: journal.cleanupFile)).changes.map(\.outcome)
    }

    @Test func restoresNewestChangeFirst() async throws {
        try await scope { journal in
            try await change(journal, "userInterfaceStyle", to: "dark")
            try await change(journal, "orientation", to: "landscapeLeft")
            _ = try await restore(journal)
            #expect(settings.sets == ["orientation", "userInterfaceStyle"])
            #expect(settings.values == ["userInterfaceStyle": "light", "orientation": "portrait"])
            #expect(try outcomes(journal) == [.restored, .restored])
        }
    }

    @Test func cleanRestoreClosesTheScope() async throws {
        try await scope { journal in
            try await change(journal, "userInterfaceStyle", to: "dark")
            let result = try await restore(journal)
            #expect(!journal.isOpen)
            #expect(result.json["closed"] == true)
            let closed = try #require(result.json["journal"]?.string)
            #expect(FileManager.default.fileExists(atPath: closed))
        }
    }

    @Test func restoreOfOneChangeCountsItInTheSingular() async throws {
        try await scope { journal in
            try await change(journal, "userInterfaceStyle", to: "dark")
            let result = try await restore(journal)
            #expect(result.text.split(separator: "\n")[1] == "1 change: 1 restored")
        }
    }

    @Test func outsideChangeIsAConflictLeftInPlace() async throws {
        try await scope { journal in
            try await change(journal, "userInterfaceStyle", to: "dark")
            settings.values["userInterfaceStyle"] = "light"
            let error = await #expect(throws: DeviceLoopError.self) { try await restore(journal) }
            #expect(error?.code == .cleanupIncomplete)
            #expect(error?.exitCode == 7)
            #expect(settings.sets.isEmpty)
            #expect(journal.isOpen)
            #expect(try outcomes(journal) == [.conflict])
        }
    }

    @Test func secondRestoreReportsRestoredChangesUnchanged() async throws {
        try await scope { journal in
            try await change(journal, "userInterfaceStyle", to: "dark")
            try await change(journal, "orientation", to: "landscapeLeft")
            settings.values["userInterfaceStyle"] = "light"
            await #expect(throws: DeviceLoopError.self) { try await restore(journal) }
            #expect(try outcomes(journal) == [.restored, .conflict])
            await #expect(throws: DeviceLoopError.self) { try await restore(journal) }
            #expect(try outcomes(journal) == [.unchanged, .conflict])
            #expect(settings.sets == ["orientation"])
        }
    }

    @Test func olderChangeOfAConflictingFieldIsLeftInPlace() async throws {
        try await scope { journal in
            try await change(journal, "userInterfaceStyle", to: "dark")
            try await change(journal, "userInterfaceStyle", to: "light")
            settings.values["userInterfaceStyle"] = "dark"
            await #expect(throws: DeviceLoopError.self) { try await restore(journal) }
            #expect(settings.sets.isEmpty)
            #expect(try outcomes(journal) == [.conflict, .conflict])
        }
    }

    @Test func overwriteConflictsSetsTheFieldBack() async throws {
        try await scope { journal in
            try await change(journal, "orientation", to: "landscapeLeft")
            settings.values["orientation"] = "landscapeRight"
            _ = try await restore(journal, overwriteConflicts: true)
            #expect(settings.values["orientation"] == "portrait")
            #expect(try outcomes(journal) == [.restored])
        }
    }

    @Test func acceptResidualClosesTheScopeWithAConflict() async throws {
        try await scope { journal in
            try await change(journal, "orientation", to: "landscapeLeft")
            settings.values["orientation"] = "landscapeRight"
            _ = try await restore(journal, acceptResidual: true)
            #expect(settings.values["orientation"] == "landscapeRight")
            #expect(!journal.isOpen)
            #expect(try outcomes(journal) == [.conflict])
        }
    }

    @Test func unobservedOriginalIsUnknown() async throws {
        try await scope { journal in
            settings.values["userInterfaceStyle"] = nil
            try await change(journal, "userInterfaceStyle", to: "dark")
            await #expect(throws: DeviceLoopError.self) { try await restore(journal) }
            #expect(settings.sets.isEmpty)
            #expect(try outcomes(journal) == [.unknown])
        }
    }

    @Test func fieldWithoutAnInverseIsUnsupported() async throws {
        try await scope { journal in
            try await change(journal, "location", to: ["latitude": 37.3349, "longitude": -122.009])
            let error = await #expect(throws: DeviceLoopError.self) { try await restore(journal) }
            #expect(try outcomes(journal) == [.unsupported])
            #expect(
                error?.fix
                    == "Run it again with --clear-location to clear the simulated location, or --accept-residual to leave these "
                    + "fields as they are.")
        }
    }

    @Test func clearLocationClearsWithoutClaimingARestore() async throws {
        try await scope { journal in
            try await change(journal, "location", to: ["latitude": 37.3349, "longitude": -122.009])
            var clears = 0
            let result = try await restore(journal, clearLocation: { clears += 1 })
            #expect(clears == 1)
            #expect(try outcomes(journal) == [.cleared])
            #expect(result.json.value(at: "changes")?.array?.first?["original"] == nil)
            #expect(!journal.isOpen)
        }
    }

    @Test func locationClearedByARestoreIsNotPending() async throws {
        try await scope { journal in
            try await change(journal, "location", to: ["latitude": 37.3349, "longitude": -122.009])
            try await change(journal, "userInterfaceStyle", to: "dark")
            settings.values["userInterfaceStyle"] = "light"
            let error = await #expect(throws: DeviceLoopError.self) { try await restore(journal, clearLocation: {}) }
            #expect(error?.code == .cleanupIncomplete)
            #expect(ChangeJournal.pending(try journal.lines().entries).map(\.field) == ["userInterfaceStyle"])
        }
    }

    @Test func locationClearedByARestoreIsNotClearedAgain() async throws {
        try await scope { journal in
            try await change(journal, "location", to: ["latitude": 37.3349, "longitude": -122.009])
            try await change(journal, "userInterfaceStyle", to: "dark")
            settings.values["userInterfaceStyle"] = "light"
            var clears = 0
            await #expect(throws: DeviceLoopError.self) { try await restore(journal, clearLocation: { clears += 1 }) }
            _ = try await restore(journal, overwriteConflicts: true)
            #expect(clears == 1)
            #expect(try outcomes(journal) == [.restored, .cleared])
            #expect(!journal.isOpen)
        }
    }

    @Test func locationWithAnotherUnsupportedFieldSuggestsClearLocationWithAcceptResidual() async throws {
        try await scope { journal in
            try await change(journal, "location", to: ["latitude": 37.3349, "longitude": -122.009])
            try await change(journal, "wifi", to: "off")
            let error = await #expect(throws: DeviceLoopError.self) {
                try await StateCommands.restore(
                    target(), journal: journal, dryRun: false, overwriteConflicts: false, acceptResidual: false
                ) { _ in nil }
            }
            #expect(
                error?.fix
                    == "Run it again with --clear-location --accept-residual to clear the simulated location and leave the other "
                    + "fields as they are, or --accept-residual to leave all of them.")
        }
    }

    @Test func strictScopeRefusesLocationBeforeDevicectl() async throws {
        let udid = UUID().uuidString
        try await scope(udid: udid, directory: ChangeJournal(udid: udid).directory, strict: true) { journal in
            let simulator = target(udid: udid, capabilities: [Capability.simulateLocation])
            let error = await #expect(throws: DeviceLoopError.self) {
                try await SettingsCommands.location(simulator, latitude: 37.3349, longitude: -122.009)
            }
            #expect(error?.code == .unsupportedOnTarget)
            #expect(error?.message.contains("strict state scope") == true)
            let entries = try journal.lines().entries
            #expect(entries.isEmpty)
        }
    }

    @Test func strictScopeRefusesSystemControlBeforeTheRunner() async throws {
        let udid = UUID().uuidString
        try await scope(udid: udid, directory: ChangeJournal(udid: udid).directory, strict: true) { journal in
            let error = await #expect(throws: DeviceLoopError.self) {
                try await SiriCommands.toggle(target(udid: udid), .wifi, on: false)
            }
            #expect(error?.code == .unsupportedOnTarget)
            #expect(error?.message.contains("strict state scope") == true)
            let entries = try journal.lines().entries
            #expect(entries.isEmpty)
        }
    }

    @Test func systemControlOnAShutDownSimulatorLeavesNoEntries() async throws {
        let udid = UUID().uuidString
        try await scope(udid: udid, directory: ChangeJournal(udid: udid).directory) { journal in
            let error = await #expect(throws: DeviceLoopError.self) {
                try await SiriCommands.toggle(target(udid: udid, bootState: "shutdown"), .wifi, on: false)
            }
            #expect(error?.code == .deviceOffline)
            let entries = try journal.lines().entries
            #expect(entries.isEmpty)
        }
    }

    @Test func systemControlInAPermissiveScopeIsUnsupportedAtRestore() async throws {
        let udid = UUID().uuidString
        let simulator = target(udid: udid, bootState: "shutdown")
        try await scope(udid: udid, directory: ChangeJournal(udid: udid).directory) { journal in
            _ = try await journal.record(field: "brightness", requested: 40, unreadable: "DeviceLoop cannot read brightness back.") {
                CommandResult(text: "Test Target")
            }
            let error = await #expect(throws: DeviceLoopError.self) {
                try await StateCommands.restore(
                    simulator, journal: journal, dryRun: false, overwriteConflicts: false, acceptResidual: false
                ) { SettingsCommands.inverse($0, on: simulator) }
            }
            #expect(error?.code == .cleanupIncomplete)
            let cleanup = try JSONDecoder().decode(ChangeJournal.Cleanup.self, from: Data(contentsOf: journal.cleanupFile))
            #expect(cleanup.changes.map(\.field) == ["brightness"])
            #expect(cleanup.changes.map(\.outcome) == [.unsupported])
            #expect(journal.isOpen)
        }
    }

    @Test func setterThatDoesNotStickFails() async throws {
        try await scope { journal in
            try await change(journal, "userInterfaceStyle", to: "dark")
            settings.setSticks = false
            await #expect(throws: DeviceLoopError.self) { try await restore(journal) }
            #expect(try outcomes(journal) == [.failed])
        }
    }

    @Test func requestOnlyEntryAtItsOriginalIsUnchangedWithoutASetter() async throws {
        try await scope { journal in
            try await change(journal, "userInterfaceStyle", to: "dark", dispatch: false)
            _ = try await restore(journal)
            #expect(settings.sets.isEmpty)
            #expect(try outcomes(journal) == [.unchanged])
            #expect(!journal.isOpen)
        }
    }

    @Test func interruptedEntryAtTheRequestedValueIsRestored() async throws {
        try await scope { journal in
            try await change(journal, "userInterfaceStyle", to: "dark", interrupted: true)
            _ = try await restore(journal)
            #expect(settings.values["userInterfaceStyle"] == "light")
            #expect(try outcomes(journal) == [.restored])
        }
    }

    @Test func offlineTargetKeepsTheJournalAndNeedsTheOwner() async throws {
        try await scope { journal in
            try await change(journal, "userInterfaceStyle", to: "dark")
            settings.reads = 0
            let error = await #expect(throws: DeviceLoopError.self) { try await restore(journal, on: target(bootState: "shutdown")) }
            #expect(error?.code == .cleanupIncomplete)
            #expect(error?.fix?.hasPrefix("Boot Test Target") == true)
            #expect(settings.reads == 0)
            #expect(journal.isOpen)
            #expect(try outcomes(journal) == [.needsOwnerAction])
        }
    }

    @Test func lockedReadNeedsTheOwner() async throws {
        try await scope { journal in
            try await change(journal, "userInterfaceStyle", to: "dark")
            settings.readError = DeviceLoopError(.deviceLocked, "Test Target is locked.")
            await #expect(throws: DeviceLoopError.self) { try await restore(journal) }
            #expect(try outcomes(journal) == [.needsOwnerAction])
        }
    }

    @Test func dryRunSetsAndWritesNothing() async throws {
        try await scope { journal in
            try await change(journal, "userInterfaceStyle", to: "dark")
            let result = try await restore(journal, dryRun: true)
            #expect(settings.sets.isEmpty)
            #expect(journal.isOpen)
            #expect(!FileManager.default.fileExists(atPath: journal.cleanupFile.path))
            #expect(result.json.value(at: "changes")?.array?.first?["outcome"] == "wouldRestore")
        }
    }

    @Test func journalOfAnotherTargetIsRefused() async throws {
        try await scope(udid: "11111111-1111-1111-1111-111111111111") { journal in
            try await change(journal, "userInterfaceStyle", to: "dark")
            settings.reads = 0
            let error = await #expect(throws: DeviceLoopError.self) { try await restore(journal) }
            #expect(error?.code == .badArguments)
            #expect(settings.reads == 0)
        }
    }

    @Test func doctorListsPendingChanges() async throws {
        let udid = UUID().uuidString
        try await scope(udid: udid, directory: ChangeJournal(udid: udid).directory) { journal in
            try await change(journal, "userInterfaceStyle", to: "dark")
            let check = try #require(DoctorReport.scopeCheck(target(udid: udid)))
            #expect(check.status == .warn)
            #expect(check.detail.hasSuffix(": userInterfaceStyle"))
            #expect(check.fix == "deviceloop state restore --device \(udid)")
        }
    }

    @Test func doctorLeavesOutRestoredChanges() async throws {
        let udid = UUID().uuidString
        try await scope(udid: udid, directory: ChangeJournal(udid: udid).directory) { journal in
            try await change(journal, "userInterfaceStyle", to: "dark")
            try await change(journal, "orientation", to: "landscapeLeft")
            settings.values["userInterfaceStyle"] = "light"
            await #expect(throws: DeviceLoopError.self) { try await restore(journal, on: target(udid: udid)) }
            let check = try #require(DoctorReport.scopeCheck(target(udid: udid)))
            #expect(check.detail.hasPrefix("1 pending change since "))
            #expect(check.detail.hasSuffix(": userInterfaceStyle"))
        }
    }

    @Test func doctorChecksAShutDownSimulatorWithAnOpenScope() async throws {
        let udid = UUID().uuidString
        #expect(!DoctorReport.listed(target(udid: udid, bootState: "shutdown")))
        try await scope(udid: udid, directory: ChangeJournal(udid: udid).directory) { _ in
            #expect(DoctorReport.listed(target(udid: udid, bootState: "shutdown")))
        }
    }

    @Test func prepareAllSkipsAShutDownSimulatorWithAnOpenScope() async throws {
        let udid = UUID().uuidString
        try await scope(udid: udid, directory: ChangeJournal(udid: udid).directory) { _ in
            #expect(!DoctorReport.checked(target(udid: udid, bootState: "shutdown")))
        }
    }

    @Test func inspectListsPendingChanges() async throws {
        let udid = UUID().uuidString
        try await scope(udid: udid, directory: ChangeJournal(udid: udid).directory) { journal in
            try await change(journal, "userInterfaceStyle", to: "dark")
            let state = DeviceState(udid: udid, capturedAt: "2026-11-08T10:05:00.000Z", fields: [:])
            let result = try StateCommands.inspect(target(udid: udid), state: state)
            #expect(result.text.contains("userInterfaceStyle: light -> dark, applied dark"))
            #expect(result.json["pendingChanges"]?.array?.count == 1)
        }
    }
}
