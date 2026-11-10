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
            Commands work the same on a connected device and a booted simulator.

            Start here:
              deviceloop devices --all
              xcrun simctl bootstatus <udid> -b
              export DEVICELOOP_DEVICE=<udid>
              deviceloop screenshot
              deviceloop ui tree
              deviceloop ui tap <label>

            The first ui command builds and starts the UI runner, which can take a minute. For a device or an agent, run \
            deviceloop setup first. It stores the signing team and prints the MCP registration for each agent. A device then \
            needs deviceloop prepare --device <udid>.

            Environment:
              DEVICELOOP_DEVICE       The target when --device is left out. Without it,
                                      a command acts on the only ready device or simulator.
              DEVICELOOP_HOME         Where DeviceLoop keeps its files.
                                      Defaults to ~/Library/Caches/deviceloop.
              DEVICELOOP_RUNNER_PATH  The Runner folder the UI runner is built from.
              DEVICELOOP_NOTIFY=0     No notification when a device waits for its passcode.
            """,
        version: version,
        groupedSubcommands: [
            CommandGroup(
                name: "Devices and setup",
                subcommands: [
                    DevicesCLI.self, InfoCLI.self, SetupCLI.self, DoctorCLI.self, PrepareCLI.self, RunnerCLI.self, MCPCLI.self,
                ]),
            CommandGroup(name: "Screen and UI", subcommands: [ScreenshotCLI.self, ViewCLI.self, UICLI.self, KeepAwakeCLI.self]),
            CommandGroup(
                name: "Apps and logs",
                subcommands: [
                    AppsCLI.self, InstallCLI.self, UninstallCLI.self, LaunchCLI.self, TerminateCLI.self, OpenCLI.self, LogsCLI.self,
                    CrashesCLI.self, ContainerCLI.self,
                ]),
            CommandGroup(
                name: "Settings and Siri",
                subcommands: [
                    LocationCLI.self, AppearanceCLI.self, OrientationCLI.self, PasteboardCLI.self, StateCLI.self, LockCLI.self,
                    SiriCLI.self,
                ]),
            CommandGroup(
                name: "Tests and recordings",
                subcommands: [
                    FlowCLI.self, RunCLI.self, TestCLI.self, PerfCLI.self, VideoCLI.self, TraceCLI.self, CaptureHelperCLI.self,
                ]),
        ]
    )

    /// Runs the command. Usage errors and a `DeviceLoopError` thrown outside `Output` are reported like errors inside it.
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let json = Output.wantsJSON(arguments)
        if arguments.first == "help" { arguments.removeAll { $0 == "--json" } }
        if let failure = ArgumentErrors.unknownHelpTopic(arguments) { fail(failure, json: json) }
        var command: any ParsableCommand
        do {
            command = try await asyncParseAsRoot(arguments)
        } catch {
            guard let failure = ArgumentErrors.badArguments(for: error, arguments: arguments) else { exit(withError: error) }
            fail(failure, json: json)
        }
        do {
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let error as DeviceLoopError {
            fail(error, json: json)
        } catch {
            exit(withError: error)
        }
    }

    /// Prints `error` as text or JSON and exits with its code.
    static func fail(_ error: DeviceLoopError, json: Bool) -> Never {
        Output.report(error, json: json)
        exit(withError: ExitCode(error.exitCode))
    }
}
