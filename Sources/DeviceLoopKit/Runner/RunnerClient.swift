//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation

/// Talks to the on-device runner over the CoreDevice tunnel (or loopback on a simulator).
struct RunnerClient: Sendable {
    let baseURL: URL
    let token: String
    var epoch: String? = nil
    var urlSession = RunnerClient.session

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func get<Result: Codable & Sendable>(_ path: String, as type: Result.Type, timeout: Double = 120) async throws -> Result {
        Self.warned(try await send(path, method: "GET", body: Optional<WireEmpty>.none, as: type, timeout: timeout))
    }

    func post<Body: Encodable, Result: Codable & Sendable>(
        _ path: String,
        _ body: Body,
        as type: Result.Type,
        timeout: Double = 120
    ) async throws -> Result {
        Self.warned(try await send(path, method: "POST", body: body, as: type, timeout: timeout))
    }

    /// Like `post`, but returns the XCTest warnings, timing and operation ID with the result.
    func postReply<Body: Encodable, Result: Codable & Sendable>(
        _ path: String,
        _ body: Body,
        as type: Result.Type,
        timeout: Double = 120
    ) async throws -> RunnerReply<Result> {
        try await send(path, method: "POST", body: body, as: type, timeout: timeout)
    }

    /// Writes the reply's XCTest warnings to stderr and returns its result.
    private static func warned<Result>(_ reply: RunnerReply<Result>) -> Result {
        for issue in reply.issues {
            FileHandle.standardError.write(Data("XCTest warning: \(issue.message)\n".utf8))
        }
        return reply.result
    }

    private func send<Body: Encodable, Result: Codable & Sendable>(
        _ path: String,
        method: String,
        body: Body?,
        as type: Result.Type,
        timeout: Double
    ) async throws -> RunnerReply<Result> {
        let operationID = UUID().uuidString.lowercased()
        let request = try request(path, method: method, body: body, timeout: timeout, operationID: operationID)
        let json: Data
        do {
            (json, _) = try await urlSession.data(for: request)
        } catch let error as URLError {
            let transport = Self.transportError(error, path: path, method: method, host: baseURL.host ?? "device")
            throw identifying(transport, path: path, id: operationID)
        }
        do {
            var reply = try Self.decodeResponse(json, path: path, method: method, as: type)
            reply.operationID = operationID
            return reply
        } catch let error as DeviceLoopError {
            throw identifying(error, path: path, id: operationID)
        }
    }

    /// Adds the receipt to errors from requests the runner may have admitted.
    func identifying(_ error: DeviceLoopError, path: String, id: String) -> DeviceLoopError {
        let unadmitted =
            [RunnerWire.Path.health, RunnerWire.Path.time].contains(path) || path.hasPrefix(RunnerWire.Path.operations)
            || [.deviceBusy, .sessionMismatch].contains(error.code)
        if unadmitted { return error }
        var error = error
        error.operationID = id
        error.sessionEpoch = epoch
        return error
    }

    static let inspectStateFix = "Inspect the current device state before issuing another action."

    /// action_outcome_unknown for an action whose response was lost, since its input may have been delivered, and
    /// runner_unreachable for any other request.
    static func transportError(_ error: URLError, path: String, method: String, host: String) -> DeviceLoopError {
        if isMutation(path: path, method: method) {
            return unknownOutcome(detail: error.localizedDescription)
        }
        return DeviceLoopError(.runnerUnreachable, "Could not reach the runner at \(host).", detail: error.localizedDescription)
    }

    private static func isMutation(path: String, method: String) -> Bool {
        let readOnlyPaths = [
            RunnerWire.Path.tree, RunnerWire.Path.find, RunnerWire.Path.wait, RunnerWire.Path.waitStable,
            RunnerWire.Path.appState, RunnerWire.Path.appForeground, RunnerWire.Path.audit, RunnerWire.Path.intentsEntities,
        ]
        return method == "POST" && !readOnlyPaths.contains(path)
    }

    private static func unknownOutcome(detail: String) -> DeviceLoopError {
        DeviceLoopError(
            .actionOutcomeUnknown,
            "The runner did not return a readable, confirmed action result.",
            fix: inspectStateFix + " Do not automatically replay this request.",
            detail: detail
        )
    }

    static func decodeResponse<Result: Codable & Sendable>(_ json: Data, path: String, method: String, as type: Result.Type) throws
        -> RunnerReply<Result>
    {
        do {
            return try decodeResult(json, as: type)
        } catch let error as DecodingError {
            if isMutation(path: path, method: method) {
                throw unknownOutcome(detail: "The action response was incomplete or incompatible: \(error.localizedDescription)")
            }
            throw error
        }
    }

    static func decodeResult<Result: Codable & Sendable>(_ json: Data, as type: Result.Type) throws -> RunnerReply<Result> {
        let envelope = try JSONDecoder().decode(WireResponse<Result>.self, from: json)
        if let issues = envelope.issues, issues.contains(where: \.isFailure) {
            throw DeviceLoopError(
                .xctestIssue,
                "XCTest reported a failure; the action may have taken effect.",
                fix: "Inspect the current device state before retrying.",
                detail: issues.map(\.message).joined(separator: "\n")
            )
        }
        if envelope.ok, let result = envelope.result {
            return RunnerReply(result: result, issues: envelope.issues ?? [], timing: envelope.timing)
        }
        throw mapped(envelope.error)
    }

    func request<Body: Encodable>(
        _ path: String, method: String, body: Body?, timeout: Double, operationID: String = UUID().uuidString.lowercased()
    ) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(epoch, forHTTPHeaderField: RunnerWire.Header.epoch)
        request.setValue(operationID, forHTTPHeaderField: RunnerWire.Header.operationID)
        request.setValue("5000", forHTTPHeaderField: RunnerWire.Header.dispatchBudget)
        if let body, method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            request.httpBody = try encoder.encode(body)
        }
        return request
    }

    /// Maps a runner wire error to a DeviceLoop error.
    private static func mapped(_ error: WireError?) -> DeviceLoopError {
        guard let error else { return DeviceLoopError(.internalError, "Runner failed without a reason") }
        let detail = error.issues.isEmpty ? nil : error.issues.joined(separator: "\n")
        let code: DeviceLoopError.Code =
            switch error.code {
                case "element_not_found": .elementNotFound
                case "stale_ref": .staleRef
                case "snapshot_failed": .snapshotFailed
                case "element_ambiguous": .elementAmbiguous
                case "element_not_hittable": .elementNotHittable
                case "text_mismatch": .textMismatch
                case "timeout": .timeout
                case "unsupported": .unsupportedOnTarget
                case "app_not_running": .appNotRunning
                case "audit_failed": .auditFailed
                case "intent_failed": .intentFailed
                case "xctest_issue": .xctestIssue
                case "busy": .deviceBusy
                case "operation_in_progress": .operationInProgress
                case "operation_conflict": .operationConflict
                case "session_mismatch": .sessionMismatch
                case "receipt_unknown", "result_not_retained": .actionOutcomeUnknown
                case "dispatch_expired": .dispatchExpired
                case "bad_request": .badArguments
                default: .internalError
            }
        let fix: String? =
            switch code {
                case .xctestIssue: "Inspect the current device state before retrying."
                case .operationInProgress: "Poll the operation receipt until it finishes."
                case .actionOutcomeUnknown, .sessionMismatch: inspectStateFix
                case .textMismatch: "Take a new tree, empty the field another way, then type without --clear."
                case .auditFailed: "Bring the app to the foreground and wait for its screen, then run the audit again."
                case .intentFailed: "Check the intent, entity and parameter names against the app's App Intents."
                case .elementNotFound: "Check the target against deviceloop ui tree, or wait for it with deviceloop ui wait."
                case .staleRef: "Run deviceloop ui tree again and use a new ref."
                case .elementNotHittable: "Swipe the element onto the screen with deviceloop ui swipe, then tap it again."
                default: nil
            }
        return DeviceLoopError(code, error.message, fix: fix, detail: detail, alternatives: error.alternatives ?? [])
    }
}

/// A decoded runner result with the XCTest warnings and timing from its envelope.
struct RunnerReply<Result: Codable & Sendable>: Sendable {
    var result: Result
    var issues: [WireIssue] = []
    var timing: WireTiming?
    /// The request's operation ID, the receipt `deviceloop runner operation` reads.
    var operationID: String?
}

extension URL {
    /// Base URL for a runner reachable at `host` (a bracketed IPv6 tunnel address or `::1`) and `port`.
    static func runner(host: String, port: UInt16) -> URL {
        URL(string: "http://[\(host)]:\(port)/")!
    }
}
