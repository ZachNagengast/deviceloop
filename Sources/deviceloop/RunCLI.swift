//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import Foundation

struct RunCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Record the commands sent to a device into a run folder.",
        discussion: """
            Between `run start` and `run stop`, every command on that device is journaled with its outcome, result JSON and files.
            Examples:
              deviceloop run start --name login --app com.example.MyApp
              deviceloop ui tap id=login
              deviceloop run stop
            """,
        subcommands: [Start.self, Stop.self, Status.self, Show.self, Report.self, List.self, Prune.self, Compare.self, Export.self],
        defaultSubcommand: Status.self
    )

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start recording the device's commands into a new run.")

        @Option(name: .long, help: "A name for the run.")
        var name: String?

        @Option(name: .long, help: "Bundle ID of the app under test. Records its version and build.")
        var app: String?

        @Option(name: .long, help: "Git checkout of the app. Records its commit and whether it has changes.")
        var source: String?

        @OptionGroup var target: TargetOptions

        func run() async throws {
            try await Output.emit(json: target.json) {
                try await RunCommands.start(
                    TargetResolver.resolve(target.device), name: name, app: app, source: source.map { URL(filePath: $0) },
                    version: version, owned: false)
            }
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Finish the device's run and print its report.")
        @OptionGroup var target: TargetOptions
        func run() async throws {
            try await Output.emit(json: target.json) { try await RunCommands.stop(TargetResolver.resolve(target.device)) }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the report of the device's active run.")
        @OptionGroup var target: TargetOptions
        func run() async throws {
            try await Output.emit(json: target.json) { try await RunCommands.status(TargetResolver.resolve(target.device)) }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the report of any run.")
        @Argument(help: "Run ID, for example run-20261108-131927-3f9a2c.") var id: String
        @OptionGroup var output: OutputOptions
        func run() async throws {
            try await Output.emit(json: output.json) { try RunCommands.show(id) }
        }
    }

    struct Report: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Render report.html of any run again.")
        @Argument(help: "Run ID, for example run-20261108-131927-3f9a2c.") var id: String
        @OptionGroup var output: OutputOptions
        func run() async throws {
            try await Output.emit(json: output.json) { try RunCommands.renderReport(id) }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List runs, newest first, with status, first failure and size.")
        @OptionGroup var output: OutputOptions
        func run() async throws {
            try await Output.emit(json: output.json) { try RunCommands.list() }
        }
    }

    struct Prune: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove old runs. Runs that a device records into are kept.",
            discussion: """
                With both options, a run is removed only when both select it.
                Examples:
                  deviceloop run prune --keep 10
                  deviceloop run prune --older-than 30
                """)

        @Option(name: .long, help: ArgumentHelp("Remove runs created more than this many days ago.", valueName: "days"))
        var olderThan: Int?

        @Option(name: .long, help: ArgumentHelp("Keep this many of the newest runs.", valueName: "n"))
        var keep: Int?

        @OptionGroup var output: OutputOptions

        func run() async throws {
            try await Output.emit(json: output.json) { try RunCommands.prune(keep: keep, olderThan: olderThan) }
        }
    }

    struct Compare: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Compare two runs step by step. Writes comparison.json and comparison.html, never into the runs.",
            discussion: """
                The result is inconclusive when the product type, OS build, screen, orientation, app or command sequence differ. \
                Otherwise each step is same, regressed (ok to error), fixed (error to ok) or changed (a different error).
                Steps where both runs saved a ui tree also list added, removed and ambiguous elements, and label, value, \
                enabled and frame changes. Elements match by type and id, else by type and label.
                Steps where both runs saved a screenshot list the share of changed pixels outside the masks, the changed areas \
                in points and a diff image. Screenshots of different sizes make the result inconclusive.
                Steps where both runs saved a video analysis compare latency, animation, last change and visual gap times. These are \
                visual estimates from one uncalibrated capture each, so a timing is only changed, never regressed.
                Examples:
                  deviceloop run compare run-20261108-131927-3f9a2c run-20261108-140210-7b1d04
                  deviceloop run compare <baseline> <candidate> --mask 0,0,430,54
                """)

        @Argument(help: "Baseline run ID.") var baseline: String
        @Argument(help: "Candidate run ID.") var candidate: String

        @Option(
            name: .long,
            help: ArgumentHelp(
                "Leave this element and the elements inside it out of the tree differences. Repeatable.", valueName: "id=ID"))
        var ignore: [String] = []

        @Option(
            name: .long,
            help: ArgumentHelp("Leave this rectangle out of the screenshot differences, in points. Repeatable.", valueName: "x,y,w,h"))
        var mask: [String] = []

        @Option(
            name: .long,
            help: ArgumentHelp("A screenshot changed when more than this percent of its unmasked pixels changed.", valueName: "percent"))
        var maxDiff = 0.1

        @Option(
            name: .long,
            help: ArgumentHelp(
                "A timing changed when it differs by more than this, or by twice the recording's frame slot when that is larger.",
                valueName: "ms"))
        var minMs = 50

        @OptionGroup var output: OutputOptions

        func run() async throws {
            try await Output.emit(json: output.json) {
                try RunCommands.compare(baseline, candidate, ignore: ignore, mask: mask, maxDiff: maxDiff, minMs: Double(minMs))
            }
        }
    }

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Copy a run, or a comparison and its two runs, into a new folder to attach to a bug report.",
            discussion: """
                Device names, UDIDs, teams, tokens and the home path become aliases, typed text and pasteboard contents are \
                hidden, and report.html is rendered again from the redacted copy. EXPORT.txt lists the SHA256 of every file and \
                the replacements. Screenshots, videos and UI text are copied as recorded, so review them before you share the folder. \
                Runs are only read.
                Examples:
                  deviceloop run export run-20261108-131927-3f9a2c --out bug-report --zip
                  deviceloop run export --comparison <id> --out bug-report --no-media
                """)

        @Argument(help: "Run ID, for example run-20261108-131927-3f9a2c.") var id: String?

        @Option(name: .long, help: ArgumentHelp("Export this comparison and its two runs instead of a run.", valueName: "id"))
        var comparison: String?

        @Option(name: .long, help: ArgumentHelp("The folder to write. It must not exist yet.", valueName: "dir"))
        var out: String

        @Flag(name: .long, help: "Leave out screenshots, videos and other images.")
        var noMedia = false

        @Flag(name: .long, help: "Keep typed text and pasteboard contents.")
        var keepTypedText = false

        @Flag(name: .long, help: "Also write <dir>.zip with ditto.")
        var zip = false

        @OptionGroup var output: OutputOptions

        func run() async throws {
            try await Output.emit(json: output.json) {
                try await RunCommands.export(
                    id, comparison: comparison, to: URL(filePath: out, relativeTo: .currentDirectory()).standardizedFileURL,
                    media: !noMedia, keepTypedText: keepTypedText, zip: zip)
            }
        }
    }
}
