//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import Testing

@testable import DeviceLoopKit
@testable import deviceloop

@Suite struct MCPCommandMapTests {
    /// The CLI commands each MCP tool runs.
    static let commands: [String: [String]] = [
        "device_list": ["devices"],
        "device_info": ["info"],
        "device_doctor": ["doctor"],
        "device_view": ["view"],
        "screen_capture": ["screenshot"],
        "app_list": ["apps"],
        "app_install": ["install"],
        "app_uninstall": ["uninstall"],
        "app_launch": ["launch"],
        "app_terminate": ["terminate"],
        "url_open": ["open"],
        "device_set": ["location", "appearance", "orientation"],
        "pasteboard": ["pasteboard"],
        "crash_list": ["crashes"],
        "crash_pull": ["crashes"],
        "video_record": ["video start", "video stop"],
        "video_capture": ["video capture"],
        "video_inspect": ["video inspect"],
        "device_lock": ["lock"],
        "system_control": [
            "siri wifi", "siri bluetooth", "siri lowpower", "siri dnd", "siri airplane", "siri brightness", "siri volume",
        ],
        "device_siri": ["siri say"],
        "device_operation": ["runner operation"],
        "ui_tree": ["ui tree"],
        "ui_tap": ["ui tap"],
        "ui_type": ["ui type"],
        "ui_swipe": ["ui swipe"],
        "ui_drag": ["ui drag"],
        "ui_press": ["ui press"],
        "ui_find": ["ui find"],
        "ui_wait": ["ui wait"],
        "ui_alert": ["ui alert"],
        "ui_audit": ["ui audit"],
        "runner_status": ["runner status"],
        "runner_stop": ["runner stop"],
        "device_state": ["state inspect", "state capture", "state diff"],
        "state_restore": ["state restore"],
        "state_scope": ["state scope start", "state scope status"],
        "device_prepare": ["prepare"],
        "test_run": ["test run"],
        "test_status": ["test results"],
        "test_cancel": [],
        "app_logs": ["logs start", "logs read", "logs stop"],
        "app_files": ["container list", "container pull", "container push"],
        "flow_validate": ["flow validate"],
        "flow_run": ["flow run"],
        "flow_status": [],
        "flow_cancel": [],
        "flow_export": ["flow export"],
        "trace_record": ["trace record"],
        "run": ["run start", "run stop", "run status", "run show", "run report", "run list", "run compare", "run export"],
    ]

    /// CLI commands with no MCP tool.
    static let cliOnly: Set<String> = [
        "setup", "mcp", "capture-helper", "ui do", "video record", "runner start", "keep-awake", "siri test", "perf launch",
        "perf run", "perf compare", "run prune",
    ]

    /// Leaf command paths below `deviceloop`, for example `ui tap`.
    func leafCommands(_ command: any ParsableCommand.Type, path: [String] = []) -> [String] {
        let subcommands = command.configuration.subcommands
        guard !subcommands.isEmpty else { return [path.joined(separator: " ")] }
        return subcommands.flatMap { leafCommands($0, path: path + [$0._commandName]) }
    }

    @Test func everyMCPToolMapsToACLICommand() {
        let leaves = Set(leafCommands(DeviceLoopCLI.self))
        #expect(Set(Self.commands.keys) == Set(MCPTools.all.map(\.name)))
        for (tool, commands) in Self.commands {
            for command in commands {
                #expect(leaves.contains(command), "\(tool) maps to \(command), which the CLI does not have")
            }
        }
    }

    @Test func everyCLICommandHasAnMCPToolOrIsListedAsCLIOnly() {
        let mapped = Set(Self.commands.values.joined())
        #expect(Set(leafCommands(DeviceLoopCLI.self)).subtracting(mapped) == Self.cliOnly)
    }
}
