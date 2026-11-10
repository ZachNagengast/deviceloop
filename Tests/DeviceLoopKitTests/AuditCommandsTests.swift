//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Testing

@testable import DeviceLoopKit

private func simulator(platform: String = "iOS") -> Target {
    Target(
        udid: "00000000-0000-0000-0000-000000000001",
        identifier: "00000000-0000-0000-0000-000000000001",
        name: "Test Simulator",
        kind: .simulator,
        deviceType: "iPhone",
        platform: platform,
        model: "iPhone 17 Pro",
        productType: "iPhone18,1",
        osVersion: "27.2",
        connectionState: "connected",
        bootState: "booted",
        transport: "sameMachine"
    )
}

private let increment = AuditIssue(
    type: "contrast", compactDescription: "Contrast nearly passed", detailedDescription: "Text is hard to read",
    element: FoundElement(type: "button", id: "fixture.counter.increment", label: "Increment", frame: [20, 100, 80, 44]))
private let submit = AuditIssue(
    type: "contrast", compactDescription: "Contrast failed", detailedDescription: "Text is hard to read",
    element: FoundElement(type: "button", id: "fixture.text.submit", label: "Submit", frame: [20, 200, 80, 44]))
private let clipped = AuditIssue(
    type: "textClipped", compactDescription: "Text clipped", detailedDescription: "Text is cut off",
    element: FoundElement(type: "button", id: "fixture.counter.increment", label: "Increment", frame: [20, 100, 80, 44]))
private let audit = AuditResult(app: "com.example.host", issues: [increment, clipped, submit])

private func decoded(_ response: WireResponse<AuditResult>) throws -> AuditResult {
    try RunnerClient.decodeResponse(JSONEncoder().encode(response), path: RunnerWire.Path.audit, method: "POST", as: AuditResult.self)
        .result
}

private func exitCode(_ report: AuditReport) throws -> Int32 {
    AuditCommands.exitCode(CommandResult(text: "", json: try JSONValue(encoding: report)))
}

private func rulesFile(_ json: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "deviceloop-suppressions-\(UUID().uuidString).json")
    try Data(json.utf8).write(to: url)
    return url
}

@Suite struct AuditCommandsTests {
    @Test func textGroupsIssuesByTypeAndEndsWithTheScopeLine() {
        var report = AuditReport(audit, suppressions: [])
        report.screenshot = "/tmp/audit.png"
        report.path = "/tmp/audit.json"
        #expect(
            AuditCommands.render(report, target: simulator()) == """
                Test Simulator (simulator, iOS 27.2)
                com.example.host: 3 issues
                contrast (2)
                  button "Increment" id=fixture.counter.increment [20,100,80,44]: Contrast nearly passed
                  button "Submit" id=fixture.text.submit [20,200,80,44]: Contrast failed
                textClipped (1)
                  button "Increment" id=fixture.counter.increment [20,100,80,44]: Text clipped
                saved /tmp/audit.png
                saved /tmp/audit.json
                The audit covers this screen only and is not an accessibility certification.
                """)
    }

    @Test func jsonListsIssuesSuppressedStaleAndFiles() throws {
        var report = AuditReport(audit, suppressions: [AuditSuppression(type: "trait", id: "gone", reason: "Removed screen")])
        report.screenshot = "/tmp/audit.png"
        report.path = "/tmp/audit.json"
        let json = try JSONValue(encoding: report)
        #expect(json.object.map { Set($0.keys) } == ["app", "issues", "suppressed", "staleSuppressions", "screenshot", "path"])
        #expect(json["issues"]?[0]?.value(at: "element.id")?.string == "fixture.counter.increment")
        #expect(json["staleSuppressions"]?[0]?["reason"]?.string == "Removed screen")
    }

    @Test func issuesExitWithTheIssuesCode() throws {
        let result = try decoded(.completed(audit, timing: WireTiming(start: 0, end: 1, elapsed: 1), issues: []))
        #expect(try exitCode(AuditReport(result, suppressions: [])) == AuditCommands.issuesExitCode)
    }

    @Test func zeroIssuesExitZero() throws {
        let clean = AuditResult(app: "com.example.host", issues: [])
        let result = try decoded(.completed(clean, timing: WireTiming(start: 0, end: 1, elapsed: 1), issues: []))
        #expect(try exitCode(AuditReport(result, suppressions: [])) == 0)
    }

    @Test func auditThatCouldNotRunExitsAsAFailure() throws {
        let error = #expect(throws: DeviceLoopError.self) {
            try decoded(WireResponse(ok: false, error: WireError(code: "audit_failed", message: "Invalid target app")))
        }
        let mapped = AuditCommands.unsupportedIfMissing(try #require(error), on: simulator())
        #expect(mapped.code == .auditFailed)
        #expect(mapped.exitCode == 1)
    }

    @Test func runnerWithoutTheAuditRouteIsUnsupported() throws {
        let error = #expect(throws: DeviceLoopError.self) {
            try decoded(WireResponse(ok: false, error: WireError(code: "bad_request", message: "Unknown endpoint POST /v1/audit")))
        }
        let mapped = AuditCommands.unsupportedIfMissing(try #require(error), on: simulator())
        #expect(mapped.code == .unsupportedOnTarget)
        #expect(mapped.exitCode == 6)
    }

    @Test func unknownAuditTypeStaysABadArgument() throws {
        let error = #expect(throws: DeviceLoopError.self) {
            try decoded(WireResponse(ok: false, error: WireError(code: "bad_request", message: "Unknown audit type color.")))
        }
        #expect(AuditCommands.unsupportedIfMissing(try #require(error), on: simulator()).code == .badArguments)
    }

    @Test func nonIOSTargetIsUnsupported() async {
        let error = await #expect(throws: DeviceLoopError.self) {
            try await AuditCommands.audit(simulator(platform: "watchOS"), app: nil, types: nil, suppressions: [], screenshot: false)
        }
        #expect(error?.code == .unsupportedOnTarget)
    }

    @Test func ruleWithTypeAndIdMovesOnlyThatIssue() {
        let rule = AuditSuppression(type: "contrast", id: "fixture.counter.increment", reason: "Brand color")
        let report = AuditReport(audit, suppressions: [rule])
        #expect(report.suppressed == [SuppressedAuditIssue(issue: increment, reason: "Brand color")])
        #expect(report.issues == [clipped, submit])
        #expect(report.staleSuppressions.isEmpty)
    }

    @Test func ruleWithLabelMatchesTheLabel() {
        let report = AuditReport(audit, suppressions: [AuditSuppression(type: "contrast", label: "Submit", reason: "Approved")])
        #expect(report.suppressed.map(\.issue) == [submit])
    }

    @Test func fullySuppressedAuditExitsZero() throws {
        let rules = [
            AuditSuppression(type: "contrast", id: "fixture.counter.increment", reason: "Brand color"),
            AuditSuppression(type: "contrast", id: "fixture.text.submit", reason: "Brand color"),
            AuditSuppression(type: "textClipped", label: "Increment", reason: "Fixed in next release"),
        ]
        #expect(try exitCode(AuditReport(audit, suppressions: rules)) == 0)
    }

    @Test func unmatchedRuleIsStale() {
        let stale = AuditSuppression(type: "textClipped", id: "fixture.text.submit", reason: "Old layout")
        let report = AuditReport(audit, suppressions: [stale])
        #expect(report.staleSuppressions == [stale])
        #expect(report.issues == audit.issues)
    }

    @Test func ruleForATypeThatDidNotRunIsNotStale() {
        let rule = AuditSuppression(type: "trait", id: "gone", reason: "Removed screen")
        #expect(AuditReport(audit, types: ["contrast", "textClipped"], suppressions: [rule]).staleSuppressions.isEmpty)
    }

    @Test func staleRulesAreListedInText() {
        let report = AuditReport(audit, suppressions: [AuditSuppression(type: "trait", id: "gone", reason: "Removed screen")])
        let text = AuditCommands.render(report, target: simulator())
        #expect(text.contains("stale suppressions, matched no issue (1)\n  trait id=gone: Removed screen"))
    }

    @Test func loadReadsScopedRules() throws {
        let url = try rulesFile(#"[{"type": "contrast", "id": "login", "reason": "Brand color"}]"#)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try AuditSuppression.load(from: url) == [AuditSuppression(type: "contrast", id: "login", reason: "Brand color")])
    }

    @Test(arguments: [
        #"[{"type": "contrast", "reason": "Brand color"}]"#,
        #"[{"type": "contrast", "id": "", "label": "", "reason": "Brand color"}]"#,
        #"[{"type": "contrast", "id": "", "label": "Submit", "reason": "Brand color"}]"#,
        #"[{"type": "all", "id": "login", "reason": "Brand color"}]"#,
        #"[{"type": "contrast", "id": "login", "reason": " "}]"#,
        #"[{"type": "contrast", "id": "login"}]"#,
    ])
    func unscopedOrUnexplainedRuleIsRejected(json: String) throws {
        let url = try rulesFile(json)
        defer { try? FileManager.default.removeItem(at: url) }
        let error = #expect(throws: DeviceLoopError.self) { try AuditSuppression.load(from: url) }
        #expect(error?.code == .badArguments)
    }
}
