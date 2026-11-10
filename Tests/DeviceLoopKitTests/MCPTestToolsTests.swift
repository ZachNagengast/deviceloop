//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

extension MCPServerTests {
    @Test func cancelledTestRunInterruptsItsJob() async throws {
        try await withSleepJob { entry in
            let call = Task { try await MCPTools.follow(entry, until: .now.advanced(by: .seconds(30))) }
            call.cancel()
            await #expect(throws: CancellationError.self) { try await call.value }
            let result = try await MCPTools.report(entry, until: .now.advanced(by: .seconds(20)))
            #expect(result.json["status"] == "cancelled")
            #expect(result.json["cancelReason"] == "interrupt")
        }
    }

    @Test(arguments: ["test_run", "test_status", "test_cancel"])
    func failedOrCancelledTestJobIsAnErrorResult(tool: String) throws {
        let failed = try #require(MCPTools.testTools.first { $0.name == tool }).failed
        let statuses = ["failed", "cancelled", "passed", "running", "cancelling"]
        let errors = statuses.filter { failed(CommandResult(text: "", json: ["status": .string($0)])) }
        #expect(errors == ["failed", "cancelled"])
    }

    @Test func testRunIsJournaledInTheActiveRun() async throws {
        let target = Self.simulator()
        try await recording(on: target) { run in
            let replies = try await exchange(
                [call(1, "test_run", ["xctestrun": "/missing/App.xctestrun"])], tools: MCPTools.testTools
            ) { _ in target }
            #expect(replies[0].value(at: "result.structuredContent.error.code") == "bad_arguments")
            let events = try run.events().events
            #expect(events.map(\.kind) == ["started", "finished"])
            #expect(events.map(\.command) == ["test_run", "test_run"])
        }
    }
}
