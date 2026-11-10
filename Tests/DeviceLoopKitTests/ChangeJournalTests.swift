//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct ChangeJournalTests {
    private func fixture(scope: Bool = true, strict: Bool = false, _ body: (ChangeJournal) async throws -> Void) async throws {
        let directory = Paths.home.appending(path: "journal-tests/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ChangeJournal(directory: directory)
        if scope {
            _ = try await journal.start(strict: strict) {
                DeviceState(udid: "00000000-0000-0000-0000-000000000000", capturedAt: "2026-11-08T10:00:00.000Z", fields: [:])
            }
        }
        try await body(journal)
    }

    @Test func changeIsOnDiskBeforeDispatchAndAfterItThrows() async throws {
        try await fixture { journal in
            let error = await #expect(throws: DeviceLoopError.self) {
                try await journal.record(field: "userInterfaceStyle", requested: "dark", source: "test", read: { "light" }) {
                    let written = try journal.lines().entries
                    #expect(written.map(\.kind) == [.change])
                    throw DeviceLoopError(.deviceError, "devicectl failed.")
                }
            }
            #expect(error?.code == .deviceError)
            let entries = try journal.lines().entries
            #expect(entries.map(\.kind) == [.change])
            #expect(entries.first?.original?.value == "light")
            #expect(entries.first?.original?.availability == .observed)
            #expect(entries.first?.requested == "dark")
        }
    }

    @Test func appliedLineHoldsTheReRead() async throws {
        try await fixture { journal in
            var style: JSONValue = "light"
            let result = try await journal.record(field: "userInterfaceStyle", requested: "dark", source: "test", read: { style }) {
                style = "dark"
                return CommandResult(text: "Test Target\nAppearance set to dark", json: ["userInterfaceStyle": "dark"])
            }
            let changes = ChangeJournal.changes(try journal.lines().entries)
            #expect(changes.count == 1)
            #expect(changes.first?.original?.value == "light")
            #expect(changes.first?.applied?.value == "dark")
            #expect(result.json.value(at: "journal.id")?.string == changes.first?.id)
        }
    }

    @Test func appliedValueIsUnknownWhenTheReReadFails() async throws {
        try await fixture { journal in
            var reads = 0
            _ = try await journal.record(
                field: "orientation", requested: "landscapeLeft", source: "devicectl device orientation get",
                read: {
                    reads += 1
                    if reads > 1 { throw DeviceLoopError(.deviceError, "devicectl timed out.") }
                    return "portrait"
                }
            ) { CommandResult(text: "Test Target\nOrientation set to landscapeLeft") }
            let applied = try #require(try journal.lines().entries.last)
            #expect(applied.kind == .applied)
            #expect(applied.applied?.availability == .unknown)
            #expect(applied.applied?.value == nil)
            #expect(applied.applied?.reason == "devicectl timed out.")
        }
    }

    @Test func nothingIsWrittenWithoutAScope() async throws {
        try await fixture(scope: false) { journal in
            let result = try await journal.record(
                field: "userInterfaceStyle", requested: "dark", source: "test",
                read: {
                    Issue.record("read without a scope")
                    return "light"
                }
            ) { CommandResult(text: "Test Target\nAppearance set to dark", json: ["userInterfaceStyle": "dark"]) }
            #expect(!FileManager.default.fileExists(atPath: journal.directory.path))
            #expect(result.text == "Test Target\nAppearance set to dark")
            #expect(result.json == ["userInterfaceStyle": "dark"])
        }
    }

    @Test func strictScopeRefusesAnUnreadableChangeBeforeDispatch() async throws {
        try await fixture(strict: true) { journal in
            let error = await #expect(throws: DeviceLoopError.self) {
                try await journal.record(field: "wifi", requested: "off", unreadable: "DeviceLoop cannot read Wi-Fi back.") {
                    Issue.record("dispatched in a strict scope")
                    return CommandResult(text: "Test Target")
                }
            }
            #expect(error?.code == .unsupportedOnTarget)
            #expect(error?.fix?.contains("without --strict") == true)
            let entries = try journal.lines().entries
            #expect(entries.isEmpty)
        }
    }

    @Test func permissiveScopeJournalsAnUnreadableChangeAsUnknown() async throws {
        try await fixture { journal in
            var dispatched = false
            _ = try await journal.record(field: "wifi", requested: "off", unreadable: "DeviceLoop cannot read Wi-Fi back.") {
                dispatched = true
                return CommandResult(text: "Test Target")
            }
            let change = try #require(ChangeJournal.changes(try journal.lines().entries).first)
            #expect(dispatched)
            #expect(change.original?.availability == .unknown)
            #expect(change.original?.reason == "DeviceLoop cannot read Wi-Fi back.")
            #expect(change.applied?.availability == .unknown)
            #expect(change.requested == "off")
        }
    }

    @Test func journalIsReadableOnlyByTheOwner() async throws {
        try await fixture { journal in
            _ = try await journal.record(field: "location", requested: ["cleared": true], source: "none", read: { nil }) {
                CommandResult(text: "Test Target\nLocation cleared")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: journal.file.path)
            #expect((attributes[.posixPermissions] as? Int) == 0o600)
        }
    }

    @Test func startRefusesAnOpenScope() async throws {
        try await fixture { journal in
            let error = await #expect(throws: DeviceLoopError.self) {
                try await journal.start(strict: true) {
                    Issue.record("captured a baseline over an open scope")
                    return DeviceState(udid: "00000000-0000-0000-0000-000000000000", capturedAt: "2026-11-08T10:01:00.000Z", fields: [:])
                }
            }
            #expect(error?.code == .badArguments)
            let scope = try journal.lines().scope
            #expect(scope.baseline.capturedAt == "2026-11-08T10:00:00.000Z")
        }
    }
}
