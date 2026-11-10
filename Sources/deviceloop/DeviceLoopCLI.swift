//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit

@main
struct DeviceLoopCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deviceloop",
        abstract: "Drive iPhones, iPads and simulators from the command line.",
        discussion: """
            Commands work the same on a connected device and a booted simulator. Pick one with --device \
            (a UDID, a name or a unique part of it, `booted`, `usb` or `device`) or let DeviceLoop choose when only one is ready.

            First run: deviceloop setup
            """,
        version: version,
        subcommands: [
            SetupCLI.self,
            DoctorCLI.self,
            PrepareCLI.self,
            DevicesCLI.self,
            InfoCLI.self,
            ViewCLI.self,
            ScreenshotCLI.self,
            UICLI.self,
            FlowCLI.self,
            AppsCLI.self,
            InstallCLI.self,
            UninstallCLI.self,
            LaunchCLI.self,
            TerminateCLI.self,
            LogsCLI.self,
            OpenCLI.self,
            LocationCLI.self,
            AppearanceCLI.self,
            OrientationCLI.self,
            StateCLI.self,
            PasteboardCLI.self,
            CrashesCLI.self,
            ContainerCLI.self,
            VideoCLI.self,
            TestCLI.self,
            PerfCLI.self,
            TraceCLI.self,
            RunnerCLI.self,
            RunCLI.self,
            KeepAwakeCLI.self,
            LockCLI.self,
            SiriCLI.self,
            MCPCLI.self,
            CaptureHelperCLI.self,
        ]
    )

    /// Runs the command. A `DeviceLoopError` thrown outside `Output` is reported like one inside it and exits with its code.
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            var command = try await asyncParseAsRoot(arguments)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let error as DeviceLoopError {
            Output.report(error, json: arguments.prefix { $0 != "--" }.contains("--json"))
            exit(withError: ExitCode(error.exitCode))
        } catch {
            exit(withError: error)
        }
    }
}
