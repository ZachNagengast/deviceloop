//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

extension MCPServerTests {
    @Test(
        arguments: [
            (["action": "start", "bundle_id": "not a bundle"], "bad_arguments"),
            (["action": "start", "system": true], "device_offline"),
        ] as [(JSONValue, String)])
    func appLogsStartIsJournaledInTheActiveRun(arguments: JSONValue, code: String) async throws {
        var target = Self.simulator()
        target.bootState = "shutdown"
        try await recording(on: target) { run in
            let replies = try await exchange([call(1, "app_logs", arguments)], tools: MCPTools.logs) { [target] _ in target }
            #expect(replies[0].value(at: "result.structuredContent.error.code") == .string(code))
            let events = try run.events().events
            #expect(events.map(\.kind) == ["started", "finished"])
            #expect(events.map(\.command) == ["app_logs", "app_logs"])
        }
    }
}
