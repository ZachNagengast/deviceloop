//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation

/// Moves audit issues of one type on one element to the suppressed list, with a reason.
public struct AuditSuppression: Codable, Sendable, Equatable {
    public var type: String
    public var id: String?
    public var label: String?
    public var reason: String

    public init(type: String, id: String? = nil, label: String? = nil, reason: String) {
        self.type = type
        self.id = id
        self.label = label
        self.reason = reason
    }

    /// True when the issue has this type and its element has every id and label the rule names.
    func matches(_ issue: AuditIssue) -> Bool {
        guard issue.type == type, let element = issue.element else { return false }
        return (id == nil || element.id == id) && (label == nil || element.label == label)
    }

    /// Why the rule is rejected, or nil when it names one type, an element and a reason.
    var problem: String? {
        if type.isEmpty { return "has no type" }
        if type.lowercased() == "all" { return "uses type all" }
        if id == nil, label == nil { return "has no id or label" }
        if id == "" || label == "" { return "has an empty id or label" }
        if reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "has an empty reason" }
        return nil
    }

    /// Reads a JSON array of rules and rejects any rule without one type, an id or label, and a reason.
    public static func load(from url: URL) throws -> [AuditSuppression] {
        let fix = #"Give each rule a type, an id or label, and a reason: [{"type": "contrast", "id": "login", "reason": "Brand color"}]."#
        let rules: [AuditSuppression]
        do {
            rules = try JSONDecoder().decode([AuditSuppression].self, from: Data(contentsOf: url))
        } catch {
            throw DeviceLoopError(.badArguments, "Could not read suppressions from \(url.path).", fix: fix, detail: "\(error)")
        }
        for (number, rule) in zip(1..., rules) {
            if let problem = rule.problem {
                throw DeviceLoopError(.badArguments, "Suppression \(number) in \(url.lastPathComponent) \(problem).", fix: fix)
            }
        }
        return rules
    }
}

public struct SuppressedAuditIssue: Codable, Sendable, Equatable {
    public var issue: AuditIssue
    public var reason: String
}

/// The `ui audit` result: printed with --json and saved next to the screenshot.
public struct AuditReport: Codable, Sendable, Equatable {
    public var app: String
    /// Issues no suppression matched.
    public var issues: [AuditIssue]
    public var suppressed: [SuppressedAuditIssue]
    /// Rules that matched no issue.
    public var staleSuppressions: [AuditSuppression]
    public var screenshot: String?
    /// Where this report was saved.
    public var path: String?

    /// Moves issues matched by a rule to `suppressed`, with the first matching rule's reason.
    /// Rules for a type outside `types` are not stale. Nil `types` means every type ran.
    public init(_ result: AuditResult, types: [String]? = nil, suppressions: [AuditSuppression]) {
        app = result.app
        issues = []
        suppressed = []
        for issue in result.issues {
            if let rule = suppressions.first(where: { $0.matches(issue) }) {
                suppressed.append(SuppressedAuditIssue(issue: issue, reason: rule.reason))
            } else {
                issues.append(issue)
            }
        }
        staleSuppressions = suppressions.filter { rule in
            (types?.contains(rule.type) ?? true) && !result.issues.contains(where: rule.matches)
        }
    }
}

public enum AuditCommands {
    /// Exit status of `deviceloop ui audit` when issues remain after suppressions.
    public static let issuesExitCode: Int32 = 7

    /// `deviceloop ui audit`: audits the app in front, or `app`, then saves a devicectl or simctl screenshot and the report.
    public static func audit(
        _ target: Target, app: String?, types: [String]?, suppressions: [AuditSuppression], screenshot: Bool
    ) async throws -> CommandResult {
        let session = try await UICommands.connect(target, focusing: app)
        let result: AuditResult
        do {
            result = try await session.client.post(RunnerWire.Path.audit, AuditRequest(app: app, types: types), as: AuditResult.self)
        } catch let error as DeviceLoopError {
            throw unsupportedIfMissing(error, on: target)
        }
        var report = AuditReport(result, types: types, suppressions: suppressions)
        var images: [ImageAttachment] = []
        var files: [URL] = []
        let reportURL: URL
        if screenshot {
            let png = try Paths.newArtifact("audit", extension: "png")
            images = try await UICommands.screenshot(target, scale: .points, output: png).images
            report.screenshot = png.path
            files.append(png)
            reportURL = png.deletingPathExtension().appendingPathExtension("json")
        } else {
            reportURL = try Paths.newArtifact("audit", extension: "json")
        }
        report.path = reportURL.path
        let json = try JSONValue(encoding: report)
        try json.data(pretty: true).write(to: reportURL)
        files.append(reportURL)
        return CommandResult(text: render(report, target: target), json: json, images: images, files: files)
    }

    /// 0, or `issuesExitCode` when the audit result lists unsuppressed issues.
    public static func exitCode(_ result: CommandResult) -> Int32 {
        result.json["issues"]?.array?.isEmpty == false ? issuesExitCode : 0
    }

    /// Turns the unknown-endpoint answer of a runner built before audits into `unsupported_on_target`.
    static func unsupportedIfMissing(_ error: DeviceLoopError, on target: Target) -> DeviceLoopError {
        guard error.code == .badArguments, error.message.hasPrefix("Unknown endpoint") else { return error }
        return DeviceLoopError(
            .unsupportedOnTarget, "The runner on \(target.name) has no accessibility audit.",
            fix: "Run deviceloop runner stop, then run the audit again to start a current runner.",
            detail: error.message, device: target.name)
    }

    /// Issues grouped by type, suppressed issues, stale rules, saved files, then the scope line.
    static func render(_ report: AuditReport, target: Target) -> String {
        let count = report.issues.count
        var lines = [target.summary]
        lines.append(
            "\(report.app): \(count == 0 ? "no" : "\(count)") issue\(count == 1 ? "" : "s")"
                + (report.suppressed.isEmpty ? "" : ", \(report.suppressed.count) suppressed"))
        for (type, issues) in Dictionary(grouping: report.issues, by: \.type).sorted(by: { $0.key < $1.key }) {
            lines.append("\(type) (\(issues.count))")
            lines += issues.map { "  \(element($0)): \($0.compactDescription)" }
        }
        if !report.suppressed.isEmpty {
            lines.append("suppressed (\(report.suppressed.count))")
            lines += report.suppressed.map { "  \($0.issue.type) \(element($0.issue)): \($0.reason)" }
        }
        if !report.staleSuppressions.isEmpty {
            lines.append("stale suppressions, matched no issue (\(report.staleSuppressions.count))")
            lines += report.staleSuppressions.map { rule in
                let selector = [rule.id.map { "id=\($0)" }, rule.label.map { "\"\($0)\"" }].compactMap(\.self)
                return "  \(([rule.type] + selector).joined(separator: " ")): \(rule.reason)"
            }
        }
        lines += [report.screenshot, report.path].compactMap { $0.map { "saved \($0)" } }
        lines.append("The audit covers this screen only and is not an accessibility certification.")
        return lines.joined(separator: "\n")
    }

    private static func element(_ issue: AuditIssue) -> String {
        issue.element.map(UICommands.describe) ?? "no element"
    }
}
