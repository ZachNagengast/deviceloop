//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct MCPRunToolTests {
    /// Calls the `run` tool with `arguments`, logging to a new temporary file, and returns the text of the result.
    func runText(_ arguments: JSONValue) async throws -> String {
        let folder = FileManager.default.temporaryDirectory.appending(path: "deviceloop-run-tool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = try #require(MCPTools.runs.first { $0.name == "run" })
        let reply = await tool.call(arguments, log: folder.appending(path: "mcp.log"))
        return reply["content"]?[0]?["text"]?.string ?? ""
    }

    @Test func everyToolArgumentIsSnakeCase() {
        for tool in MCPTools.all {
            for name in tool.properties.keys {
                #expect(name.wholeMatch(of: /[a-z][a-z0-9]*(_[a-z0-9]+)*/) != nil, "\(tool.name) argument \(name)")
            }
        }
    }

    @Test(
        arguments: [
            ("screenshot_masks", ["0,0,430"], "mask takes x,y,w,h"),
            ("max_diff", 200, "max-diff is a percent"),
            ("min_ms", -1, "min-ms is milliseconds"),
        ] as [(String, JSONValue, String)])
    func compareRejectsAnInvalidArgument(name: String, value: JSONValue, message: String) async throws {
        let text = try await runText(["action": "compare", "baseline": "run-a", "candidate": "run-b", name: value])
        #expect(text.hasPrefix("ERROR bad_arguments: \(message)"))
    }

    @Test func exportRefusesAnOutputFolderThatExists() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "deviceloop-run-export-\(UUID().uuidString)")
        try Paths.ensureDirectory(folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let text = try await runText([
            "action": "export", "id": "run-a", "output": .string(folder.path), "media": false, "keep_typed_text": true,
        ])
        #expect(text.hasPrefix("ERROR bad_arguments: \(folder.path) already exists."))
    }
}
