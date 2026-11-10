//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

extension MCPTools {
    static let runs: [MCPTool] = [
        MCPTool(
            name: "run",
            title: "Record a run",
            description: """
                Record the tool calls on a device into a run folder: a manifest with provenance, an event journal, each result \
                and its files. `start` begins recording, `status` reports the active run, `stop` finishes it and returns the \
                report with the outcome and the path of report.html, `show` reports any run by `id`, `report` renders its \
                report.html again, `list` lists every run newest first, `compare` compares run `baseline` with run `candidate` \
                step by step and writes comparison.json and comparison.html. A comparison is inconclusive when the product type, \
                OS build, screen, orientation, app or command sequence differ. Steps where both runs saved a UI tree also list \
                added, removed and ambiguous elements, and label, value, enabled and frame changes. Steps where both saved a \
                screenshot list the changed pixels outside `screenshot_masks` and write a diff image. Steps where both saved a video \
                analysis compare latency, animation, last change and visual gap times as visual estimates from one uncalibrated \
                capture each: changed or within detection floor, never regressed. `export` copies run `id`, or comparison \
                `comparison` and its two runs, into the new folder `output` for a bug report: device names, UDIDs, teams, tokens \
                and the home path become aliases, typed text and pasteboard contents are hidden, and EXPORT.txt lists the \
                SHA256 of every file. Screenshots, videos and UI text are copied as recorded, so review them before sharing.
                """,
            properties: [
                "action": Param.string("What to do.", oneOf: ["start", "stop", "status", "show", "report", "list", "compare", "export"]),
                "name": Param.string("A name for the run, for `start`."),
                "app": Param.string("Bundle ID of the app under test, for `start`. Records its version and build."),
                "source": Param.string("Path to the git checkout of the app, for `start`. Records its commit and whether it has changes."),
                "id": Param.string("Run ID for `show`, `report` and `export`, for example run-20261108-131927-3f9a2c."),
                "baseline": Param.string("Baseline run ID for `compare`."),
                "candidate": Param.string("Candidate run ID for `compare`."),
                "ignore": Param.strings(
                    "`id=<accessibility id>` values for `compare`, left out of the tree differences with what they contain."),
                "screenshot_masks": Param.strings(
                    "`x,y,w,h` rectangles in points for `compare`, left out of the screenshot differences."),
                "max_diff": Param.number(
                    "Percent of unmasked pixels for `compare`. A screenshot changed when more of them changed.", default: 0.1),
                "min_ms": Param.integer(
                    "Milliseconds for `compare`. A timing changed when it differs by more, or by twice the frame slot when larger.",
                    default: 50),
                "comparison": Param.string("Comparison ID for `export`, instead of `id`, for example cmp-20261108-144911-6ff929."),
                "output": Param.string("Path of the folder `export` writes. It must not exist yet."),
                "media": Param.boolean("Include screenshots, videos and other images in `export`.", default: true),
                "keep_typed_text": Param.boolean("Keep typed text and pasteboard contents in `export`."),
                "zip": Param.boolean("Also write `<output>.zip` with ditto, for `export`."),
                "device": Param.device,
            ],
            required: ["action"],
            readOnly: false
        ) { arguments in
            switch try arguments.require("action") {
                case "start":
                    return try await RunCommands.start(
                        arguments.target(), name: arguments.string("name"), app: arguments.string("app"),
                        source: arguments.string("source").map(MCPArguments.fileURL), version: arguments.serverVersion, owned: true)
                case "stop": return try await RunCommands.stop(arguments.target())
                case "status": return try await RunCommands.status(arguments.target())
                case "show": return try RunCommands.show(arguments.require("id"))
                case "report": return try RunCommands.renderReport(arguments.require("id"))
                case "list": return try RunCommands.list()
                case "compare":
                    return try RunCommands.compare(
                        arguments.require("baseline"), arguments.require("candidate"), ignore: arguments.strings("ignore") ?? [],
                        mask: arguments.strings("screenshot_masks") ?? [], maxDiff: arguments.number("max_diff") ?? 0.1,
                        minMs: Double(arguments.int("min_ms") ?? 50))
                case "export":
                    return try await RunCommands.export(
                        arguments.string("id"), comparison: arguments.string("comparison"),
                        to: MCPArguments.fileURL(arguments.require("output")), media: arguments.bool("media") ?? true,
                        keepTypedText: arguments.bool("keep_typed_text") ?? false, zip: arguments.bool("zip") ?? false)
                case let action:
                    throw DeviceLoopError(
                        .badArguments, "run action must be start, stop, status, show, report, list, compare or export, got \(action).")
            }
        }
    ]
}
