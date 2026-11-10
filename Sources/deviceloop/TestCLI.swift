//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import Foundation

struct TestCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run XCTest and Swift Testing suites and read their results.",
        subcommands: [Run.self, Results.self]
    )

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a scheme, test plan or prebuilt .xctestrun with xcodebuild and summarize its result bundle.",
            discussion: """
                Each run gets a job directory with result.xcresult, xcodebuild.log and summary.json. The result comes \
                from the bundle. Exits 0 when tests pass, 1 when tests or the build fail, 130 after Ctrl-C and 5 after \
                --timeout. Ctrl-C or the timeout sends xcodebuild SIGINT and waits up to 60 s for it to finish the bundle.

                --xctestrun runs the output of build-for-testing with test-without-building, and fails with \
                unsupported_on_target when it was built for a simulator and the target is a device, or the reverse.

                On a device, fails with device_locked when it is locked, and with ui_automation_passcode when nobody \
                enters the passcode that UI tests ask for. Test diagnostics are off unless --diagnostics is passed.

                Fails with device_busy while the UI runner or another test run uses the target. Arguments after -- go \
                to xcodebuild unchanged.
                """
        )

        @Option(help: "Path to the .xcodeproj.")
        var project: String?

        @Option(help: "Path to the .xcworkspace.")
        var workspace: String?

        @Option(help: "Path to a .xctestrun from xcodebuild build-for-testing, instead of a project or workspace.")
        var xctestrun: String?

        @Option(help: "Scheme to test, with --project or --workspace.")
        var scheme: String?

        @Option(name: .customLong("test-plan"), help: "Test plan of the scheme.")
        var testPlan: String?

        @Option(name: .customLong("only-testing"), help: "Run only this test identifier, for example Target/Class/test(). Repeatable.")
        var onlyTesting: [String] = []

        @Option(name: .customLong("skip-testing"), help: "Skip this test identifier. Repeatable.")
        var skipTesting: [String] = []

        @Option(help: "Build configuration, for example Debug.")
        var configuration: String?

        @Option(help: "Seconds before the run is cancelled.")
        var timeout: Int = 3600

        @Flag(name: .customLong("allow-provisioning-updates"), help: "Let xcodebuild create and update signing profiles.")
        var allowProvisioningUpdates = false

        @Flag(help: "Collect test diagnostics, like a sysdiagnose, when a test fails.")
        var diagnostics = false

        @Flag(name: .customLong("stop-runner"), help: "Stop a running UI runner on the target first.")
        var stopRunner = false

        @OptionGroup var target: TargetOptions

        @Argument(parsing: .postTerminator, help: "Arguments passed to xcodebuild after --.")
        var xcodebuildArguments: [String] = []

        func run() async throws {
            try await Output.run(target, exitCode: TestCLI.exitCode) { target in
                try await TestCommands.run(
                    target, project: project, workspace: workspace, xctestrun: xctestrun, scheme: scheme,
                    testPlan: testPlan, onlyTesting: onlyTesting, skipTesting: skipTesting, configuration: configuration,
                    allowProvisioningUpdates: allowProvisioningUpdates, diagnostics: diagnostics,
                    extraArguments: xcodebuildArguments, timeout: .seconds(timeout), stopRunner: stopRunner
                )
            }
        }
    }

    /// 1 when the job's tests or build failed, 5 after its timeout, 130 after any other cancellation, otherwise 0.
    static func exitCode(_ job: CommandResult) -> Int32 {
        switch (job.json["status"]?.string, job.json["cancelReason"]?.string) {
            case ("failed", _): 1
            case ("cancelled", "timeout"): 5
            case ("cancelled", _): 130
            default: 0
        }
    }

    struct Results: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Summarize an .xcresult bundle: destination, counts, failures and build errors.",
            discussion: "Works on bundles from xcodebuild, Xcode or other tools. Reads them with xcrun xcresulttool."
        )

        @Argument(help: "Path to the .xcresult bundle.")
        var bundle: String

        @OptionGroup var output: OutputOptions

        func run() async throws {
            try await Output.emit(json: output.json) { try await TestCommands.results(URL(filePath: bundle)) }
        }
    }
}
