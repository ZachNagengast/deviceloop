//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

extension MCPTools {
    static let container: [MCPTool] = [
        .device(
            name: "app_files",
            title: "App container files",
            description: """
                Files in an app's data container. `list` returns every file and folder, recursively, with paths relative to \
                the container. `pull` copies one file to the DeviceLoop artifacts folder and returns its path and sha256, and \
                never replaces a file already there. `push` copies one file from this Mac into the container while the app is \
                not running, and replaces an existing file only with `overwrite`. state_scope does not journal pushes, so \
                state_restore cannot undo them. On a device the app must be a development-signed build.
                """,
            properties: [
                "action": Param.string("`list`, `pull` or `push`.", oneOf: ["list", "pull", "push"]),
                "bundle_id": Param.string("Bundle ID of the app, for example com.example.app."),
                "path": Param.string(
                    "Path in the container, for example Documents/f.txt. A folder for `list`, required for `pull` and `push`."),
                "local": Param.string("File on this Mac to push, required for `push`."),
                "overwrite": Param.boolean("`push` replaces a file that is already there."),
            ],
            required: ["action", "bundle_id"],
            readOnly: false,
            destructive: true
        ) { target, arguments in
            let bundleID = try arguments.require("bundle_id")
            switch try arguments.require("action") {
                case "list":
                    return try await ContainerCommands.list(target, bundleID: bundleID, path: arguments.string("path"))
                case "pull":
                    return try await ContainerCommands.pull(target, bundleID: bundleID, path: arguments.require("path"), to: nil)
                case "push":
                    return try await ContainerCommands.push(
                        target, bundleID: bundleID, source: MCPArguments.fileURL(arguments.require("local")),
                        path: arguments.require("path"), overwrite: arguments.bool("overwrite") ?? false)
                case let action: throw DeviceLoopError(.badArguments, "app_files action must be list, pull or push, got \(action).")
            }
        }
    ]
}
