//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Testing

@testable import DeviceLoopKit

private let epoch = "00000000-0000-0000-0000-0000000000e1"
private let operationID = "00000000-0000-0000-0000-0000000000a1"
private let host = "com.example.host"

private let target = Target(
    udid: "00000000-0000-0000-0000-000000000001", identifier: "00000000-0000-0000-0000-000000000001", name: "Test Simulator",
    kind: .simulator, deviceType: "iPhone", platform: "iOS", model: "iPhone 17 Pro", productType: "iPhone18,1", osVersion: "27.2",
    connectionState: "connected", bootState: "booted", transport: "sameMachine"
)

private func wire<Result: Codable & Sendable>(_ result: Result) throws -> Data {
    try JSONEncoder().encode(WireResponse(ok: true, result: result))
}

private func receipt(_ phase: String, status: Int? = nil, response: WireResponse<ActionResult>? = nil) throws -> Data {
    let json = try response.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
    return try wire(
        OperationStatusResult(
            operation: OperationReference(id: operationID, sessionEpoch: epoch, phase: phase), responseStatus: status,
            responseContentType: json == nil ? nil : "application/json", responseJSON: json))
}

private let info = InfoResult(
    screenWidth: 402, screenHeight: 874, scale: 3, model: "iPhone", systemName: "iOS", systemVersion: "27.2", orientation: "portrait",
    appearance: "light", hardwareButtons: ["home"], preferredLanguages: ["fr-FR", "en-US"], locale: "fr_FR")

/// Serves info, accepts the Siri request, then answers receipt lookups with `receipts` (the last one repeats) and finds with `find`.
private func fakeRunner(receipts: [Data?], find: Data? = nil) throws -> FakeRunner {
    let accepted = try wire(ActionResult(operation: OperationReference(id: operationID, sessionEpoch: epoch, phase: "accepted")))
    let found: [FakeRunner.Reply?] = find.map { [(200, $0)] } ?? []
    return FakeRunner(
        epoch: epoch,
        replies: [
            "GET \(RunnerWire.Path.info)": [(200, try wire(info))],
            "POST \(RunnerWire.Path.siri)": [(202, accepted)],
            "POST \(RunnerWire.Path.find)": found,
            "GET \(RunnerWire.Path.operations + operationID)": receipts.map { $0.map { (200, $0) } },
        ])
}

private func say(
    _ runner: FakeRunner, wait: Duration? = .seconds(1), expect: ElementQuery? = nil
) async throws -> CommandResult {
    try await SiriCommands.send(
        target, client: runner.client, phrase: "what time is it", note: false, wait: wait, expect: expect, app: host,
        interval: .milliseconds(10))
}

@Suite struct SiriCommandsTests {
    @Test func levelMustBeANumber() {
        #expect(throws: DeviceLoopError.self) { try SiriCommands.Control(setting: "brightness", value: "high") }
    }

    @Test func toggleValueMustBeOnOrOff() {
        #expect(throws: DeviceLoopError.self) { try SiriCommands.Control(setting: "wifi", value: "yes") }
    }

    @Test func toggleValueIgnoresCase() throws {
        #expect(try SiriCommands.Control(setting: "airplane", value: "OFF") == .toggle(.airplaneMode, on: false))
    }

    @Test func expectationTakesOnlyIdOrLabel() throws {
        #expect(try SiriCommands.expectation("id=login") == ElementQuery(id: "login"))
        #expect(try SiriCommands.expectation("label=Clock") == ElementQuery(label: "Clock"))
        #expect(throws: DeviceLoopError.self) { try SiriCommands.expectation("@e5") }
    }

    @Test func finishedReceiptWithAFailureIssueIsUnverifiedWithTheIssue() async throws {
        let issue = WireIssue(type: 0, message: "Timed out waiting for Siri to activate", isFailure: true)
        let finished = WireResponse.completed(ActionResult(eventTime: 1), timing: WireTiming(start: 0, end: 130), issues: [issue])
        let result = try await say(try fakeRunner(receipts: [receipt("running"), receipt("finished", status: 500, response: finished)]))
        #expect(result.json["verified"] == false)
        #expect(result.json["responseStatus"] == 500)
        #expect(try result.json["issues"]?.decode([WireIssue].self) == [issue])
        #expect(result.text.contains("XCTest failure: Timed out waiting for Siri to activate"))
    }

    @Test func finishedReceiptPrintsTheRunnerOperationLines() async throws {
        let issue = WireIssue(type: 4, message: "Siri did not answer", isFailure: false)
        let finished = WireResponse.completed(ActionResult(eventTime: 1), timing: WireTiming(start: 0, end: 2), issues: [issue])
        let body = try receipt("finished", status: 200, response: finished)
        let result = try await say(try fakeRunner(receipts: [body]))
        let status = try #require(try JSONDecoder().decode(WireResponse<OperationStatusResult>.self, from: body).result)
        let receiptLines = RunnerCommands.operationLines(operationID, result: status)
        #expect(receiptLines.last == "XCTest issue: Siri did not answer")
        #expect(result.text.contains(receiptLines.joined(separator: "\n")))
    }

    @Test func finishedReceiptWithoutIssuesHasAnEmptyIssueList() async throws {
        let finished = WireResponse.completed(ActionResult(eventTime: 1), timing: WireTiming(start: 0, end: 5), issues: [])
        let result = try await say(try fakeRunner(receipts: [receipt("finished", status: 200, response: finished)]))
        #expect(result.json["issues"] == [])
    }

    @Test func metExpectationIsVerified() async throws {
        let finished = WireResponse.completed(ActionResult(eventTime: 1), timing: WireTiming(start: 0, end: 5), issues: [])
        let match = FoundElement(type: "button", id: "fixture.counter.increment", frame: [0, 0, 10, 10])
        let found = try wire(FindResult(matches: [match]))
        let runner = try fakeRunner(receipts: [receipt("finished", status: 200, response: finished)], find: found)
        let result = try await say(runner, expect: ElementQuery(id: "fixture.counter.increment"))
        #expect(result.json["verified"] == true)
        #expect(runner.requests.last == "POST \(RunnerWire.Path.find)")
    }

    @Test func failedFindAfterTheReceiptIsUnverifiedWithTheReceipt() async throws {
        let finished = WireResponse.completed(ActionResult(eventTime: 1), timing: WireTiming(start: 0, end: 5), issues: [])
        let runner = try fakeRunner(receipts: [receipt("finished", status: 200, response: finished)])
        let result = try await say(runner, expect: ElementQuery(id: "fixture.counter.increment"))
        #expect(result.json["verified"] == false)
        #expect(result.json["responseStatus"] == 200)
        #expect(result.json.value(at: "expectation.error.code") == "runner_unreachable")
    }

    @Test func pollTimeoutIsUnknownWithTheOperationIDAndNoResubmit() async throws {
        let runner = try fakeRunner(receipts: [receipt("running")])
        let error = await #expect(throws: DeviceLoopError.self) { try await say(runner, wait: .milliseconds(50)) }
        #expect(error?.code == .actionOutcomeUnknown)
        #expect(error?.operationID == operationID)
        #expect(error?.sessionEpoch == epoch)
        #expect(runner.sent("POST \(RunnerWire.Path.siri)") == 1)
    }

    @Test func lostReceiptIsUnknownWithTheOperationIDAndNoResubmit() async throws {
        let runner = try fakeRunner(receipts: [nil])
        let error = await #expect(throws: DeviceLoopError.self) { try await say(runner) }
        #expect(error?.code == .actionOutcomeUnknown)
        #expect(error?.operationID == operationID)
        #expect(runner.sent("POST \(RunnerWire.Path.siri)") == 1)
    }

    @Test func siriResultReportsDeviceLanguagesAndUnknownSiriState() async throws {
        let result = try await say(try fakeRunner(receipts: []), wait: nil)
        #expect(result.json["deviceLanguages"] == ["fr-FR", "en-US"])
        #expect(result.json["siriLanguage"] == "unknown")
        #expect(result.json["siriEnabled"] == "unknown")
        #expect(result.json.value(at: "operation.phase") == "accepted")
    }

    @Test func lockWindowIsBetweenOneAnd300Seconds() throws {
        #expect(try SiriCommands.lockWindow(seconds: 1) == .seconds(1))
        #expect(try SiriCommands.lockWindow(seconds: 300) == .seconds(300))
        for seconds in [0, -1, 301] {
            let error = #expect(throws: DeviceLoopError.self) { try SiriCommands.lockWindow(seconds: seconds) }
            #expect(error?.code == .badArguments)
            #expect(error?.fix != nil)
        }
    }

    @Test func passcodeRequiredVerifiesTheLock() async throws {
        var states: [JSONValue] = [["passcodeRequired": false], ["passcodeRequired": true]]
        let result = try await SiriCommands.lock(
            target, client: try fakeRunner(receipts: []).client, window: .seconds(30), interval: .milliseconds(10)
        ) { states.removeFirst() }
        #expect(result.json["lockVerified"] == true)
        #expect(result.json.value(at: "operation.id") == .string(operationID))
    }

    @Test func lockNeverShowingPasscodeRequiredIsUnverifiedWithAReasonAndNoResubmit() async throws {
        let runner = try fakeRunner(receipts: [])
        let result = try await SiriCommands.lock(
            target, client: runner.client, window: .milliseconds(50), interval: .milliseconds(10)
        ) { ["passcodeRequired": false] }
        #expect(result.json["lockVerified"] == false)
        #expect(result.json["reason"]?.string?.contains("A device with no passcode never does") == true)
        #expect(result.json.value(at: "operation.id") == .string(operationID))
        #expect(runner.requests == ["POST \(RunnerWire.Path.siri)"])
    }

    @Test func unreadableLockStateAfterADroppedRequestIsUnverifiedWithDevicectlsError() async throws {
        let runner = FakeRunner(epoch: epoch, replies: [:])
        let result = try await SiriCommands.lock(target, client: runner.client, window: .milliseconds(50), interval: .milliseconds(10)) {
            throw DeviceLoopError(.deviceError, "The device is not reachable.")
        }
        #expect(result.json["lockVerified"] == false)
        #expect(result.json["reason"] == "devicectl could not read the lock state: The device is not reachable.")
        #expect(result.json.value(at: "operation.phase") == "unknown")
        #expect(runner.requests == ["POST \(RunnerWire.Path.siri)"])
    }

    @Test func infoDecodesLanguageFields() throws {
        let decoded = try JSONDecoder().decode(InfoResult.self, from: JSONEncoder().encode(info))
        #expect(decoded.preferredLanguages == ["fr-FR", "en-US"])
        #expect(decoded.locale == "fr_FR")
    }

    @Test func infoFromAnOlderRunnerDecodesWithoutLanguageFields() throws {
        let older = #"""
            {"screenWidth": 402, "screenHeight": 874, "scale": 3, "model": "iPhone", "systemName": "iOS", "systemVersion": "18.5",
            "orientation": "portrait", "appearance": "light", "hardwareButtons": []}
            """#
        let decoded = try JSONDecoder().decode(InfoResult.self, from: Data(older.utf8))
        #expect(decoded.preferredLanguages == nil)
        #expect(decoded.locale == nil)
    }
}
