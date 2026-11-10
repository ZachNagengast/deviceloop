//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

extension MCPTools {
    static let trace: [MCPTool] = [
        .device(
            name: "trace_record",
            title: "Record Instruments trace",
            description: """
                Record an Instruments trace of one running app with xctrace, attached to its pid on the device, \
                then write the trace's table of contents and a deviceloop.trace/1 summary with hitches and potential hangs \
                next to the raw .trace, which is kept. Recording stops after duration_ms, at most 60000. \
                It needs about 0.5 GB of free disk per second plus 1 GB. Animation Hitches is not supported on simulators, \
                and a target where xctrace cannot attach fails with unsupported_on_target.
                """,
            properties: [
                "app": Param.string("Bundle ID of the running app."),
                "template": Param.string("Template name from `xcrun xctrace list templates`. Defaults to Time Profiler."),
                "duration_ms": [
                    "type": "integer", "description": "Stop recording after this many milliseconds.",
                    "default": .number(Double(TraceCommands.defaultLimitMs)), "minimum": 1,
                    "maximum": .number(Double(TraceCommands.maxLimitMs)),
                ],
            ],
            required: ["app"],
            readOnly: false
        ) { target, arguments in
            try await TraceCommands.record(
                target, app: arguments.require("app"), template: arguments.string("template"), durationMs: arguments.int("duration_ms"),
                output: nil)
        }
    ]
}
