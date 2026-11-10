//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct RunnerDiagnosticsTests {
    private let warning = WireIssue(type: 4, message: "Diagnostic warning", isFailure: false)
    private let failure = WireIssue(type: 4, message: "Input failed", isFailure: true)
    private let timing = WireTiming(start: 100, end: 101, elapsed: 1)

    @Test func warningPreservesSuccessfulResultAndDiagnostics() throws {
        let response = WireResponse.completed(WireEmpty(), timing: timing, issues: [warning])
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(WireResponse<WireEmpty>.self, from: data)
        #expect(decoded.ok)
        #expect(decoded.issues == [warning])
        #expect(decoded.error == nil)
        #expect(try RunnerClient.decodeResult(data, as: WireEmpty.self).result == WireEmpty())
    }

    @Test func warningOnlyResponseReturnsItsIssuesAndTiming() throws {
        let data = Data(
            #"""
            {"ok":true,"result":{"point":{"x":10,"y":20}},"timing":{"start":100,"end":101,"ms":1000},
            "issues":[{"type":4,"message":"Diagnostic warning","isFailure":false}]}
            """#.utf8)
        let reply = try RunnerClient.decodeResult(data, as: ActionResult.self)
        #expect(reply.result == ActionResult(point: WirePoint(x: 10, y: 20)))
        #expect(reply.issues == [warning])
        #expect(reply.timing == timing)
    }

    @Test func actionResultCarriesIssuesTimingAndReceipt() throws {
        let target = Target(
            udid: "unit-test", identifier: "unit-test", name: "Unit test", kind: .simulator, deviceType: "iPhone", platform: "iOS",
            model: "fixture", productType: "fixture", osVersion: "27.0", connectionState: "connected")
        let reply = RunnerReply(result: ActionResult(), issues: [warning], timing: timing, operationID: "test-id")
        let result = try UICommands.actionResult(target, line: "tapped", reply: reply, epoch: "test-epoch")
        #expect(result.json["issues"] == [["type": 4, "message": "Diagnostic warning", "isFailure": false]])
        #expect(result.json["timing"] == ["start": 100, "end": 101, "ms": 1000])
        #expect(result.json["operationID"] == "test-id")
        #expect(result.json["sessionEpoch"] == "test-epoch")
        #expect(result.text == "\(target.summary)\ntapped\nwarning: XCTest: Diagnostic warning")
    }

    @Test func nonthrowingFailureRetainsPartialResultButFailsResponse() {
        let response = WireResponse.completed(WireEmpty(), timing: timing, issues: [warning, failure])
        #expect(!response.ok)
        #expect(response.result == WireEmpty())
        #expect(response.error?.code == "xctest_issue")
        #expect(response.error?.issues == [warning.message, failure.message])
        #expect(response.issues == [warning, failure])
    }

    @Test func clientRejectsFailureEvenWhenEnvelopeClaimsSuccess() throws {
        let data = try JSONEncoder().encode(WireResponse(ok: true, result: WireEmpty(), issues: [failure]))
        do {
            _ = try RunnerClient.decodeResult(data, as: WireEmpty.self)
            Issue.record("A recorded failure was accepted as success")
        } catch let error as DeviceLoopError {
            #expect(error.code == .xctestIssue)
            #expect(!error.retryable)
            #expect(error.detail == failure.message)
        }
    }

    @Test func clearFailureFromTheRunnerIsATextMismatchWithAFix() throws {
        let error = WireError(code: "text_mismatch", message: "The field still holds 3 characters after clearing, so nothing was typed.")
        let data = try JSONEncoder().encode(WireResponse<WireEmpty>(ok: false, error: error))
        do {
            _ = try RunnerClient.decodeResult(data, as: WireEmpty.self)
            Issue.record("A failed clear was accepted as success")
        } catch let error as DeviceLoopError {
            #expect(error.code == .textMismatch)
            #expect(error.fix?.contains("empty the field another way") == true)
        }
    }

    @Test func elementNotFoundFromTheRunnerHasAFix() throws {
        let error = WireError(code: "element_not_found", message: "No element matches the target")
        let data = try JSONEncoder().encode(WireResponse<WireEmpty>(ok: false, error: error))
        let failure = #expect(throws: DeviceLoopError.self) { try RunnerClient.decodeResult(data, as: WireEmpty.self) }
        #expect(failure?.code == .elementNotFound)
        #expect(failure?.fix == "Check the target against deviceloop ui tree, or wait for it with deviceloop ui wait.")
    }

    @Test func staleRefFromTheRunnerHasAFix() throws {
        let error = WireError(code: "stale_ref", message: "Ref e5 is not in the last tree snapshot. Take a new tree.")
        let data = try JSONEncoder().encode(WireResponse<WireEmpty>(ok: false, error: error))
        let failure = #expect(throws: DeviceLoopError.self) { try RunnerClient.decodeResult(data, as: WireEmpty.self) }
        #expect(failure?.fix == "Run deviceloop ui tree again and use a new ref.")
    }

    @Test func elementNotHittableFromTheRunnerHasAFix() throws {
        let error = WireError(code: "element_not_hittable", message: "The element at 1201,690 is outside the app frame of 402x874 points.")
        let data = try JSONEncoder().encode(WireResponse<WireEmpty>(ok: false, error: error))
        let failure = #expect(throws: DeviceLoopError.self) { try RunnerClient.decodeResult(data, as: WireEmpty.self) }
        #expect(failure?.code == .elementNotHittable)
        #expect(failure?.fix == "Swipe the element onto the screen with deviceloop ui swipe, then tap it again.")
    }

    @Test func responseWithoutIssuesRemainsDecodable() throws {
        let data = Data(#"{"ok":true,"result":{}}"#.utf8)
        #expect(try RunnerClient.decodeResult(data, as: WireEmpty.self).result == WireEmpty())
    }

    @Test(arguments: [RunnerWire.Path.type, RunnerWire.Path.tap, RunnerWire.Path.siri, RunnerWire.Path.intentsRun, "/future-action"])
    func mutationDisconnectDoesNotInviteReplay(path: String) {
        let error = RunnerClient.transportError(URLError(.timedOut), path: path, method: "POST", host: "test")
        #expect(error.code == .actionOutcomeUnknown)
        #expect(!error.retryable)
        #expect(error.fix?.contains("Do not automatically replay") == true)
    }

    @Test(arguments: [
        RunnerWire.Path.tree, RunnerWire.Path.find, RunnerWire.Path.wait, RunnerWire.Path.waitStable, RunnerWire.Path.audit,
        RunnerWire.Path.intentsEntities,
    ])
    func observationDisconnectRemainsRetryable(path: String) {
        let error = RunnerClient.transportError(URLError(.timedOut), path: path, method: "POST", host: "test")
        #expect(error.code == .runnerUnreachable)
        #expect(error.retryable)
    }

    @Test func healthDisconnectRemainsRetryable() {
        let error = RunnerClient.transportError(URLError(.networkConnectionLost), path: RunnerWire.Path.health, method: "GET", host: "test")
        #expect(error.code == .runnerUnreachable)
        #expect(error.retryable)
    }

    @Test func elapsedDurationSurvivesWallClockAdjustment() {
        #expect(WireTiming(start: 100, end: 99, elapsed: 0.2).ms == 200)
        #expect(WireTiming(start: 100, end: 99).ms == 0)
    }

    @Test func unreadableMutationResponseHasUnknownOutcome() throws {
        do {
            _ = try RunnerClient.decodeResponse(Data("{\"ok\":".utf8), path: RunnerWire.Path.type, method: "POST", as: WireEmpty.self)
            Issue.record("A truncated response was accepted")
        } catch let error as DeviceLoopError {
            #expect(error.code == .actionOutcomeUnknown)
            #expect(!error.retryable)
        }
    }

    @Test func snapshotFailureRetainsItsCode() throws {
        let data = try JSONEncoder().encode(
            WireResponse<WireEmpty>(ok: false, error: WireError(code: "snapshot_failed", message: "No snapshot")))
        do {
            _ = try RunnerClient.decodeResponse(data, path: RunnerWire.Path.waitStable, method: "POST", as: WireEmpty.self)
            Issue.record("A failed snapshot was accepted")
        } catch let error as DeviceLoopError {
            #expect(error.code == .snapshotFailed)
        }
    }

    @Test func unsupportedButtonListsTheAvailableButtons() throws {
        let failure = WireError(code: "unsupported", message: "This device has no back button", alternatives: ["home"])
        let data = try JSONEncoder().encode(WireResponse<WireEmpty>(ok: false, error: failure))
        do {
            _ = try RunnerClient.decodeResponse(data, path: RunnerWire.Path.button, method: "POST", as: WireEmpty.self)
            Issue.record("An unsupported button was accepted")
        } catch let error as DeviceLoopError {
            #expect(error.exitCode == 6)
            #expect(error.alternatives == ["home"])
        }
    }

    @Test func requestsCarryEpochAndStableOperationIdentity() throws {
        let client = RunnerClient(baseURL: URL(string: "http://localhost:1234")!, token: "test", epoch: "test-epoch")
        let request = try client.request(
            RunnerWire.Path.tap, method: "POST", body: WirePoint(x: 1, y: 2), timeout: 10, operationID: "test-id")
        #expect(request.value(forHTTPHeaderField: RunnerWire.Header.epoch) == "test-epoch")
        #expect(request.value(forHTTPHeaderField: RunnerWire.Header.operationID) == "test-id")
        #expect(request.httpBody == Data(#"{"x":1,"y":2}"#.utf8))
    }

    @Test func unencodableInputFailsBeforeRequestDispatch() {
        let client = RunnerClient(baseURL: URL(string: "http://localhost:1234")!, token: "test")
        #expect(throws: EncodingError.self) {
            try client.request(RunnerWire.Path.tap, method: "POST", body: WirePoint(x: .nan, y: 2), timeout: 10)
        }
    }

    @Test func unknownOutcomeRetainsReceiptInJSONAndText() throws {
        var error = DeviceLoopError(.actionOutcomeUnknown, "Response lost")
        error.operationID = "test-id"
        error.sessionEpoch = "test-epoch"
        let decoded = try JSONDecoder().decode(DeviceLoopError.self, from: JSONEncoder().encode(error))
        #expect(decoded.operationID == "test-id")
        #expect(decoded.sessionEpoch == "test-epoch")
        #expect(decoded.rendered.contains("runner operation test-id --epoch test-epoch"))
    }

    @Test func admittedRequestErrorsCarryTheirReceipt() {
        let client = RunnerClient(baseURL: URL(string: "http://localhost:1234")!, token: "test", epoch: "test-epoch")
        let error = client.identifying(DeviceLoopError(.timeout, "Timed out"), path: RunnerWire.Path.tap, id: "test-id")
        #expect(error.operationID == "test-id")
        #expect(error.sessionEpoch == "test-epoch")
    }

    @Test(arguments: [DeviceLoopError.Code.deviceBusy, .sessionMismatch])
    func rejectionsBeforeAdmissionCarryNoReceipt(code: DeviceLoopError.Code) {
        let client = RunnerClient(baseURL: URL(string: "http://localhost:1234")!, token: "test", epoch: "test-epoch")
        let error = client.identifying(DeviceLoopError(code, "Rejected"), path: RunnerWire.Path.tap, id: "test-id")
        #expect(error.operationID == nil)
    }

    @Test func receiptLookupErrorsCarryNoReceipt() {
        let client = RunnerClient(baseURL: URL(string: "http://localhost:1234")!, token: "test", epoch: "test-epoch")
        let error = client.identifying(
            DeviceLoopError(.actionOutcomeUnknown, "No receipt"), path: RunnerWire.Path.operations + "test-id", id: "lookup-id")
        #expect(error.operationID == nil)
    }

    @Test func auditRequestEncodesTypeNames() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let request = AuditRequest(app: "com.example.app", types: ["contrast", "dynamicType"])
        let data = try encoder.encode(request)
        #expect(data == Data(#"{"app":"com.example.app","types":["contrast","dynamicType"]}"#.utf8))
        #expect(try JSONDecoder().decode(AuditRequest.self, from: data) == request)
        #expect(try JSONDecoder().decode(AuditRequest.self, from: Data("{}".utf8)) == AuditRequest())
    }

    @Test func auditResultRoundTripsThroughTheClient() throws {
        let result = AuditResult(
            app: "com.example.app",
            issues: [
                AuditIssue(
                    type: "contrast", compactDescription: "Contrast failed", detailedDescription: "Text is hard to read",
                    element: FoundElement(type: "staticText", id: "title", label: "Title", frame: [0, 10, 100, 20])),
                AuditIssue(type: "dynamicType", compactDescription: "Fixed size", detailedDescription: "Text does not scale"),
            ])
        let data = try JSONEncoder().encode(WireResponse.completed(result, timing: timing, issues: []))
        #expect(try RunnerClient.decodeResult(data, as: AuditResult.self).result == result)
    }

    @Test func auditFailureMapsToItsOwnCode() throws {
        let data = try JSONEncoder().encode(
            WireResponse<AuditResult>(ok: false, error: WireError(code: "audit_failed", message: "Audit could not run")))
        do {
            _ = try RunnerClient.decodeResponse(data, path: RunnerWire.Path.audit, method: "POST", as: AuditResult.self)
            Issue.record("A failed audit was accepted")
        } catch let error as DeviceLoopError {
            #expect(error.code == .auditFailed)
            #expect(error.message == "Audit could not run")
            #expect(error.fix?.contains("run the audit again") == true)
        }
    }

    @Test func intentParametersDecodeByJSONType() throws {
        let json = #"{"title":"Blue marker","count":3,"ratio":2.5,"done":true,"task":{"entity":"FixtureTaskEntity","id":"A1"}}"#
        let params = try JSONDecoder().decode([String: IntentValue].self, from: Data(json.utf8))
        #expect(
            params == [
                "title": .string("Blue marker"), "count": .number(3), "ratio": .number(2.5), "done": .bool(true),
                "task": .entity(type: "FixtureTaskEntity", id: "A1"),
            ])
        #expect(try JSONDecoder().decode([String: IntentValue].self, from: JSONEncoder().encode(params)) == params)
    }

    @Test func intentParameterWithoutEntityIDIsRejected() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(IntentValue.self, from: Data(#"{"entity":"FixtureTaskEntity"}"#.utf8))
        }
    }

    @Test(arguments: ["operation_in_progress", "operation_conflict", "session_mismatch", "receipt_unknown", "result_not_retained"])
    func receiptUncertaintyNeverInvitesReplay(code: String) throws {
        let data = try JSONEncoder().encode(WireResponse<WireEmpty>(ok: false, error: WireError(code: code, message: "Receipt test")))
        do {
            _ = try RunnerClient.decodeResult(data, as: WireEmpty.self)
            Issue.record("Expected a receipt error")
        } catch let error as DeviceLoopError {
            #expect(!error.retryable)
            #expect(error.code != .internalError)
        }
    }
}
