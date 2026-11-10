//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct DoctorSetupTests {
    let home = URL(filePath: "/Users/dev", directoryHint: .isDirectory)

    func plan(installed: Set<String>) -> [AgentRegistration] {
        AgentRegistration.plan(binary: "/opt/homebrew/bin/deviceloop", home: home, installed: installed)
    }

    @Test func claudeRegistersAtUserScopeWithAbsolutePath() throws {
        let claude = try #require(plan(installed: ["claude"]).first { $0.agent == "claude" })
        #expect(claude.command == ["claude", "mcp", "add", "-s", "user", "deviceloop", "--", "/opt/homebrew/bin/deviceloop", "mcp"])
        #expect(claude.status == "printed")
    }

    @Test func agentsNotFoundAreListedOnOneLine() {
        let expected = [
            "claude: claude mcp add -s user deviceloop -- /opt/homebrew/bin/deviceloop mcp",
            "not installed: codex, cursor, gemini",
        ]
        #expect(AgentRegistration.lines(plan(installed: ["claude"])) == expected)
    }

    @Test func cursorWritesToItsUserConfigFile() throws {
        let cursor = try #require(plan(installed: ["cursor"]).first { $0.agent == "cursor" })
        #expect(cursor.command == nil)
        #expect(cursor.configFile == "/Users/dev/.cursor/mcp.json")
    }

    @Test func cursorMergeKeepsOtherServers() throws {
        let existing = Data(#"{"mcpServers":{"other":{"command":"other-mcp"}},"theme":"dark"}"#.utf8)
        let entry: JSONValue = ["command": "/opt/homebrew/bin/deviceloop", "args": ["mcp"]]
        let merged = try JSONValue(data: AgentRegistration.mergeServer(entry, into: existing, file: "mcp.json"))
        #expect(merged.value(at: "mcpServers.other.command") == "other-mcp")
        #expect(merged.value(at: "mcpServers.deviceloop") == entry)
        #expect(merged["theme"] == "dark")
    }

    @Test func cursorMergeRefusesFileThatIsNotAnObject() {
        #expect(throws: DeviceLoopError.self) {
            try AgentRegistration.mergeServer(["command": "x"], into: Data("[1, 2]".utf8), file: "mcp.json")
        }
    }

    @Test func pathWithSpacesIsQuoted() {
        #expect(AgentRegistration.shellQuoted("/Users/dev/My Tools/deviceloop") == "'/Users/dev/My Tools/deviceloop'")
        #expect(AgentRegistration.shellQuoted("/opt/homebrew/bin/deviceloop") == "/opt/homebrew/bin/deviceloop")
    }

    @Test func storingTeamKeepsOtherKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "deviceloop-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"team":"OLD0000001","runner":"keep"}"#.utf8).write(to: url)

        try DeviceLoopConfig.store(team: "ABCDE12345", at: url)

        #expect(DeviceLoopConfig.team(at: url) == "ABCDE12345")
        #expect(try JSONValue(data: Data(contentsOf: url))["runner"] == "keep")
    }
}
