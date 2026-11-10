//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import Foundation

struct FlowCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "flow",
        abstract: "Check, run and export saved flow files (schema deviceloop.flow/1).",
        discussion: """
            Flow v1 has no siri, location, appearance, orientation, audit or checkpoint steps and cannot resume from a \
            checkpoint. While a flow runs, other flow runs and DeviceLoop commands on this Mac that use the UI runner fail \
            with device_busy for that device. Other DeviceLoop commands, other tools and a person at the device can still \
            send input.
            """,
        subcommands: [Validate.self, Run.self, Export.self]
    )

    struct Validate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check a flow file without a device and list what it needs.")

        @Argument(help: "Flow JSON file.")
        var file: String

        @OptionGroup var output: OutputOptions

        func run() async throws {
            try await Output.emit(json: output.json) { try FlowCommands.validate(try FlowCommands.load(file)) }
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a flow file and save its result and screenshots.",
            discussion: "Prints each step's result. Exits 1 when the flow fails, 130 when Ctrl-C stops it before the next step."
        )

        @Argument(help: "Flow JSON file.")
        var file: String

        @Option(name: .long, help: "Bundle ID to use instead of app.bundleID in the flow.")
        var app: String?

        @Option(name: .long, help: "Deadline for the whole flow in milliseconds, instead of timeoutMs in the flow.")
        var timeoutMs: Int?

        @OptionGroup var target: TargetOptions

        func run() async throws {
            let flow = try? FlowCommands.load(file)
            try await Output.runFlow(target, hiding: flow.map(FlowCommands.typedText) ?? []) {
                try await FlowCommands.run($0, flow: try FlowCommands.load(file), app: app, timeoutMs: timeoutMs)
            }
        }
    }

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write a flow as a new XCTest UI test file.",
            discussion: """
                Writes one XCTestCase class with one test method to a new .swift file. It does not replace a file or edit an \
                Xcode project: add the file to a UI test target yourself. Prints the number of exported steps and each \
                fragile one (points, drags, sleeps). Exits 2 and lists every step it cannot export: settle, type with clear and \
                reset reinstall.
                """
        )

        @Argument(help: "Flow JSON file.")
        var file: String

        @Option(name: [.short, .customLong("output")], help: "New .swift file to write.")
        var output: String

        @Option(name: .customLong("class"), help: "Test class name. Defaults to the flow name followed by FlowTests.")
        var className: String?

        @Option(name: .long, help: "Bundle ID to use instead of app.bundleID in the flow.")
        var app: String?

        @OptionGroup var options: OutputOptions

        func run() async throws {
            try await Output.emit(json: options.json) {
                try FlowCommands.export(try FlowCommands.load(file), to: URL(filePath: output), className: className, app: app)
            }
        }
    }
}
