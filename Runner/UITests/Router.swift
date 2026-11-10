//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import CryptoKit
import UIKit
import XCTest

/// Admits one UI operation at a time before dispatch, so run-loop reentrancy cannot overlap two.
/// Answers health and receipt lookups while XCTest or Siri holds the main actor.
final class Router: @unchecked Sendable {
    @MainActor var stopped = false
    private let started = ProcessInfo.processInfo.systemUptime
    private let operations = OperationStore<HTTPResponse>()

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "GET", request.path == RunnerWire.Path.health {
            let active = operations.current(now: now)
            return .json(
                WireResponse(
                    ok: true,
                    result: HealthResult(
                        version: RunnerWire.version,
                        runnerBuild: Bundle(for: DeviceLoopRunner.self).infoDictionary?["CFBundleVersion"] as? String ?? "0",
                        os: ProcessInfo.processInfo.operatingSystemVersionString,
                        uptimeS: now - started,
                        busy: active != nil,
                        currentOp: active?.id,
                        currentElapsedMs: active.map { Int((now - $0.admittedAt) * 1000) },
                        queue: 0,
                        sessionEpoch: operations.epoch
                    )))
        }
        if request.method == "GET", request.path == RunnerWire.Path.time {
            return .json(WireResponse(ok: true, result: TimeResult(wall: Date().timeIntervalSince1970, uptime: now)))
        }
        guard request.headers[RunnerWire.Header.epoch] == operations.epoch else {
            return RunnerError.response(409, "session_mismatch", "The request is for a different runner session")
        }
        if request.method == "GET", request.path.hasPrefix(RunnerWire.Path.operations) {
            return operationStatus(String(request.path.dropFirst(RunnerWire.Path.operations.count)))
        }
        guard let rawID = request.headers[RunnerWire.Header.operationID], let uuid = UUID(uuidString: rawID) else {
            return RunnerError.response(400, "bad_request", "A UUID operation ID is required")
        }
        let id = uuid.uuidString.lowercased()
        let rawBudget = request.headers[RunnerWire.Header.dispatchBudget] ?? "5000"
        guard let budget = Int(rawBudget), (1 ... 30000).contains(budget) else {
            return RunnerError.response(400, "bad_request", "Dispatch budget must be 1...30000 milliseconds")
        }
        let deadline = now + Double(budget) / 1000
        var fingerprint = Data("\(request.method)\n\(request.path)\n\(rawBudget)\n".utf8)
        fingerprint.append(request.body)
        let digest = SHA256.hash(data: fingerprint).map { String(format: "%02x", $0) }.joined()
        let token: OperationToken
        switch operations.begin(id: id, fingerprint: digest, now: now) {
            case .admitted(let admitted): token = admitted
            case .replay(let response): return response
            case .inProgress:
                return RunnerError.response(409, "operation_in_progress", "This operation is already running")
            case .conflict:
                return RunnerError.response(409, "operation_conflict", "This operation ID already identifies a different request")
            case .busy:
                return RunnerError.response(409, "busy", "Another UI operation is active. This request was not queued or executed.")
        }
        if request.method == "POST", request.path == RunnerWire.Path.siri, (try? request.decode(SiriRequest.self)) != nil {
            // Acknowledge admission while keeping the gate held until the synchronous Siri call returns.
            Task { @MainActor in _ = await execute(request, token: token, deadline: deadline) }
            let receipt = OperationReference(id: id, sessionEpoch: operations.epoch, phase: "accepted")
            return .json(WireResponse(ok: true, result: ActionResult(operation: receipt)), status: 202)
        }
        return await execute(request, token: token, deadline: deadline)
    }

    private func operationStatus(_ rawID: String) -> HTTPResponse {
        guard let id = UUID(uuidString: rawID)?.uuidString.lowercased() else {
            return RunnerError.response(400, "bad_request", "Receipt ID must be a UUID")
        }
        guard let receipt = operations.lookup(id: id, now: now) else {
            return RunnerError.response(404, "receipt_unknown", "No receipt is retained for this operation. It may still have run.")
        }
        let response = receipt.response
        let json = response?.contentType == "application/json" ? response.flatMap { String(data: $0.body, encoding: .utf8) } : nil
        let status = OperationStatusResult(
            operation: OperationReference(
                id: id, sessionEpoch: operations.epoch, phase: receipt.state == .running ? "running" : "finished"),
            responseStatus: response?.status, responseContentType: response?.contentType, responseJSON: json
        )
        return .json(WireResponse(ok: true, result: status))
    }

    @MainActor
    private func execute(_ request: HTTPRequest, token: OperationToken, deadline: Double) async -> HTTPResponse {
        let response: HTTPResponse
        if now >= deadline {
            response = RunnerError.response(408, "dispatch_expired", "The request expired before UI execution. No input was sent.")
        } else {
            DeviceLoopRunner.recordedIssues.reset()
            response = await route(request)
        }
        // Preserve a small terminal receipt even when a screenshot or tree is too large to retain.
        let retained =
            response.body.count <= 65536
            ? response
            : RunnerError.response(410, "result_not_retained", "The operation finished, but its result was too large to keep")
        operations.finish(token: token, response: retained, now: now, cost: retained.body.count)
        return response
    }

    /// Runs one request on the main actor and returns its response.
    @MainActor
    func route(_ request: HTTPRequest) async -> HTTPResponse {
        let start = Date()
        let startedUptime = ProcessInfo.processInfo.systemUptime
        func ok<T: Codable & Sendable>(_ build: () async throws -> T) async -> HTTPResponse {
            do {
                let result = try await build()
                let timing = WireTiming(
                    start: start.timeIntervalSince1970,
                    end: Date().timeIntervalSince1970,
                    elapsed: ProcessInfo.processInfo.systemUptime - startedUptime
                )
                let response = WireResponse.completed(result, timing: timing, issues: DeviceLoopRunner.recordedIssues.snapshot())
                return .json(response, status: response.ok ? 200 : 500)
            } catch let failure as RunnerFailure {
                return RunnerError.response(
                    statusFor(failure.code), failure.code, failure.message,
                    issues: DeviceLoopRunner.recordedIssues.snapshot().map(\.message),
                    alternatives: failure.alternatives)
            } catch {
                return RunnerError.response(500, "internal", "\(error)", issues: DeviceLoopRunner.recordedIssues.snapshot().map(\.message))
            }
        }
        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            do {
                return try request.decode(type)
            } catch {
                throw RunnerFailure("bad_request", "Could not read the request body: \(error)")
            }
        }

        switch (request.method, request.path) {
            case ("POST", RunnerWire.Path.shutdown):
                stopped = true
                return await ok { WireEmpty() }
            case ("GET", RunnerWire.Path.info):
                return await ok { UIActions.info() }
            case ("GET", RunnerWire.Path.screenshot):
                let image = UIActions.screenshot()
                let issues = DeviceLoopRunner.recordedIssues.snapshot()
                if issues.contains(where: \.isFailure) {
                    return RunnerError.response(
                        500, "xctest_issue", "XCTest could not reliably capture the screen.", issues: issues.map(\.message))
                }
                return HTTPResponse(status: 200, contentType: "image/png", body: image)
            case ("POST", RunnerWire.Path.appLaunch):
                return await ok { UIActions.launch(try decode(AppRequest.self)) }
            case ("POST", RunnerWire.Path.appTerminate):
                return await ok { UIActions.terminate(try decode(AppRequest.self).app) }
            case ("POST", RunnerWire.Path.appState):
                return await ok { UIActions.state(try decode(AppRequest.self).app) }
            case ("POST", RunnerWire.Path.appForeground):
                return await ok { UIActions.foreground(try decode(ForegroundRequest.self).candidates) }
            case ("POST", RunnerWire.Path.openURL):
                return await ok { try UIActions.openURL(try decode(OpenURLRequest.self)) }
            case ("POST", RunnerWire.Path.tree):
                return await ok { try UIActions.tree(try decode(TreeRequest.self)) }
            case ("POST", RunnerWire.Path.find):
                return await ok { UIActions.find(try decode(FindRequest.self)) }
            case ("POST", RunnerWire.Path.wait):
                return await ok { try UIActions.wait(try decode(WaitRequest.self)) }
            case ("POST", RunnerWire.Path.waitStable):
                return await ok { try UIActions.waitStable(try decode(WaitStableRequest.self)) }
            case ("POST", RunnerWire.Path.tap):
                return await ok { try UIActions.tap(try decode(TapRequest.self)) }
            case ("POST", RunnerWire.Path.drag):
                return await ok { try UIActions.drag(try decode(DragRequest.self)) }
            case ("POST", RunnerWire.Path.swipe):
                return await ok { try UIActions.swipe(try decode(SwipeRequest.self)) }
            case ("POST", RunnerWire.Path.pinch):
                return await ok { try UIActions.pinch(try decode(PinchRequest.self)) }
            case ("POST", RunnerWire.Path.type):
                return await ok { try UIActions.type(try decode(TypeRequest.self)) }
            case ("POST", RunnerWire.Path.key):
                return await ok { UIActions.key(try decode(KeyRequest.self)) }
            case ("POST", RunnerWire.Path.button):
                return await ok { try UIActions.button(try decode(ButtonRequest.self).name) }
            case ("POST", RunnerWire.Path.siri):
                return await ok { UIActions.siri(try decode(SiriRequest.self).text) }
            case ("GET", RunnerWire.Path.alert):
                return await ok { UIActions.readAlert() }
            case ("POST", RunnerWire.Path.alert):
                return await ok { try UIActions.actOnAlert(try decode(AlertActionRequest.self)) }
            case ("POST", RunnerWire.Path.audit):
                return await ok { try UIActions.audit(try decode(AuditRequest.self)) }
            case ("POST", RunnerWire.Path.intentsRun):
                return await ok { try await Intents.run(try decode(IntentRunRequest.self)) }
            case ("POST", RunnerWire.Path.intentsEntities):
                return await ok { try await Intents.entities(try decode(IntentEntitiesRequest.self)) }
            default:
                return RunnerError.response(404, "bad_request", "Unknown endpoint \(request.method) \(request.path)")
        }
    }

    private func statusFor(_ code: String) -> Int {
        switch code {
            case "bad_request": return 400
            case "element_not_found", "stale_ref": return 404
            case "unsupported": return 501
            case "timeout": return 504
            default: return 500
        }
    }
}
