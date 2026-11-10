//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// Every failure DeviceLoop reports. The code is stable and documented, the fix line comes first.
public struct DeviceLoopError: Error, Codable, Sendable, Equatable {
    public enum Code: String, Codable, Sendable, CaseIterable {
        case badArguments = "bad_arguments"
        case deviceNotFound = "device_not_found"
        case deviceAmbiguous = "device_ambiguous"
        case deviceOffline = "device_offline"
        case deviceLocked = "device_locked"
        case trustRequired = "trust_required"
        case developerModeOff = "developer_mode_off"
        case ddiUnavailable = "ddi_unavailable"
        case osUnsupported = "os_unsupported"
        case xcodeMissing = "xcode_missing"
        case signingNoTeam = "signing_no_team"
        case signingProfileFailed = "signing_profile_failed"
        case runnerBuildFailed = "runner_build_failed"
        case runnerInstallFailed = "runner_install_failed"
        case uiAutomationPasscode = "ui_automation_passcode"
        case uiAutomationDisabled = "ui_automation_disabled"
        case runnerUnreachable = "runner_unreachable"
        case recorderBusy = "recorder_busy"
        case screenCaptureDenied = "screen_capture_denied"
        case deviceBusy = "device_busy"
        case unsupportedOnTarget = "unsupported_on_target"
        case appNotInstalled = "app_not_installed"
        case appNotRunning = "app_not_running"
        case appRunning = "app_running"
        case appCrashed = "app_crashed"
        case elementNotFound = "element_not_found"
        case staleRef = "stale_ref"
        case snapshotFailed = "snapshot_failed"
        case elementAmbiguous = "element_ambiguous"
        case elementNotHittable = "element_not_hittable"
        case textMismatch = "text_mismatch"
        case auditFailed = "audit_failed"
        case intentFailed = "intent_failed"
        case assertionFailed = "assertion_failed"
        case timeout
        case xctestIssue = "xctest_issue"
        case actionOutcomeUnknown = "action_outcome_unknown"
        case operationInProgress = "operation_in_progress"
        case operationConflict = "operation_conflict"
        case sessionMismatch = "session_mismatch"
        case dispatchExpired = "dispatch_expired"
        case cleanupIncomplete = "cleanup_incomplete"
        case deviceError = "device_error"
        case internalError = "internal_error"
    }

    /// Who has to act before a retry can succeed.
    public enum Actor: String, Codable, Sendable {
        case agent
        case user
    }

    public var code: Code
    public var message: String
    public var fix: String?
    public var detail: String?
    public var alternatives: [String]
    public var device: String?
    public var operationID: String?
    public var sessionEpoch: String?

    public init(
        _ code: Code,
        _ message: String,
        fix: String? = nil,
        detail: String? = nil,
        alternatives: [String] = [],
        device: String? = nil
    ) {
        self.code = code
        self.message = message
        self.fix = fix
        self.detail = detail
        self.alternatives = alternatives
        self.device = device
    }

    public var actor: Actor {
        switch code {
            case .deviceOffline, .deviceLocked, .trustRequired, .developerModeOff, .osUnsupported, .xcodeMissing,
                .signingNoTeam, .signingProfileFailed, .uiAutomationPasscode, .uiAutomationDisabled,
                .screenCaptureDenied:
                .user
            default:
                .agent
        }
    }

    public var retryable: Bool {
        switch code {
            case .runnerUnreachable, .deviceBusy, .timeout, .ddiUnavailable, .recorderBusy, .dispatchExpired: true
            default: actor == .user
        }
    }

    /// Process exit status for the CLI.
    public var exitCode: Int32 {
        switch code {
            case .badArguments, .deviceNotFound, .deviceAmbiguous: 2
            case .deviceOffline, .ddiUnavailable, .osUnsupported, .runnerUnreachable: 4
            case .timeout: 5
            case .unsupportedOnTarget: 6
            case .cleanupIncomplete: 7
            default: actor == .user ? 3 : 1
        }
    }

    /// The error line, then optional Fix, Try and Detail lines.
    public var rendered: String {
        var lines = ["ERROR \(code.rawValue)\(actor == .user ? " (needs user)" : ""): \(message)"]
        if let fix { lines.append("Fix: \(fix)") }
        if !alternatives.isEmpty { lines.append("Try: " + alternatives.joined(separator: " | ")) }
        if let detail { lines.append("Detail: \(detail)") }
        if let operationID, let sessionEpoch {
            lines.append("Receipt: deviceloop runner operation \(operationID) --epoch \(sessionEpoch)")
        }
        return lines.joined(separator: "\n")
    }

    private enum CodingKeys: String, CodingKey {
        case code, message, fix, detail, alternatives, device, actor, retryable, operationID, sessionEpoch
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(fix, forKey: .fix)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encode(alternatives, forKey: .alternatives)
        try container.encodeIfPresent(device, forKey: .device)
        try container.encodeIfPresent(operationID, forKey: .operationID)
        try container.encodeIfPresent(sessionEpoch, forKey: .sessionEpoch)
        try container.encode(actor, forKey: .actor)
        try container.encode(retryable, forKey: .retryable)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Code.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        fix = try container.decodeIfPresent(String.self, forKey: .fix)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        alternatives = try container.decodeIfPresent([String].self, forKey: .alternatives) ?? []
        device = try container.decodeIfPresent(String.self, forKey: .device)
        operationID = try container.decodeIfPresent(String.self, forKey: .operationID)
        sessionEpoch = try container.decodeIfPresent(String.self, forKey: .sessionEpoch)
    }
}

extension DeviceLoopError: LocalizedError {
    public var errorDescription: String? { rendered }
}

extension DeviceLoopError {
    public static func usage(_ message: String) -> DeviceLoopError {
        DeviceLoopError(.badArguments, message)
    }

    /// `error` with `line` added to its detail. Cancellation passes through and other errors become `internal_error`.
    public static func adding(detail line: String, to error: any Error) -> any Error {
        if error is CancellationError { return error }
        var failure = error as? DeviceLoopError ?? DeviceLoopError(.internalError, "\(error)")
        failure.detail = [failure.detail, line].compactMap { $0 }.joined(separator: "\n")
        return failure
    }

    public static func unsupported(_ what: String, on target: Target, capability: String? = nil, alternatives: [String] = [])
        -> DeviceLoopError
    {
        DeviceLoopError(
            .unsupportedOnTarget,
            "\(what) is not available on \(target.summary).",
            detail: capability.map { "missing capability \($0)" },
            alternatives: alternatives,
            device: target.name
        )
    }
}
