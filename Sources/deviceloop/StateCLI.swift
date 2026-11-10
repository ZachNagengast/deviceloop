//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import Foundation

struct StateCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "state",
        abstract: "Read, save and compare identity and settings, with each field marked observed or not.",
        subcommands: [Inspect.self, Capture.self, Diff.self, Scope.self, Restore.self]
    )

    struct Inspect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show every field and why the unknown ones are unknown.")

        @OptionGroup var target: TargetOptions

        func run() async throws {
            try await Output.run(target) { try await StateCommands.inspect($0) }
        }
    }

    struct Capture: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save the state to a JSON file only you can read.")

        @Option(name: [.short, .long], help: "Where to save it. Defaults to the DeviceLoop state folder.")
        var output: String?

        @OptionGroup var target: TargetOptions

        func run() async throws {
            try await Output.run(target) { try await StateCommands.capture($0, output: output.map { URL(filePath: $0) }) }
        }
    }

    struct Diff: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Compare a capture with another capture, or with the live state.",
            discussion: """
                Examples:
                  deviceloop state diff before.json after.json
                  deviceloop state diff before.json --live
                """
        )

        @Argument(help: "Capture file from `deviceloop state capture`.")
        var before: String

        @Argument(help: "Second capture file. Omit with --live.")
        var after: String?

        @Flag(name: .long, help: "Compare with a new read of the target.")
        var live = false

        @Option(name: [.short, .customLong("device")], help: "With --live, the target to read. Defaults to the captured target.")
        var device: String?

        @OptionGroup var output: OutputOptions

        func run() async throws {
            try await Output.emit(json: output.json) {
                switch (after, live) {
                    case (let after?, false): return try StateCommands.diff(URL(filePath: before), URL(filePath: after))
                    case (nil, true): return try await StateCommands.diff(URL(filePath: before), live: device)
                    case (nil, false): throw DeviceLoopError.usage("Pass a second capture file or --live.")
                    default: throw DeviceLoopError.usage("Pass a second capture file or --live, not both.")
                }
            }
        }
    }

    struct Scope: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Journal the setting changes DeviceLoop makes on a target.",
            subcommands: [Start.self, Status.self]
        )

        struct Start: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Capture a baseline and journal each later change with its original value.")

            @Flag(name: .long, help: "Refuse changes DeviceLoop cannot set back: location, Siri system controls and pasteboard copy.")
            var strict = false

            @OptionGroup var target: TargetOptions

            func run() async throws {
                try await Output.run(target) { try await StateCommands.scopeStart($0, strict: strict) }
            }
        }

        struct Status: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show whether a scope is open and the changes journaled in it.")

            @OptionGroup var target: TargetOptions

            func run() async throws {
                try await Output.run(target) { try StateCommands.scopeStatus($0) }
            }
        }
    }

    struct Restore: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set the journaled changes back, newest first, and close the scope.",
            discussion: """
                A field that changed since DeviceLoop set it is a conflict and stays as it is. Location, Siri system controls and \
                pasteboard copy are unsupported. Exits 7 with cleanup_incomplete, keeping the scope open, unless every change is \
                restored, unchanged or cleared, or --dry-run or --accept-residual is set.
                """
        )

        @Flag(name: .long, help: "Show what restore would do without setting anything.")
        var dryRun = false

        @Flag(name: .long, help: "Set conflicting fields back anyway.")
        var overwriteConflicts = false

        @Flag(name: .long, help: "Close the scope even when changes are left in place.")
        var acceptResidual = false

        @Flag(name: .long, help: "Clear the simulated location. The location before the scope cannot be read, so it is lost.")
        var clearLocation = false

        @OptionGroup var target: TargetOptions

        func run() async throws {
            try await Output.run(target) {
                try await StateCommands.restore(
                    $0, dryRun: dryRun, overwriteConflicts: overwriteConflicts, acceptResidual: acceptResidual,
                    clearLocation: clearLocation)
            }
        }
    }
}
