//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import DeviceLoopProtocol
import Foundation

struct SiriCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "siri",
        abstract: "Change toggles, brightness and volume through Siri, or say anything to it.",
        discussion: "These need the device unlocked. DeviceLoop cannot read most of these settings back, so check the phone to confirm.",
        subcommands: [Say.self, Test.self, Wifi.self, Bluetooth.self, LowPower.self, DND.self, Airplane.self, Brightness.self, Volume.self]
    )

    struct Say: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Say anything to Siri, for example \"open Calculator\" or \"start a 5 minute timer\".",
            discussion: """
                Returns once the runner accepts the request. --wait polls the receipt until XCTest returns \
                and prints its status and XCTest issues. --expect then looks for an element and sets verified \
                only when it is found.
                """
        )
        @Argument(help: "What to say to Siri.") var text: String
        @Flag(name: .long, help: "Wait for XCTest to return and print the receipt.") var wait = false
        @Option(name: .long, help: "Seconds to wait for the receipt.") var timeout = 180
        @Option(name: .long, help: "id=login, label~=Wi or an exact label to find after Siri returns, as in ui tap. Implies --wait.")
        var expect: String?
        @Option(name: .long, help: "Bundle ID to search with --expect. Defaults to the app in front.") var app: String?
        @OptionGroup var target: TargetOptions
        func run() async throws {
            try await Output.run(target, hiding: [text]) {
                let query = try expect.map(Self.expectation)
                let waiting = wait || query != nil ? Duration.seconds(timeout) : nil
                return try await SiriCommands.say($0, text: text, wait: waiting, expect: query, app: app)
            }
        }

        /// Reads `--expect` like a ui target, without points, refs or the old `label=` form.
        static func expectation(_ text: String) throws -> ElementQuery {
            guard !text.hasPrefix("label="), let query = try UIStep.parseTarget(text).query else {
                throw DeviceLoopError(
                    .badArguments, "Cannot expect \(text).", fix: "Pass --expect id=<identifier>, label~=<text> or an exact label.")
            }
            return query
        }
    }

    struct Test: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a Siri phrase scenario against an app. Exits 8 when a phrase is not verified.",
            discussion: """
                A scenario is a JSON file:
                {"app": "<bundle ID>", "reset": {"intent": "ResetTasksIntent"}, "phrases": ["Add milk in MyApp"],
                 "expect": {"entity": "TaskEntity", "matching": "milk", "property": "title", "equals": "Milk", "count": 1}}
                Optional fields: "seed": [{"intent": "AddTaskIntent", "params": {"title": "Milk"}}] runs after each reset, \
                "timeoutS" is the receipt wait per phrase (default 180, at most 3600), "settleS" is the shortest time from \
                Siri accepting a phrase to the after screenshot and read-back (default 10, at most 600), and \
                "requiredLanguage" is checked against the device language. Unknown fields are rejected.

                Each phrase runs after the reset intent. Then the entities that "matching" finds are read through App \
                Intents, and the phrase is verified, missing, wrong_entity, duplicate, unverified or uncertain. Where App \
                Intents testing is unsupported, the app is brought to the front, labels containing "matching" are \
                counted, and the reset does not run. A lost connection stops the scenario without sending anything again. \
                Another error after a phrase stops the scenario, runs cleanup, saves report.json and exits with that \
                error. Cleanup runs the reset intent only.

                The first request for a fresh app's App Shortcut asks "Turn on '<app>' shortcuts with Siri?", so tap \
                Turn On once before siri test or the phrase reports missing.
                """
        )
        @Argument(help: "Scenario JSON file.") var scenario: String
        @Option(name: .long, help: "Directory for report.json and screenshots. Defaults to a new one under the artifacts directory.")
        var artifacts: String?
        @OptionGroup var target: TargetOptions
        func run() async throws {
            try await Output.run(target, exitCode: SiriCommands.exitCode) {
                let loaded = try SiriScenario.load(from: URL(filePath: scenario))
                return try await SiriCommands.test($0, scenario: loaded, artifacts: artifacts.map { URL(filePath: $0) })
            }
        }
    }

    struct Wifi: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn Wi-Fi on or off.")
        @Argument(help: "`on` or `off`.") var state: OnOff
        @OptionGroup var target: TargetOptions
        func run() async throws { try await Output.run(target) { try await SiriCommands.toggle($0, .wifi, on: state.on) } }
    }

    struct Bluetooth: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn Bluetooth on or off.")
        @Argument(help: "`on` or `off`.") var state: OnOff
        @OptionGroup var target: TargetOptions
        func run() async throws { try await Output.run(target) { try await SiriCommands.toggle($0, .bluetooth, on: state.on) } }
    }

    struct LowPower: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "lowpower", abstract: "Turn Low Power Mode on or off.")
        @Argument(help: "`on` or `off`.") var state: OnOff
        @OptionGroup var target: TargetOptions
        func run() async throws { try await Output.run(target) { try await SiriCommands.toggle($0, .lowPowerMode, on: state.on) } }
    }

    struct DND: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "dnd", abstract: "Turn Do Not Disturb on or off.")
        @Argument(help: "`on` or `off`.") var state: OnOff
        @OptionGroup var target: TargetOptions
        func run() async throws { try await Output.run(target) { try await SiriCommands.toggle($0, .doNotDisturb, on: state.on) } }
    }

    struct Airplane: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Turn Airplane Mode on or off. Over Wi-Fi this drops the connection to the device.")
        @Argument(help: "`on` or `off`.") var state: OnOff
        @OptionGroup var target: TargetOptions
        func run() async throws { try await Output.run(target) { try await SiriCommands.toggle($0, .airplaneMode, on: state.on) } }
    }

    struct Brightness: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set screen brightness, 0 to 100.")
        @Argument(help: "Percent, 0 to 100.") var percent: Int
        @OptionGroup var target: TargetOptions
        func run() async throws { try await Output.run(target) { try await SiriCommands.brightness($0, percent: percent) } }
    }

    struct Volume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set media volume, 0 to 100.")
        @Argument(help: "Percent, 0 to 100.") var percent: Int
        @OptionGroup var target: TargetOptions
        func run() async throws { try await Output.run(target) { try await SiriCommands.volume($0, percent: percent) } }
    }
}

enum OnOff: String, ExpressibleByArgument {
    case on
    case off
    var on: Bool { self == .on }
}
