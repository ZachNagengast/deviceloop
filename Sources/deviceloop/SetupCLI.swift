//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import Foundation

struct SetupCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Run one-time setup: signing team and agent registration, then doctor.",
        discussion: """
            Prints the MCP registration command for each installed agent and runs them only with --yes.
            Use --dry-run to see everything setup would do without changing anything.
            """
    )

    @Option(name: .long, help: "Apple development team ID. Defaults to the team signed in to Xcode.")
    var team: String?

    @Flag(name: .long, help: "Run the agent registration commands instead of only printing them.")
    var yes = false

    @Flag(name: .long, help: "Print what setup would do and change nothing.")
    var dryRun = false

    @Flag(name: .long, help: "Do not register the MCP server with Claude Code, Codex, Cursor or Gemini CLI.")
    var noAgents = false

    @Option(
        name: [.short, .customLong("device")],
        help: "Device or simulator to finish setup on. Defaults to $DEVICELOOP_DEVICE, or every target when it is unset.")
    var device: String?

    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await Output.emit(json: output.json) {
            let target = try await selectedTarget(device)
            return try await SetupCommands.setup(team: team, registerAgents: !noAgents, target: target, apply: yes, dryRun: dryRun)
        }
    }
}

struct DoctorCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract:
            "Check Xcode, signing, pairing, Developer Mode, connection, lock state, UI Automation and the runner session, with one fix per problem.",
        discussion: """
            Checks the target --device or $DEVICELOOP_DEVICE names. Without either, checks every device, booted simulator \
            and simulator with an open state scope. Exits 1 when a check fails.
            --export DIR writes a support folder to attach to bug reports, with names, UDIDs, teams, tokens and paths \
            replaced by aliases, and exits 0 once it is written.
            """
    )

    @Option(
        name: [.short, .customLong("device")],
        help: "Check one device or simulator. Defaults to $DEVICELOOP_DEVICE, or every target when it is unset.")
    var device: String?

    @Option(
        name: .customLong("export"),
        help: "Write redacted doctor.json, version.txt, runs.json and REDACTIONS.txt to a new or empty folder.")
    var exportDirectory: String?

    @Flag(name: .long, help: "With --export, add the redacted tail of each runner startup log.")
    var includeRunnerLogs = false

    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await Output.emit(json: output.json, exitCode: Output.failedExitCode) {
            if let exportDirectory {
                let directory = URL(filePath: exportDirectory, relativeTo: .currentDirectory()).standardizedFileURL
                return try await SetupCommands.export(
                    try await selectedTarget(device), to: directory, includeRunnerLogs: includeRunnerLogs, version: version)
            }
            guard !includeRunnerLogs else {
                throw DeviceLoopError(.badArguments, "--include-runner-logs needs --export.", fix: "Pass --export DIR as well.")
            }
            return try await SetupCommands.doctor(try await selectedTarget(device))
        }
    }
}

/// The target named by --device or $DEVICELOOP_DEVICE, or nil to check every target.
private func selectedTarget(_ device: String?) async throws -> Target? {
    guard let selector = device ?? ProcessInfo.processInfo.environment["DEVICELOOP_DEVICE"] else { return nil }
    return try await TargetResolver.resolve(selector)
}

struct MCPCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the MCP protocol over stdio for agents."
    )

    func run() async throws {
        try await MCPServer.serve(version: version)
    }
}
