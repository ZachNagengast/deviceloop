//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

extension MCPTools {
    static let stateTools: [MCPTool] = [
        MCPTool(
            name: "device_state",
            title: "Device state",
            description: """
                Read the identity and settings of a device or simulator, each field marked observed, unknown, unsupported or \
                unavailable with a reason. `inspect` returns them, `capture` also saves them to a file, `diff` compares a capture \
                with another capture or with the live state. A diff marks a field unknown unless both sides observed it.
                """,
            properties: [
                "action": Param.string("What to do.", oneOf: ["inspect", "capture", "diff"]),
                "device": Param.string(
                    "A UDID, a name or a unique part of it, `booted`, `usb` or `device`. For `diff`, defaults to the captured target."),
                "output": Param.string("File for `capture`. Defaults to the DeviceLoop state folder."),
                "before": Param.string("Capture file for `diff`."),
                "after": Param.string("Second capture file for `diff`. Omit to compare with the live state."),
            ],
            required: ["action"],
            readOnly: false
        ) { arguments in
            switch try arguments.require("action") {
                case "inspect":
                    return try await StateCommands.inspect(arguments.target())
                case "capture":
                    let output = try arguments.string("output").map(MCPArguments.fileURL)
                    return try await StateCommands.capture(arguments.target(), output: output)
                case "diff":
                    let before = MCPArguments.fileURL(try arguments.require("before"))
                    if let after = try arguments.string("after") {
                        return try StateCommands.diff(before, MCPArguments.fileURL(after))
                    }
                    return try await StateCommands.diff(before, live: arguments.string("device"))
                case let action:
                    throw DeviceLoopError(.badArguments, "device_state action must be inspect, capture or diff, got \(action).")
            }
        },
        .device(
            name: "state_scope",
            title: "State scope",
            description: """
                Journal the setting changes DeviceLoop makes on a device or simulator. `start` captures a baseline, and device_set, \
                system_control and pasteboard copy then journal each change, with its original value when DeviceLoop can read it, \
                until state_restore closes the scope. `status` reports whether a scope is open and each change journaled in it.
                """,
            properties: [
                "action": Param.string("What to do.", oneOf: ["start", "status"]),
                "strict": Param.boolean(
                    "For `start`, refuse changes DeviceLoop cannot set back: location, system_control and pasteboard copy."),
            ],
            required: ["action"],
            readOnly: false
        ) { target, arguments in
            switch try arguments.require("action") {
                case "start": return try await StateCommands.scopeStart(target, strict: arguments.bool("strict") ?? false)
                case "status": return try StateCommands.scopeStatus(target)
                case let action: throw DeviceLoopError(.badArguments, "state_scope action must be start or status, got \(action).")
            }
        },
        .device(
            name: "state_restore",
            title: "Restore device state",
            description: """
                Set back the appearance and orientation changes journaled in the open state_scope of a device or \
                simulator, newest first, and close the scope. A field that changed since DeviceLoop set it is a conflict and \
                stays as it is. Location, system_control and pasteboard copy are unsupported. Fails with cleanup_incomplete, \
                keeping the scope open, unless every change is restored, unchanged or cleared, or dry_run or accept_residual is set.
                """,
            properties: [
                "dry_run": Param.boolean("Report what restore would do without setting anything."),
                "overwrite_conflicts": Param.boolean("Set conflicting fields back anyway."),
                "accept_residual": Param.boolean("Close the scope even when changes are left in place."),
                "clear_location": Param.boolean(
                    "Clear the simulated location. The location before the scope cannot be read, so it is lost."),
            ],
            readOnly: false,
            destructive: true
        ) { target, arguments in
            try await StateCommands.restore(
                target, dryRun: arguments.bool("dry_run") ?? false, overwriteConflicts: arguments.bool("overwrite_conflicts") ?? false,
                acceptResidual: arguments.bool("accept_residual") ?? false, clearLocation: arguments.bool("clear_location") ?? false)
        },
    ]
}
