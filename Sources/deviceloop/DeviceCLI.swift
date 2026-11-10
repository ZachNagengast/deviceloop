//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import Foundation

struct DevicesCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "devices",
        abstract: "List connected devices and simulators."
    )

    @Flag(name: .long, help: "Include shut-down simulators, unavailable devices and other platforms.")
    var all = false

    @OptionGroup var output: OutputOptions

    func run() async throws {
        try await Output.emit(json: output.json) { try await DeviceCommands.list(all: all) }
    }
}

struct InfoCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show model, OS, connection, lock state, screen, and what works on the target with a reason for the rest."
    )

    @OptionGroup var target: TargetOptions

    func run() async throws {
        try await Output.run(target) { try await DeviceCommands.info($0) }
    }
}

struct ViewCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "view", abstract: "Open the live screen in Device Hub so you can watch.")

    @OptionGroup var target: TargetOptions

    func run() async throws {
        try await Output.run(target) { try await DeviceCommands.view($0) }
    }
}

struct AppsCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "apps", abstract: "List installed apps, or running ones with --running.")

    @Flag(name: .long, help: "Include system apps.")
    var system = false

    @Flag(name: .long, help: "List running apps, system apps included, with pids, and the foreground app when a UI runner is running.")
    var running = false

    @Option(name: .long, help: "Show only apps whose name or bundle ID contains this text.")
    var name: String?

    @OptionGroup var target: TargetOptions

    func run() async throws {
        try await Output.run(target) {
            running ? try await AppCommands.running($0) : try await AppCommands.list($0, includeSystem: system, matching: name)
        }
    }
}

struct InstallCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Install and verify an .app or .ipa.")

    @Argument(help: "Path to the .app bundle or .ipa file.")
    var path: String

    @OptionGroup var target: TargetOptions

    func run() async throws {
        try await Output.run(target) { try await AppCommands.install($0, path: URL(filePath: path)) }
    }
}

struct UninstallCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Uninstall an app.")

    @Argument(help: "Bundle ID.")
    var bundleID: String

    @OptionGroup var target: TargetOptions

    func run() async throws {
        try await Output.run(target) { try await AppCommands.uninstall($0, bundleID: bundleID) }
    }
}

struct LaunchCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "launch", abstract: "Launch an app.")

    @Argument(help: "Bundle ID.")
    var bundleID: String

    @Option(name: .customLong("env"), help: "Environment variable for the app, KEY=VALUE. Repeatable.")
    var environment: [String] = []

    @Flag(
        name: .long,
        help: "Stream the app's stdout, stderr and os_log until it exits, and save them to a log file. With --json they go to stderr.")
    var console = false

    @Flag(name: .long, help: "Terminate a running instance first.")
    var restart = false

    @OptionGroup var target: TargetOptions

    @Argument(parsing: .postTerminator, help: "Arguments passed to the app after --.")
    var arguments: [String] = []

    func run() async throws {
        try await Output.run(target) { device in
            try await AppCommands.launch(
                device,
                bundleID: bundleID,
                arguments: arguments,
                environment: try parseEnvironment(environment),
                console: console,
                terminateExisting: restart,
                consoleOutput: target.json ? .standardError : .standardOutput
            )
        }
    }
}

struct TerminateCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "terminate", abstract: "Terminate a running app.")

    @Argument(help: "Bundle ID.")
    var bundleID: String

    @OptionGroup var target: TargetOptions

    func run() async throws {
        try await Output.run(target) { try await AppCommands.terminate($0, bundleID: bundleID) }
    }
}

struct OpenCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open a URL or deep link.")

    @Argument(help: "URL, for example https://apple.com or myapp://route.")
    var url: String

    @OptionGroup var target: TargetOptions

    func run() async throws {
        try await Output.run(target) { try await AppCommands.openURL($0, url: url) }
    }
}

struct LocationCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "location",
        abstract: "Set or clear the simulated location.",
        discussion: """
            Examples:
              deviceloop location 37.3349,-122.0090
              deviceloop location -- -33.8568,151.2153
              deviceloop location clear
            """
    )

    @Argument(help: "LAT,LON or `clear`.")
    var value: String

    @OptionGroup var target: TargetOptions

    func run() async throws {
        try await Output.run(target) { device in
            var coordinates: [Double?] = [nil, nil]
            if value != "clear" {
                let parts = value.split(separator: ",", omittingEmptySubsequences: false)
                coordinates = parts.map { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard coordinates.count == 2, !coordinates.contains(nil) else {
                    throw DeviceLoopError.usage("Expected LAT,LON, for example 37.3349,-122.0090")
                }
            }
            return try await SettingsCommands.location(device, latitude: coordinates[0], longitude: coordinates[1])
        }
    }
}

struct AppearanceCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "appearance", abstract: "Read or set light or dark appearance.")

    @Argument(help: "`light` or `dark`. Omit to read.")
    var mode: String?

    @OptionGroup var target: TargetOptions

    func run() async throws {
        try await Output.run(target) { try await SettingsCommands.appearance($0, mode: mode) }
    }
}

struct OrientationCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orientation",
        abstract: "Read or set the device orientation. Setting reports the previous value."
    )

    @Argument(help: "`portrait`, `portraitUpsideDown`, `landscapeLeft` or `landscapeRight`. Omit to read.")
    var value: String?

    @OptionGroup var target: TargetOptions

    func run() async throws {
        try await Output.run(target) { try await SettingsCommands.orientation($0, value: value) }
    }
}

struct PasteboardCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pasteboard",
        abstract: "Copy text to the device pasteboard, or print what is on it.",
        discussion: """
            Examples:
              deviceloop pasteboard copy "hello"
              deviceloop pasteboard paste
            """
    )

    @Argument(help: "`copy` or `paste`.")
    var action: String

    @Argument(help: "Text for `copy`.")
    var text: String?

    @OptionGroup var target: TargetOptions

    func run() async throws {
        try await Output.run(target, hiding: [text].compactMap { $0 }, savingResult: false) { device in
            switch action {
                case "copy":
                    guard let text else { throw DeviceLoopError.usage("pasteboard copy needs text") }
                    return try await SettingsCommands.pasteboardCopy(device, text: text)
                case "paste":
                    return try await SettingsCommands.pasteboardPaste(device)
                default:
                    throw DeviceLoopError.usage("Use `copy <text>` or `paste`.")
            }
        }
    }
}

struct CrashesCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "crashes",
        abstract: "List crash reports, or pull one to the Mac.",
        discussion: """
            Examples:
              deviceloop crashes --process MyApp
              deviceloop crashes pull MyApp-2026-10-22-131927.ips
            """
    )

    @Argument(help: "`pull` followed by a report name, or nothing to list.")
    var action: String?

    @Argument(help: "Report name for `pull`.")
    var name: String?

    @Option(name: .long, help: "Only reports for this process name.")
    var process: String?

    @Option(name: .long, help: "Maximum reports to list.")
    var limit = 20

    @Option(name: .long, help: "Only reports dated at or after this ISO 8601 time, such as launchedAt. Undated reports are kept.")
    var since: String?

    @Option(name: [.short, .long], help: "Directory for pulled reports.")
    var output: String?

    @OptionGroup var target: TargetOptions

    func run() async throws {
        try await Output.run(target) { device in
            switch action {
                case nil:
                    return try await CrashCommands.list(device, process: process, limit: limit, since: since)
                case "pull":
                    guard let name else { throw DeviceLoopError.usage("crashes pull needs a report name from `deviceloop crashes`") }
                    let directory = output.map { URL(filePath: $0) }
                    return try await CrashCommands.pull(device, name: name, to: directory)
                case let action?:
                    throw DeviceLoopError.usage("Unknown action \(action). Use `crashes pull <name>` or `crashes --process <name>`.")
            }
        }
    }
}
