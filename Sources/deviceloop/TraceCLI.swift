//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import Foundation

struct TraceCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trace",
        abstract: "Record Instruments traces with xctrace.",
        subcommands: [Record.self]
    )

    struct Record: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Record an Instruments trace of one running app, for --duration-ms or until Ctrl-C.",
            discussion: """
                Runs xctrace on the chosen device, attached to the app's pid. The raw .trace is kept, with its table of \
                contents (.toc.xml) and a deviceloop.trace/1 summary (.summary.json) of hitches and potential hangs next to it. \
                Recording needs about 0.5 GB of free disk per second plus 1 GB, and stops after at most 60000 ms. \
                Animation Hitches is not supported on simulators. A device where xctrace cannot attach fails with \
                unsupported_on_target.
                """)

        @Option(name: .long, help: "Bundle ID of the running app.")
        var app: String

        @Option(name: .long, help: "Template name from `xcrun xctrace list templates`. Defaults to Time Profiler.")
        var template: String?

        @Option(name: .long, help: "Stop after this many milliseconds, at most 60000. Defaults to 10000.")
        var durationMs: Int?

        @Option(name: [.short, .long], help: "Where to save the .trace bundle.")
        var output: String?

        @OptionGroup var target: TargetOptions

        func run() async throws {
            try await Output.run(target) {
                try await TraceCommands.record(
                    $0, app: app, template: template, durationMs: durationMs, output: output.map { URL(filePath: $0) })
            }
        }
    }
}
