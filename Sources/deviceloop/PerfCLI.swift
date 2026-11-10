//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import Foundation

struct PerfCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "perf",
        abstract: "Measure an app with XCTest metrics in a finite run of the UI runner.",
        subcommands: [Launch.self, Run.self, Compare.self]
    )

    struct Launch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Measure how long an installed app takes to launch, with XCTApplicationLaunchMetric.",
            discussion: """
                Runs the runner's launch test as a test run job and reports each measurement with its statistics, the \
                device and OS build, and the app version. Simulator timings come from the Mac. Exits like test run: 0 \
                when the test passes, 1 when it fails, 130 after Ctrl-C and 5 after --timeout.

                Fails with recorder_busy while the target is being recorded, and with device_busy while the UI runner \
                or a test run uses it.
                """
        )

        @Argument(help: "Bundle ID of the installed app to launch.")
        var bundleID: String

        @Option(help: "Measured launches. XCTest launches once more first and discards it.")
        var iterations = 5

        @Option(
            name: .customLong("launch-arg"), parsing: .unconditionalSingleValue,
            help: "Argument passed to the app on every launch. Repeatable.")
        var launchArguments: [String] = []

        @Option(help: "Seconds before the run is cancelled.")
        var timeout: Int = 600

        @Flag(name: .customLong("stop-runner"), help: "Stop a running UI runner on the target first.")
        var stopRunner = false

        @OptionGroup var target: TargetOptions

        func run() async throws {
            try await Output.run(target, exitCode: TestCLI.exitCode) { target in
                try await PerfCommands.launch(
                    target, bundleID: bundleID, iterations: iterations, launchArguments: launchArguments,
                    timeout: .seconds(timeout), stopRunner: stopRunner
                )
            }
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Measure UI steps in an installed app with XCTest hitch, CPU, memory, clock and signpost metrics.",
            discussion: """
                Each iteration relaunches the app and runs the --setup steps, then measures the --measure steps. Steps \
                use the ui step grammar without refs, for example 'tap id=open', 'swipe up' or 'sleep 500'. Text from \
                type steps is kept in the job's result bundle and log. A step that fails fails \
                the run and is not retried. Hitch metrics need iOS 26 or later, and a requested metric without \
                measurements is reported as unavailable with the reason. scroll measures UIKit's scrolling and \
                deceleration signposts, and signpost:<subsystem>/<category>/<name> an os_signpost interval the app \
                emits. Exits like test run: 0 when the test passes, 1 when it fails, 130 after Ctrl-C and 5 after \
                --timeout.
                """
        )

        @Option(help: "Bundle ID of the installed app to measure.")
        var app: String

        @Option(help: "Step run after each relaunch, before the measured interval. Repeatable.")
        var setup: [String] = []

        @Option(help: "Step run inside the measured interval. Repeatable.")
        var measure: [String] = []

        @Option(
            name: .customLong("metric"),
            help: """
                Comma-separated metrics: hitch, cpu, memory, clock, scroll, signpost:<subsystem>/<category>/<name>. \
                Signpost names cannot contain commas.
                """)
        var metrics = "hitch,cpu,memory,clock"

        @Option(help: "Measured iterations. XCTest runs one more first and discards it.")
        var iterations = 5

        @Option(
            name: .customLong("launch-arg"), parsing: .unconditionalSingleValue,
            help: "Argument passed to the app on every launch. Repeatable.")
        var launchArguments: [String] = []

        @Option(help: "Seconds before the run is cancelled.")
        var timeout: Int = 600

        @Flag(name: .customLong("stop-runner"), help: "Stop a running UI runner on the target first.")
        var stopRunner = false

        @OptionGroup var target: TargetOptions

        /// Every type step in `setup` and `measure` with its text, journaled as `[hidden]`.
        var typed: [String] {
            (setup + measure).flatMap { step in (try? UIStep.parse(step))?.typedText.map { [step, $0] } ?? [] }
        }

        func run() async throws {
            try await Output.run(target, hiding: typed, exitCode: TestCLI.exitCode) { target in
                try await PerfCommands.run(
                    target, bundleID: app, setup: setup, measure: measure, metrics: try PerfCommands.metrics(metrics),
                    iterations: iterations, launchArguments: launchArguments, timeout: .seconds(timeout), stopRunner: stopRunner
                )
            }
        }
    }

    struct Compare: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Compare the metrics of two perf or test run jobs.",
            discussion: """
                Takes each job's directory, its summary.json or an .xcresult bundle. Metrics match by test, configuration \
                and identifier, and repeated entries of one metric match in order. A metric is different only when both \
                runs have at least 5 measurements and their min to max ranges do not overlap, and no_difference_detected \
                when the ranges overlap. It is inconclusive with fewer measurements or different units, and every metric \
                is inconclusive when the devices, OS builds or perf scenarios (app and steps) differ. Launch arguments are \
                listed, not compared.
                Examples:
                  deviceloop perf compare <job-dir-a> <job-dir-b>
                  deviceloop perf compare baseline.xcresult candidate.xcresult
                """
        )

        @Argument(help: "Baseline job directory, summary.json or .xcresult bundle.")
        var baseline: String

        @Argument(help: "Candidate job directory, summary.json or .xcresult bundle.")
        var candidate: String

        @OptionGroup var output: OutputOptions

        func run() async throws {
            try await Output.emit(json: output.json) {
                try await PerfCommands.compare(URL(filePath: baseline), URL(filePath: candidate))
            }
        }
    }
}
