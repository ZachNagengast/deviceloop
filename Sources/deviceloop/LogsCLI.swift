//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import Foundation

struct LogsCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Capture an app's stdout, stderr and os_log, or a simulator's unified log, in the background.",
        subcommands: [Start.self, Read.self, Stop.self]
    )

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Relaunch an app with its console saved to a log file, or with --system stream a simulator's unified log.",
            discussion: """
                Prints a handle for `logs read` and `logs stop`.
                Examples:
                  deviceloop logs start com.example.MyApp
                  deviceloop logs start --system --predicate 'process == "MyApp"'
                """
        )

        @Argument(help: "Bundle ID. Leave it out with --system.")
        var bundleID: String?

        @Flag(name: .long, help: "Stream the simulator's unified log as ndjson with `log stream`, for apps launched any way.")
        var system = false

        @Option(name: .long, help: "With --system, a `log stream` predicate such as 'process == \"MyApp\"'.")
        var predicate: String?

        @Option(name: .customLong("env"), help: "Environment variable for the app, KEY=VALUE. Repeatable.")
        var environment: [String] = []

        @OptionGroup var target: TargetOptions

        @Argument(parsing: .postTerminator, help: "Arguments passed to the app after --.")
        var arguments: [String] = []

        func run() async throws {
            try await Output.run(target) { target in
                if system {
                    guard bundleID == nil, environment.isEmpty, arguments.isEmpty else {
                        throw DeviceLoopError.usage("logs start --system takes no bundle ID, --env or app arguments")
                    }
                    return try await LogCommands.startSystem(target, predicate: predicate)
                }
                guard let bundleID else { throw DeviceLoopError.usage("logs start needs a bundle ID, or --system for the unified log") }
                guard predicate == nil else { throw DeviceLoopError.usage("--predicate needs --system") }
                return try await LogCommands.start(
                    target, bundleID: bundleID, arguments: arguments, environment: try parseEnvironment(environment))
            }
        }
    }

    struct Read: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print lines captured so far.")

        @Argument(help: "Handle printed by `logs start`.")
        var handle: String

        @Option(name: .long, help: "Print only the last N lines.")
        var tail: Int?

        @Option(name: .long, help: "Print only lines that contain this text.")
        var grep: String?

        @OptionGroup var output: OutputOptions

        func run() async throws {
            try await Output.emit(json: output.json) { try await LogCommands.read(handle: handle, tail: tail, grep: grep) }
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Terminate the app and report how it exited, or end a --system stream, and finish the log file.")

        @Argument(help: "Handle printed by `logs start`.")
        var handle: String

        @OptionGroup var output: OutputOptions

        func run() async throws {
            try await Output.emit(json: output.json) { try await LogCommands.stop(handle: handle) }
        }
    }
}
