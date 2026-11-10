//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

private let udid = "00000000-0000-0000-0000-000000000000"

private func field(
    _ value: JSONValue?, _ availability: StateField.Availability = .observed, reason: String? = nil,
    at time: String = "2026-11-08T10:00:00.000Z"
) -> StateField {
    StateField(
        value: value, availability: availability, reason: reason, source: "devicectl device info appearance",
        observedAt: value == nil ? nil : time, scope: .simulator, mutability: .settable, sensitivity: .normal, restorable: false)
}

private func state(udid: String = udid, at time: String, _ fields: [String: StateField]) -> DeviceState {
    DeviceState(udid: udid, capturedAt: time, fields: fields)
}

@Suite struct StateDiffTests {
    @Test func equalObservedValuesAreUnchanged() throws {
        let before = state(at: "2026-11-08T10:00:00.000Z", ["textSize": field("Large")])
        let after = state(at: "2026-11-08T10:01:00.000Z", ["textSize": field("Large", at: "2026-11-08T10:01:00.000Z")])
        #expect(try StateDiff.compare(before, after).fields["textSize"]?.status == .unchanged)
    }

    @Test func differentObservedValuesAreChangedWithSourceAndTime() throws {
        let before = state(at: "2026-11-08T10:00:00.000Z", ["userInterfaceStyle": field("light")])
        let after = state(at: "2026-11-08T10:01:00.000Z", ["userInterfaceStyle": field("dark", at: "2026-11-08T10:01:00.500Z")])
        let change = try StateDiff.compare(before, after).fields["userInterfaceStyle"]
        #expect(change?.status == .changed)
        #expect(change?.before == "light")
        #expect(change?.after == "dark")
        #expect(change?.source == "devicectl device info appearance")
        #expect(change?.observedAt == "2026-11-08T10:01:00.500Z")
    }

    @Test func fieldNotObservedOnEitherSideIsUnknown() throws {
        let before = state(
            at: "2026-11-08T10:00:00.000Z",
            [
                "battery": field(nil, .unknown, reason: "no source"),
                "voiceOver": field(false),
                "volume": field(nil, .unavailable, reason: "Test Target is shutdown"),
            ])
        let after = state(
            at: "2026-11-08T10:01:00.000Z",
            [
                "battery": field(nil, .unknown, reason: "no source"),
                "voiceOver": field(false, .unsupported, reason: "missing capability x"),
                "volume": field(60),
            ])
        let diff = try StateDiff.compare(before, after)
        #expect(diff.fields.values.allSatisfy { $0.status == .unknown })
        #expect(diff.fields["voiceOver"]?.reason == "after: unsupported, missing capability x")
        #expect(diff.fields["voiceOver"]?.after == nil)
        #expect(diff.fields["volume"]?.reason == "before: unavailable, Test Target is shutdown")
    }

    @Test func differentUDIDIsRejected() {
        let before = state(at: "2026-11-08T10:00:00.000Z", [:])
        let after = state(udid: "00000000-0000-0000-0000-000000000001", at: "2026-11-08T10:01:00.000Z", [:])
        let error = #expect(throws: DeviceLoopError.self) { try StateDiff.compare(before, after) }
        #expect(error?.code == .badArguments)
    }

    @Test func osBuildChangeIsReported() throws {
        let before = state(at: "2026-11-08T10:00:00.000Z", ["osBuild": field("24A434")])
        let after = state(at: "2026-11-08T10:01:00.000Z", ["osBuild": field("24B5070a")])
        let diff = try StateDiff.compare(before, after)
        #expect(diff.osBuildChanged)
        #expect(diff.fields["osBuild"]?.status == .changed)
    }

    @Test func captureFileIsPrivateAndReadsBack() throws {
        let file = Paths.home.appending(path: "state-tests/\(UUID().uuidString)/capture.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let saved = state(at: "2026-11-08T10:00:00.000Z", ["userInterfaceStyle": field("light")])
        try StateCommands.write(saved, to: file)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(try StateCommands.load(file).fields == saved.fields)
    }

    @Test func captureRefusesAnExistingOutput() async throws {
        let file = Paths.home.appending(path: "state-tests/\(UUID().uuidString)/Package.swift")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Paths.ensureDirectory(file.deletingLastPathComponent())
        try Data("let package = 1".utf8).write(to: file)
        let target = Target(
            udid: udid, identifier: udid, name: "Test Target", kind: .simulator, deviceType: "iPhone", platform: "iOS",
            model: "iPhone 17 Pro", productType: "iPhone18,1", osVersion: "27.0", connectionState: "connected", bootState: "booted",
            capabilities: [])
        let error = await #expect(throws: DeviceLoopError.self) { try await StateCommands.capture(target, output: file) }

        #expect(error?.code == .badArguments)
        #expect(try String(contentsOf: file, encoding: .utf8) == "let package = 1")
    }

    @Test func writeWithoutReplaceKeepsAnExistingFile() throws {
        let file = Paths.home.appending(path: "state-tests/\(UUID().uuidString)/capture.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let first = state(at: "2026-11-08T10:00:00.000Z", ["userInterfaceStyle": field("light")])
        try StateCommands.write(first, to: file, replace: false)
        let second = state(at: "2026-11-08T10:01:00.000Z", ["userInterfaceStyle": field("dark")])
        let error = #expect(throws: DeviceLoopError.self) { try StateCommands.write(second, to: file, replace: false) }

        #expect(error?.code == .badArguments)
        #expect(try StateCommands.load(file).fields == first.fields)
        let leftover = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        #expect(leftover == ["capture.json"])
    }

    @Test func fileWithAnotherSchemaIsRejected() throws {
        let file = Paths.home.appending(path: "state-tests/\(UUID().uuidString)/capture.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var saved = state(at: "2026-11-08T10:00:00.000Z", [:])
        saved.schema = "deviceloop.device-state/2"
        try StateCommands.write(saved, to: file)
        #expect(throws: DeviceLoopError.self) { try StateCommands.load(file) }
    }
}
