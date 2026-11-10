//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

extension MCPTools {
    static let prepareTools: [MCPTool] = [
        MCPTool(
            name: "device_prepare",
            title: "Prepare device",
            description: """
                Get a device ready for UI commands. Plans the steps device_doctor shows are missing, waits up to `wait` seconds \
                for each owner step (pair, developerMode, unlock), then mounts the developer disk image, stores the signing team, \
                starts the UI runner and re-runs doctor. Steps after one that is not done are blocked. Relay a needsOwner step \
                to the person at the device, then call again with a wait. Starting the runner may ask for the device passcode.
                """,
            properties: [
                "device": Param.device,
                "all": Param.boolean("Prepare every device and booted simulator."),
                "dry_run": Param.boolean("Return the plan and owner steps and run nothing."),
                "wait": Param.integer("Seconds to wait for each owner step, 0 to 120.", default: 0),
            ],
            readOnly: false
        ) { arguments in
            let wait = try arguments.int("wait") ?? 0
            guard (0 ... 120).contains(wait) else {
                throw DeviceLoopError(.badArguments, "device_prepare wait must be 0 to 120 seconds, got \(wait).")
            }
            let targets = try await PrepareCommands.targets(device: arguments.string("device"), all: arguments.bool("all") ?? false)
            return try await PrepareCommands.prepare(targets, dryRun: arguments.bool("dry_run") ?? false, wait: wait) {
                MCPServer.log($0)
            }
        }
    ]
}
