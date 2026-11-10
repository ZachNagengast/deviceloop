//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import Testing

@testable import deviceloop

@Suite struct ArgumentErrorsTests {
    /// The error `badArguments` reports for the parse failure of `arguments`.
    func failure(_ arguments: [String]) -> DeviceLoopError? {
        let error = #expect(throws: (any Error).self) { try DeviceLoopCLI.parseAsRoot(arguments) }
        return error.flatMap { ArgumentErrors.badArguments(for: $0, arguments: arguments) }
    }

    @Test func unknownOptionIsBadArgumentsWithTheCommandUsage() {
        let error = failure(["devices", "--json", "--bogus"])
        #expect(error?.code == .badArguments)
        #expect(error?.exitCode == 2)
        #expect(error?.message == "Unknown option '--bogus'.")
        #expect(error?.fix == "Run `deviceloop help devices`.")
        #expect(error?.detail == "Usage: deviceloop devices [--all] [--json]")
    }

    @Test func mistypedOptionNamesTheClosestOneInTheFix() {
        let error = failure(["devices", "--jsno"])
        #expect(error?.message == "Unknown option '--jsno'.")
        #expect(error?.fix == "Use `--json`.")
    }

    @Test func mistypedCommandNamesTheClosestOne() {
        let error = failure(["devcies"])
        #expect(error?.message == "deviceloop has no command devcies.")
        #expect(error?.fix == "Use `deviceloop devices`.")
    }

    @Test func mistypedCommandUnderAGroupWithADefaultNamesTheClosestOne() {
        let error = failure(["run", "stauts"])
        #expect(error?.message == "deviceloop run has no command stauts.")
        #expect(error?.fix == "Use `deviceloop run status`.")
        #expect(error?.detail == nil)
    }

    @Test func mistypedCommandBeforeAnOptionUnderAGroupWithADefaultNamesTheClosestOne() {
        let error = failure(["run", "strat", "--name", "login"])
        #expect(error?.message == "deviceloop run has no command strat.")
        #expect(error?.fix == "Use `deviceloop run start`.")
        #expect(error?.detail == nil)
    }

    @Test func wordTheDefaultSubcommandTakesGetsNoSuggestion() {
        let error = failure(["container", "lisst", "--bogus"])
        #expect(error?.message == "Unknown option '--bogus'.")
        #expect(error?.fix == "Run `deviceloop help container list`.")
    }

    @Test func emptyWordKeepsTheParserMessage() {
        let error = failure([""])
        #expect(error?.message == "Unexpected argument ''.")
        #expect(error?.fix == "Run `deviceloop help`.")
        #expect(ArgumentErrors.unknownHelpTopic(["help", ""]) == nil)
    }

    @Test func unsupportedShellNamesTheSupportedOnes() {
        let error = failure(["--generate-completion-script", "tcsh"])
        #expect(error?.message == "Can't generate completion scripts for 'tcsh'.")
        #expect(error?.fix == "Use `--generate-completion-script zsh`, `bash` or `fish`.")
    }

    @Test func wordFarFromEveryCommandPointsAtTheGroupHelp() {
        let error = failure(["ui", "xyzzy"])
        #expect(error?.message == "deviceloop ui has no command xyzzy.")
        #expect(error?.fix == "Run `deviceloop help ui`.")
    }

    @Test func equallyCloseCommandsAreNotSuggested() {
        #expect(ArgumentErrors.distance("typ", "type") == ArgumentErrors.distance("typ", "tap"))
        let error = failure(["ui", "typ", "hello"])
        #expect(error?.message == "deviceloop ui has no command typ.")
        #expect(error?.fix == "Run `deviceloop help ui`.")
    }

    @Test func hiddenCommandsAreNotSuggested() {
        #expect(ArgumentErrors.closest(to: "capture-helpr", under: DeviceLoopCLI.self) == nil)
        #expect(failure(["capture-helpr"])?.fix == "Run `deviceloop help`.")
    }

    @Test func badValueKeepsTheArgumentHelpInTheDetail() {
        let error = failure(["siri", "wifi", "maybe", "--json"])
        #expect(error?.message == "The value 'maybe' is invalid for '<state>'.")
        #expect(error?.fix == "Run `deviceloop help siri wifi`.")
        #expect(error?.detail == "Help:  <state>  `on` or `off`.\nUsage: deviceloop siri wifi <state> [--device <device>] [--json]")
    }

    @Test func missingArgumentPointsAtTheDefaultSubcommandHelp() {
        let error = failure(["container"])
        #expect(error?.message == "Missing expected argument '<bundle-id>'.")
        #expect(error?.fix == "Run `deviceloop help container list`.")
    }

    @Test func helpVersionAndCompletionRequestsAreNotBadArguments() throws {
        for arguments in [["--version"], ["--generate-completion-script", "zsh"]] {
            #expect(failure(arguments) == nil)
        }
        for arguments in [["--help"], ["ui", "tap", "--help"], ["help"], ["help", "ui", "tap"]] {
            #expect(ArgumentErrors.unknownHelpTopic(arguments) == nil)
            _ = try DeviceLoopCLI.parseAsRoot(arguments)
        }
    }

    @Test func optionValueAfterAHelpTopicIsNotACommand() {
        #expect(ArgumentErrors.unknownHelpTopic(["help", "ui", "tap", "--device", "booted"]) == nil)
    }

    @Test(arguments: [["swipe", "sideways"], ["press", "menu"], ["tap", "1,1", "--count", "3"], ["do", "sleep 999999"]])
    func uiArgumentsAreCheckedBeforeTheTarget(_ arguments: [String]) async throws {
        let parsed = try DeviceLoopCLI.parseAsRoot(["ui"] + arguments + ["--device", "no-such-device"])
        var command = try #require(parsed as? any AsyncParsableCommand)
        let error = await #expect(throws: DeviceLoopError.self) { try await command.run() }
        #expect(error?.code == .badArguments)
    }

    @Test func helpForAnUnknownCommandIsBadArguments() {
        let error = ArgumentErrors.unknownHelpTopic(["help", "devcies"])
        #expect(error?.code == .badArguments)
        #expect(error?.message == "deviceloop has no command devcies.")
        #expect(error?.fix == "Use `deviceloop help devices`.")
        #expect(ArgumentErrors.unknownHelpTopic(["help", "ui", "tpa"])?.fix == "Use `deviceloop help ui tap`.")
        #expect(ArgumentErrors.unknownHelpTopic(["help", "xyzzy"])?.fix == "Run `deviceloop help`.")
    }

    @Test func jsonCountsAnywhereBeforeTheTerminator() {
        #expect(Output.wantsJSON(["--json", "devices"]))
        #expect(Output.wantsJSON(["ui", "tap", "--count", "x", "1,1", "--json"]))
        #expect(!Output.wantsJSON(["ui", "type", "--", "--json"]))
    }

    @Test func swappedNeighborsCountAsOneEdit() {
        #expect(ArgumentErrors.distance("devcies", "devices") == 1)
        #expect(ArgumentErrors.distance("kitten", "sitting") == 3)
    }

    @Test func distanceFromAnEmptyWordIsTheOtherWordsLength() {
        #expect(ArgumentErrors.distance("", "ui") == 2)
    }
}
