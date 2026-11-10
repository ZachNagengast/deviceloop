//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import Testing

@testable import deviceloop

@Suite struct CLIOutputTests {
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
