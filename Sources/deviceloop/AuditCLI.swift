//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import Foundation

struct AuditCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit",
        abstract: "Run XCTest's accessibility audit on the screen in front. Exits 7 when issues remain.",
        discussion: """
            Saves a screenshot and the JSON report.
            Types: contrast, elementDetection, hitRegion, sufficientElementDescription, dynamicType, textClipped, trait.
            A suppressions file is a JSON array of rules, each with a type, an id or label, and a reason:
            [{"type": "contrast", "id": "login", "reason": "Brand color"}]
            """
    )

    @Option(name: .customLong("type"), help: "Audit type to run. Repeatable. Defaults to every type.")
    var types: [String] = []

    @Option(name: .long, help: "JSON file of rules for known issues.")
    var suppressions: String?

    @Flag(name: .long, help: "Skip the screenshot.")
    var noScreenshot = false

    @OptionGroup var app: AppOption
    @OptionGroup var target: TargetOptions

    func run() async throws {
        try await Output.run(target, exitCode: AuditCommands.exitCode) {
            let rules = try suppressions.map { try AuditSuppression.load(from: URL(filePath: $0)) } ?? []
            return try await AuditCommands.audit(
                $0, app: app.app, types: types.isEmpty ? nil : types, suppressions: rules, screenshot: !noScreenshot)
        }
    }
}
