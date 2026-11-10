//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import Foundation

struct ContainerCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "container",
        abstract: "List the files in an app's data container, pull one to the Mac, or push one into it.",
        discussion: """
            Examples:
              deviceloop container com.example.MyApp --path Documents
              deviceloop container pull com.example.MyApp Documents/f.txt
              deviceloop container push com.example.MyApp seed.json Documents/seed.json
            """,
        subcommands: [List.self, Pull.self, Push.self],
        defaultSubcommand: List.self
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List files and folders in the container, recursively, with paths relative to it.")

        @Argument(help: "Bundle ID.")
        var bundleID: String

        @Option(name: .long, help: "Only this folder of the container, for example Documents.")
        var path: String?

        @OptionGroup var target: TargetOptions

        func run() async throws {
            try await Output.run(target) { try await ContainerCommands.list($0, bundleID: bundleID, path: path) }
        }
    }

    struct Pull: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Copy one file out of the container. Existing files are never replaced.")

        @Argument(help: "Bundle ID.")
        var bundleID: String

        @Argument(help: "Path in the container, for example Documents/f.txt.")
        var path: String

        @Option(name: [.short, .long], help: "Directory for the pulled file.")
        var output: String?

        @OptionGroup var target: TargetOptions

        func run() async throws {
            try await Output.run(target) {
                try await ContainerCommands.pull($0, bundleID: bundleID, path: path, to: output.map { URL(filePath: $0) })
            }
        }
    }

    struct Push: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Copy one file from the Mac into the container while the app is not running. The push is not journaled.")

        @Argument(help: "Bundle ID.")
        var bundleID: String

        @Argument(help: "File on this Mac.")
        var local: String

        @Argument(help: "Path in the container, for example Documents/seed.json.")
        var destination: String

        @Flag(name: .long, help: "Replace a file that is already there.")
        var overwrite = false

        @OptionGroup var target: TargetOptions

        func run() async throws {
            try await Output.run(target) {
                try await ContainerCommands.push(
                    $0, bundleID: bundleID, source: URL(filePath: local), path: destination, overwrite: overwrite)
            }
        }
    }
}
