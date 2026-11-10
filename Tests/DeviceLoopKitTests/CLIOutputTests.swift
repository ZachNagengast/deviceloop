//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import Testing

@testable import deviceloop

@Suite struct CLIOutputTests {
    /// `command` and every command below it.
    func commands(_ command: any ParsableCommand.Type) -> [any ParsableCommand.Type] {
        [command] + command.configuration.subcommands.flatMap(commands)
    }

    /// The words of a shell command line, with its quotes removed.
    func shellWords(_ line: Substring) -> [String] {
        var words = [""]
        var quote: Character?
        for character in line {
            if character == quote {
                quote = nil
            } else if quote == nil, character == "'" || character == "\"" {
                quote = character
            } else if quote == nil, character == " " {
                if !words[words.count - 1].isEmpty { words.append("") }
            } else {
                words[words.count - 1].append(character)
            }
        }
        return words.filter { !$0.isEmpty }
    }

    @Test func groupWithoutASubcommandIsJournaledWithItsDefault() {
        let words = Output.commandWords(["runner", "--json"])
        #expect(words.command == "runner status")
        #expect(words.args == ["--json"])
    }

    @Test func namedSubcommandIsJournaledOnce() {
        let words = Output.commandWords(["runner", "stop", "--json"])
        #expect(words.command == "runner stop")
        #expect(words.args == ["--json"])
    }

    @Test func everyRootCommandIsInExactlyOneHelpGroup() {
        let configuration = DeviceLoopCLI.configuration
        let names = configuration.groupedSubcommands.flatMap(\.subcommands).map { $0._commandName }
        #expect(configuration.ungroupedSubcommands.isEmpty)
        #expect(names.count == Set(names).count)
    }

    @Test func everyHelpExampleParses() {
        let examples = commands(DeviceLoopCLI.self).flatMap { command in
            command.configuration.discussion.split(separator: "\n").filter { $0.hasPrefix("  deviceloop ") }
        }
        #expect(!examples.isEmpty)
        for example in examples {
            let arguments = Array(shellWords(example).dropFirst())
            #expect(throws: Never.self, "\(example)") { try DeviceLoopCLI.parseAsRoot(arguments) }
        }
    }

    @Test func everyUIDoStepInHelpParses() throws {
        let lines = UICLI.DoCLI.configuration.discussion.split(separator: "\n")
        let start = try #require(lines.firstIndex(of: "Steps:"))
        let end = try #require(lines.firstIndex(of: "Examples:"))
        let steps = lines[(start + 1) ..< end].map { line in
            String(line.drop { $0 == " " }.split(separator: "  ", maxSplits: 1)[0])
        }
        #expect(steps.count == 11)
        for step in steps {
            #expect(throws: Never.self, "\(step)") { try UIStep.parse(step).validate() }
        }
    }

    @Test func emitExitsWithTheCodeOfTheReturnedResult() async throws {
        let audit = CommandResult(text: "", json: ["violations": 2])
        await #expect(throws: ExitCode(7)) {
            try await Output.emit(json: false, exitCode: { $0.json["violations"] == 0 ? 0 : 7 }, { audit })
        }
        try await Output.emit(json: false, exitCode: { _ in 0 }, { audit })
    }

    @Test func flowExitCodeFollowsTheFlowStatus() {
        let statuses = ["passed", "failed", "cleanup_failed", "cancelled"]
        let codes = statuses.map { Output.flowExitCode(CommandResult(text: "", json: ["status": .string($0)])) }
        #expect(codes == [0, 1, 1, 130])
        #expect(Output.flowExitCode(CommandResult(text: "")) == 0)
    }
}
