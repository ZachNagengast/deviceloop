//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import Foundation

struct PrepareCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare",
        abstract: "Get a device ready for UI commands: owner steps, disk image, signing team and runner, then doctor.",
        discussion: """
            Plans the steps doctor shows are missing. Owner steps (pair, Developer Mode, unlock) print what to do on the device \
            and wait up to --wait seconds each. With --pair, a device that is not paired is asked to pair with `devicectl manage \
            pair` before the pair step waits. Tool steps mount the developer disk image, store the signing team and start the UI \
            runner, which may ask for the device passcode. When that prompt times out, the runner starts again until \
            --wait-for-owner runs out. A live runner is reused. Steps after one that is not done are blocked. With --all the \
            targets run at the same time. Exits 1 when a target is not ready.
            """
    )

    @Flag(name: .long, help: "Prepare every device and booted simulator.")
    var all = false

    @Flag(name: .long, help: "Print the plan and owner steps and run nothing.")
    var dryRun = false

    @Flag(name: .long, help: "Run devicectl manage pair on a device that is not paired, then wait for Trust.")
    var pair = false

    @Option(name: .long, help: "Seconds to wait for each owner step.")
    var wait = 300

    @Option(name: .long, help: "Seconds to keep restarting the UI runner after its passcode prompt times out.")
    var waitForOwner = 180

    @OptionGroup var target: TargetOptions

    func run() async throws {
        try await Output.emit(json: target.json, exitCode: Output.failedExitCode) {
            guard wait >= 0 else { throw DeviceLoopError.usage("--wait must be 0 or more seconds.") }
            guard waitForOwner >= 0 else { throw DeviceLoopError.usage("--wait-for-owner must be 0 or more seconds.") }
            let targets = try await PrepareCommands.targets(device: target.device, all: all)
            return try await PrepareCommands.prepare(targets, dryRun: dryRun, wait: wait, ownerWait: waitForOwner, pair: pair) { line in
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
        }
    }
}
