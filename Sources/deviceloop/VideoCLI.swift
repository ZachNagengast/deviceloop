//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import Foundation

/// Hidden entry point that DeviceLoopCapture.app runs to record a device screen over USB.
struct CaptureHelperCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture-helper",
        abstract: "Internal: USB screen capture process.",
        shouldDisplay: false
    )

    @Argument(parsing: .captureForPassthrough)
    var arguments: [String] = []

    func run() async throws {
        try await CaptureHelper.main(arguments)
    }
}

struct VideoCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "video",
        abstract: "Record the screen and analyze animations.",
        subcommands: [Record.self, Start.self, Stop.self, Capture.self, Inspect.self]
    )

    struct Record: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Record the screen until Ctrl-C, or for --duration-ms.")

        @Option(name: [.short, .long], help: "Where to save the video.")
        var output: String?

        @Option(name: .long, help: "Stop after this many milliseconds.")
        var durationMs: Int?

        @OptionGroup var target: TargetOptions

        func run() async throws {
            try await Output.run(target) {
                try await VideoCommands.record($0, output: output.map { URL(filePath: $0) }, durationMs: durationMs)
            }
        }
    }

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start recording in the background and print a handle for `video stop`.")

        @OptionGroup var target: TargetOptions

        func run() async throws {
            try await Output.run(target) { try await VideoCommands.startRecording($0) }
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop a recording started with `video start` and analyze it.")

        @Argument(help: "Handle printed by `video start`.")
        var handle: String

        @Flag(name: .long, help: "Only finish the file, skip the analysis.")
        var noAnalyze = false

        @OptionGroup var areas: AreaOptions
        @OptionGroup var output: OutputOptions

        func run() async throws {
            try await Output.emit(json: output.json) {
                let region = try areas.parsedRegion()
                let masks = try areas.parsedMasks()
                return try await Output.record(VideoCommands.recordingDevice(handle)) {
                    try await VideoCommands.stopRecording(handle: handle, analyze: !noAnalyze, region: region, masks: masks)
                }
            }
        }
    }

    struct Capture: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Record around one action and report how the screen moved.",
            discussion: """
                With --instruments on a device, an Animation Hitches trace of --app starts first, the USB capture after it, \
                and each gap candidate is checked against the trace's displayed-surface gaps. Tracing needs about 0.5 GB of \
                free disk per second of --pre-ms, --wait-ms and a 10 s margin, plus 1 GB.
                Example: deviceloop video capture --do 'tap "Wi-Fi"'
                """
        )

        @Option(name: .customLong("do"), help: "The step to run, same grammar as `deviceloop ui do`.")
        var step: String

        @Option(name: .long, help: "Record this long before the step.")
        var preMs = 300

        @Option(name: .long, help: "Keep recording this long after the step.")
        var waitMs = 1500

        @Flag(name: .long, help: "Keep the raw video next to the contact sheet. A failed capture always keeps it.")
        var keepVideo = false

        @Flag(name: .long, help: "Record an Animation Hitches trace of --app around the capture. Devices only.")
        var instruments = false

        @Flag(name: .long, help: "Keep the --instruments trace and its table of contents.")
        var keepTrace = false

        @OptionGroup var areas: AreaOptions
        @OptionGroup var app: AppOption
        @OptionGroup var target: TargetOptions

        func run() async throws {
            let parsed = try UIStep.parse(step)
            try await Output.run(target, hiding: parsed.typedText.map { [step, $0] } ?? []) {
                try await VideoCommands.capture(
                    $0, step: parsed, app: app.app, preMs: preMs, waitMs: waitMs, keepVideo: keepVideo,
                    region: try areas.parsedRegion(), masks: try areas.parsedMasks(), instruments: instruments, keepTrace: keepTrace)
            }
        }
    }

    struct Inspect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Analyze any screen recording: motion, last change, gap candidates.")

        @Argument(help: "MP4 or MOV file.")
        var file: String

        @Flag(name: .long, help: "Skip the contact sheet image.")
        var noSheet = false

        @OptionGroup var areas: AreaOptions
        @OptionGroup var output: OutputOptions

        func run() async throws {
            try await Output.emit(json: output.json) {
                try await VideoCommands.inspect(
                    URL(filePath: file), sheet: !noSheet, region: try areas.parsedRegion(), masks: try areas.parsedMasks())
            }
        }
    }
}

struct AreaOptions: ParsableArguments {
    @Option(name: .long, help: "Analyze only x,y,w,h in source pixels, widened to whole analysis tiles.")
    var region: String?

    @Option(
        name: .long,
        help: "Ignore x,y,w,h in source pixels, widened to whole analysis tiles, for example a spinner or a clock. Repeatable.")
    var mask: [String] = []

    func parsedRegion() throws -> CGRect? { try region.map(VideoCommands.area) }

    func parsedMasks() throws -> [CGRect] { try mask.map(VideoCommands.area) }
}
