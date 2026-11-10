//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

extension MCPTools {
    static let logs: [MCPTool] = [
        MCPTool(
            name: "app_logs",
            title: "Capture app logs",
            description: """
                Capture an app's stdout, stderr and os_log in the background while other tools drive it. `start` relaunches \
                the app with optional arguments and environment and returns a handle. `read` returns captured lines. `stop` \
                terminates the app, finishes the log file and reports how the app exited. When the app crashed, `read` and \
                `stop` wait up to \(Int(CrashCommands.reportWait)) s after the crash for its report and fail with app_crashed \
                naming it for `crash_pull`. On a simulator, `start` with `system` streams the unified log as ndjson instead, \
                which also covers apps launched any other way.
                """,
            properties: [
                "action": Param.string("`start`, `read` or `stop`.", oneOf: ["start", "read", "stop"]),
                "bundle_id": Param.string("Bundle ID of the app, required for `start` without `system`."),
                "system": Param.boolean("`start` streams the simulator's unified log with `log stream` instead of one app's console."),
                "predicate": Param.string("`log stream` predicate for `start` with `system`, for example `process == \"MyApp\"`."),
                "arguments": Param.strings("Launch arguments for `start`."),
                "env": Param.keyValues("Environment variables for `start`."),
                "handle": Param.string("Handle returned by `start`, required for `read` and `stop`."),
                "tail": Param.integer("`read` returns at most this many of the last lines.", default: 200),
                "grep": Param.string("`read` returns only lines that contain this text."),
                "device": Param.device,
            ],
            required: ["action"],
            readOnly: false
        ) { arguments in
            switch try arguments.require("action") {
                case "start" where try arguments.bool("system") == true:
                    guard try arguments.string("bundle_id") == nil, try arguments.strings("arguments")?.isEmpty != false,
                        try arguments.environment("env").isEmpty
                    else {
                        throw DeviceLoopError(.badArguments, "app_logs start with system takes no bundle_id, arguments or env.")
                    }
                    let target = try await arguments.target()
                    return try await arguments.record(target.udid) {
                        try await LogCommands.startSystem(target, predicate: arguments.string("predicate"))
                    }
                case "start":
                    guard try arguments.string("predicate") == nil else {
                        throw DeviceLoopError(.badArguments, "app_logs predicate needs system.")
                    }
                    let target = try await arguments.target()
                    return try await arguments.record(target.udid) {
                        try await LogCommands.start(
                            target,
                            bundleID: arguments.require("bundle_id"),
                            arguments: arguments.strings("arguments") ?? [],
                            environment: arguments.environment("env")
                        )
                    }
                case "read":
                    return try await LogCommands.read(
                        handle: arguments.require("handle"), tail: arguments.int("tail") ?? 200, grep: arguments.string("grep"))
                case "stop": return try await LogCommands.stop(handle: arguments.require("handle"))
                case let action: throw DeviceLoopError(.badArguments, "app_logs action must be start, read or stop, got \(action).")
            }
        }
    ]
}
