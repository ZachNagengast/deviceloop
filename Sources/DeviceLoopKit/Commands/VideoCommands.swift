//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import AVFoundation
import DeviceLoopProtocol
import Foundation

/// Screen recordings and their analysis. Devices record over USB with AVFoundation through the capture helper app,
/// simulators with `simctl io recordVideo`.
public enum VideoCommands {
    /// Records until `durationMs` passes, or until the process gets SIGINT when it is nil.
    public static func record(_ target: Target, output: URL?, durationMs: Int?) async throws -> CommandResult {
        let interrupt = InterruptFlag()
        defer { interrupt.remove() }
        let handle = try await Recorder.start(target, video: try output ?? Paths.newArtifact("video", extension: "mp4"))
        _ = await interrupt.sleep(seconds: durationMs.map { Double($0) / 1000 })
        return try await summary(try await stop(handle))
    }

    /// Starts a background recording and returns a handle id for `stopRecording`.
    public static func startRecording(_ target: Target) async throws -> CommandResult {
        let video = try Paths.newArtifact("video", extension: "mp4")
        let handle = try await Recorder.start(target, video: video)
        return CommandResult(
            text: "\(target.summary)\nrecording \(handle.id) to \(video.path)\nstop with: deviceloop video stop \(handle.id)",
            json: ["handle": .string(handle.id), "video": .string(video.path), "device": .string(target.udid)]
        )
    }

    /// The UDID of the target recording `handle`, or nil for an unknown handle.
    public static func recordingDevice(_ handle: String) -> String? {
        try? Recorder.load(handle).udid
    }

    /// Stops the recording `handle` names, then analyzes the video with `analyze`, or summarizes it.
    public static func stopRecording(
        handle: String, analyze: Bool, region: CGRect? = nil, masks: [CGRect] = []
    ) async throws -> CommandResult {
        let stopped = try await stop(try Recorder.load(handle))
        guard analyze else { return try await summary(stopped) }
        var options = options(for: stopped)
        options.region = region
        options.masks = masks
        return try await analyzed(stopped.video, header: stopped.handle.summary, options: options, keepVideo: true)
    }

    /// Trace time beyond `preMs` and `waitMs` for the USB capture to start and stop and for the step to run.
    static let traceMarginMs = 10_000

    /// Records, waits `preMs`, runs `step`, waits `waitMs`, stops and analyzes.
    /// Returns timing, motion segments, visual gap candidates and one contact-sheet image.
    /// With `instruments`, records an Animation Hitches trace of `app` around the capture and checks each candidate against it.
    public static func capture(
        _ target: Target,
        step: UIStep,
        app: String?,
        preMs: Int,
        waitMs: Int,
        keepVideo: Bool,
        region: CGRect? = nil,
        masks: [CGRect] = [],
        instruments: Bool = false,
        keepTrace: Bool = false
    ) async throws -> CommandResult {
        try step.validate()
        let limitMs = instruments ? try traceLimitMs(target, app: app, preMs: preMs, waitMs: waitMs) : nil
        try await Recorder.preflight(target)
        // Connects before recording so runner startup stays out of the action window.
        let runner = try await needsRunner(step) ? UICommands.connect(target, focusing: app) : nil
        var recorded: (stopped: StoppedRecording, sentAt: Double, ackAt: Double, reconnect: AnimationReport.Reconnect?)?
        var trace: TraceMatch?
        if let limitMs, let app {
            let (pid, names) = try await TraceCommands.attachment(target, app: app)
            do {
                let exported = try await traced(target, app: app, pid: pid, names: names, limitMs: limitMs, keepTrace: keepTrace) {
                    recorded = try await recordStep(step, on: target, app: app, runner: runner, preMs: preMs, waitMs: waitMs)
                }
                guard let videoStart = recorded?.stopped.handle.startedAt,
                    let clockOffset = exported.toc.clockOffset(wall: Date(), host: hostNow(), videoStartHost: videoStart)
                else {
                    throw DeviceLoopError(
                        .deviceError, "The trace's table of contents has no start date to place it on the video.",
                        fix: "Retry, or pass --keep-trace and open the trace in Instruments.", device: target.name)
                }
                trace = TraceMatch(
                    swaps: exported.tables["displayed-surfaces-interval"].flatMap { SurfaceSwaps($0) }, clockOffset: clockOffset,
                    hitches: exported.summary.hitches, file: keepTrace ? exported.summary.trace : nil)
            } catch {
                guard let video = recorded?.stopped.video else { throw error }
                throw keeping(video, failure: error)
            }
        } else {
            recorded = try await recordStep(step, on: target, app: app, runner: runner, preMs: preMs, waitMs: waitMs)
        }
        guard let (stopped, sentAt, ackAt, reconnect) = recorded else {
            throw DeviceLoopError(.internalError, "xctrace stopped before the capture ran.")
        }

        var options = options(for: stopped)
        options.actionAt = sentAt - stopped.handle.startedAt
        options.region = region
        options.masks = masks
        let action = AnimationReport.Action(
            step: describe(step),
            status: "ran",
            sentAt: VideoAnalyzer.seconds(sentAt - stopped.handle.startedAt),
            ackAt: VideoAnalyzer.seconds(ackAt - stopped.handle.startedAt),
            windowMs: VideoAnalyzer.ms(ackAt - sentAt),
            note: runner == nil ? nil : "XCTest idle waits fall inside the window",
            reconnect: reconnect
        )
        return try await analyzed(
            stopped.video, header: target.summary, options: options, action: action, trace: trace, keepVideo: keepVideo)
    }

    /// Records, waits `preMs`, runs `step` and waits `waitMs`. Returns the recording, the host times of send and ack, and
    /// the tunnel move seen after recording started. A failed step keeps the video and names it. The caller runs
    /// `Recorder.preflight` first.
    static func recordStep(
        _ step: UIStep, on target: Target, app: String?, runner: RunnerSession?, preMs: Int, waitMs: Int
    ) async throws -> (stopped: StoppedRecording, sentAt: Double, ackAt: Double, reconnect: AnimationReport.Reconnect?) {
        let interrupt = InterruptFlag()
        defer { interrupt.remove() }
        let handle = try await Recorder.start(target, video: try Paths.newArtifact("capture", extension: "mp4"), preflighted: true)
        var sentAt = 0.0
        var ackAt = 0.0
        var reconnect: AnimationReport.Reconnect?
        var failure: (any Error)?
        do {
            var current = (target: target, reconnect: AnimationReport.Reconnect?.none)
            var session = runner
            if let runner, !target.isSimulator, await runnerDropped(runner, within: captureWatch) {
                current = try await reconnected(target, for: step, startedAt: handle.startedAt, timeout: .seconds(20), newAddress: true)
                // The runner does not answer at the new address, so connecting replaces it before the action window.
                let replaced = try await UICommands.connect(current.target, focusing: app)
                // A new runner attaches to the app on its first query, which would otherwise fall inside the window.
                _ = try? await replaced.client.post(RunnerWire.Path.tree, TreeRequest(app: app), as: TreeResult.self, timeout: 15)
                session = replaced
            }
            reconnect = current.reconnect
            if await interrupt.sleep(seconds: Double(preMs) / 1000) { throw CancellationError() }
            sentAt = hostNow()
            try await perform(step, on: current.target, app: app, runner: session)
            ackAt = hostNow()
            if await interrupt.sleep(seconds: Double(waitMs) / 1000) { throw CancellationError() }
        } catch {
            failure = error
        }
        let stopped = try await stop(handle)
        if let failure { throw keeping(stopped.video, failure: failure) }
        return (stopped, sentAt, ackAt, reconnect)
    }

    /// `failure` with `video kept at` in its detail, or on stderr for a cancellation, which has no detail.
    static func keeping(_ video: URL, failure: any Error) -> any Error {
        let kept = "video kept at \(video.path)"
        if failure is CancellationError { FileHandle.standardError.write(Data((kept + "\n").utf8)) }
        return DeviceLoopError.adding(detail: kept, to: failure)
    }

    /// Stops `handle` and waits for its device in a new task, which this task's cancellation does not reach.
    static func stop(
        _ handle: RecordingHandle, list: @escaping @Sendable () async throws -> [Target] = Devicectl.listTargets
    ) async throws -> StoppedRecording {
        try await Task {
            let stopped = try await Recorder.stop(handle)
            await waitForDevice(after: stopped, list: list)
            return stopped
        }.value
    }

    /// Waits up to `timeout` for a device to list as ready on USB again after its USB capture stopped. Stopping a capture
    /// can disconnect a device for a few seconds, or list it on the local network.
    static func waitForDevice(
        after stopped: StoppedRecording, timeout: Duration = .seconds(10), list: () async throws -> [Target] = Devicectl.listTargets
    ) async {
        guard !stopped.handle.simulator else { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let target = try? await list().first(where: { $0.udid == stopped.handle.udid }), target.isReady,
                target.transport == "wired"
            {
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// How long a device runner must keep answering after USB capture starts. A capture can move the device tunnel, and
    /// a runner it cuts off stops answering within about 2 s.
    static let captureWatch: Duration = .seconds(3)

    /// True when `runner` stops answering its health check within `window`.
    static func runnerDropped(_ runner: RunnerSession, within window: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: window)
        while clock.now < deadline {
            if (try? await runner.client.get(RunnerWire.Path.health, as: HealthResult.self, timeout: 1)) == nil { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// Re-reads a device after capture starts, since USB capture can give a wired device a new tunnel address.
    /// Simulators and steps that do not use the runner keep `target`. With `newAddress`, waits until the address changes.
    static func reconnected(
        _ target: Target,
        for step: UIStep,
        startedAt: Double,
        timeout: Duration = .seconds(10),
        newAddress: Bool = false,
        list: () async throws -> [Target] = Devicectl.listTargets
    ) async throws -> (target: Target, reconnect: AnimationReport.Reconnect?) {
        guard needsRunner(step), !target.isSimulator else { return (target, nil) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if let current = try? await list().first(where: { $0.udid == target.udid }), current.isReady,
                let address = current.tunnelAddress
            {
                if address != target.tunnelAddress {
                    let seen = VideoAnalyzer.seconds(hostNow() - startedAt)
                    return (current, AnimationReport.Reconnect(from: target.tunnelAddress, to: address, at: seen))
                }
                if !newAddress { return (current, nil) }
            }
            guard clock.now < deadline else {
                throw DeviceLoopError(
                    .deviceOffline,
                    "\(target.name) did not reconnect within \(timeout.components.seconds) s after capture started.",
                    fix: "Check the cable and unlock \(target.name), then run the capture again.", device: target.name
                )
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// The trace time limit for `--instruments`. Throws on simulators, without `app`, and over 60 s.
    static func traceLimitMs(_ target: Target, app: String?, preMs: Int, waitMs: Int) throws -> Int {
        guard !target.isSimulator else {
            throw DeviceLoopError.unsupported(
                "Animation Hitches tracing", on: target, alternatives: ["Use an iPhone or iPad over USB", "Drop --instruments"])
        }
        guard app != nil else {
            throw DeviceLoopError(
                .badArguments, "--instruments needs --app, the bundle ID of the app to trace.",
                fix: "For example: --instruments --app com.example.app")
        }
        let limitMs = preMs + waitMs + traceMarginMs
        guard limitMs <= TraceCommands.maxLimitMs else {
            throw DeviceLoopError(
                .badArguments,
                "--instruments traces at most \(TraceCommands.maxLimitMs) ms, "
                    + "and --pre-ms plus --wait-ms plus \(traceMarginMs) ms is \(limitMs) ms.",
                fix: "Pass a shorter --wait-ms.")
        }
        return limitMs
    }

    /// Records an Animation Hitches trace of `pid` around `body`, which runs once tracing has started, and exports it.
    /// Deletes the trace and its TOC unless `keepTrace` or the export fails, which keeps them and names the trace.
    static func traced(
        _ target: Target, app: String, pid: Int32, names: [String], limitMs: Int, keepTrace: Bool,
        xctrace: [String] = ["xcrun", "xctrace"], body: @escaping () async throws -> Void
    ) async throws -> (summary: TraceSummary, toc: TraceTOC, tables: [String: TraceTable]) {
        let trace = try Paths.newArtifact("trace", extension: "trace")
        var kept = keepTrace
        defer {
            if !kept {
                try? FileManager.default.removeItem(at: trace)
                try? FileManager.default.removeItem(at: TraceCommands.sibling(trace, "toc.xml"))
            }
        }
        _ = try await TraceCommands.run(
            target, app: app, pid: pid, template: TraceSummary.hitchesTemplate, limitMs: limitMs, output: trace, xctrace: xctrace,
            during: body)
        do {
            return try await TraceCommands.summarize(trace, target: target, pid: pid, names: names, xctrace: xctrace)
        } catch {
            if !(error is CancellationError) { kept = true }
            throw DeviceLoopError.adding(detail: "trace kept at \(trace.path)", to: error)
        }
    }

    /// What `analyzed` needs to check candidates against a trace. `file` is the kept trace.
    struct TraceMatch {
        var swaps: SurfaceSwaps?
        var clockOffset: Double
        var hitches: [TraceSummary.Hitch]?
        var file: String?
    }

    /// False for launch, open and sleep, which run without the UI runner.
    static func needsRunner(_ step: UIStep) -> Bool {
        switch step {
            case .launch, .openURL, .sleep: return false
            default: return true
        }
    }

    /// Runs launch, open and sleep without the UI runner, and every other step through `runner`, or a new connection.
    static func perform(_ step: UIStep, on target: Target, app: String?, runner: RunnerSession?) async throws {
        switch step {
            case .launch(let bundleID, let arguments, let environment):
                _ = try await AppCommands.start(
                    target, bundleID: bundleID, arguments: arguments, environment: environment, console: nil, terminateExisting: false)
            case .openURL(let url):
                _ = try await AppCommands.open(target, url: url)
            case .sleep(let ms):
                try await Task.sleep(for: .milliseconds(ms))
            default:
                let messages: [String]
                if let runner {
                    messages = try await UICommands.run(step, app: app, client: runner.client).reply.issues.map(\.message)
                } else {
                    let result = try await UICommands.perform(step, on: target, app: app)
                    messages = (result.json["issues"]?.array ?? []).map { $0["message"]?.string ?? "" }
                }
                for message in messages {
                    FileHandle.standardError.write(Data("XCTest warning: \(message)\n".utf8))
                }
        }
    }

    /// Analyzes any MP4 or MOV, including QuickTime and Device Hub recordings.
    public static func inspect(_ file: URL, sheet: Bool, region: CGRect? = nil, masks: [CGRect] = []) async throws -> CommandResult {
        var options = VideoAnalyzer.Options()
        options.region = region
        options.masks = masks
        return try await analyzed(file, header: nil, options: options, sheet: sheet, keepVideo: true)
    }

    /// Parses an analysis area, `x,y,w,h` in source pixels.
    public static func area(_ text: String) throws -> CGRect {
        let values = text.split(separator: ",", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == 4, let x = values[0], let y = values[1], let width = values[2], let height = values[3],
            width > 0, height > 0
        else {
            throw DeviceLoopError(
                .badArguments, "An area is x,y,w,h in source pixels with a positive size, got \(text).",
                fix: "For example: 0,300,1206,1800")
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func options(for stopped: StoppedRecording) -> VideoAnalyzer.Options {
        var options = VideoAnalyzer.Options()
        options.endAt = stopped.endAt
        options.backend = stopped.handle.simulator ? "simctl" : "usb"
        options.simulator = stopped.handle.simulator
        if stopped.handle.simulator {
            // Assumed, because simctl writes frames only when the screen changes.
            options.refreshHz = 60
        } else if let slot = stopped.slot {
            options.refreshHz = 1 / slot
            options.refreshMeasured = true
        }
        options.recorderDrops = stopped.drops
        options.captureSource = stopped.source
        options.clock = stopped.clock
        options.arrivalSpread = stopped.arrivalSpread
        return options
    }

    /// Runs the analysis, writes the contact sheet, and deletes the video unless `keepVideo`.
    /// A failed analysis keeps the video and names it in the error detail.
    static func analyzed(
        _ video: URL,
        header: String?,
        options: VideoAnalyzer.Options,
        action: AnimationReport.Action? = nil,
        trace: TraceMatch? = nil,
        sheet: Bool = true,
        keepVideo: Bool
    ) async throws -> CommandResult {
        do {
            var result = try await VideoAnalyzer.analyze(video, options: options)
            result.report.action = action
            var images: [ImageAttachment] = []
            var files: [URL] = []
            if let trace {
                result.report.matchTrace(trace.swaps, clockOffset: trace.clockOffset, hitches: trace.hitches)
                result.report.trace?.file = trace.file
                files += trace.file.map { [URL(filePath: $0)] } ?? []
            }
            if sheet {
                let cells = ContactSheet.cells(for: result, actionAt: options.actionAt)
                let png = try await ContactSheet.render(
                    video, cells: cells, firstPTS: result.firstPTS, crop: ContactSheet.crop(for: result))
                let path = try Paths.newArtifact("sheet", extension: "png")
                try png.write(to: path)
                result.report.contactSheet = path.path
                let jpeg = try ScreenshotImage.jpeg(from: path, maxPixelSize: Int(ContactSheet.maxEdge))
                images.append(ImageAttachment(data: jpeg, mimeType: "image/jpeg", path: path))
                files.append(path)
            }
            if keepVideo {
                files.insert(video, at: 0)
            } else {
                result.report.video = nil
            }
            let text = ([header].compactMap { $0 } + result.report.lines).joined(separator: "\n")
            let analysis = try CommandResult(text: text, payload: result.report, images: images, files: files)
            if !keepVideo { try? FileManager.default.removeItem(at: video) }
            return analysis
        } catch {
            guard FileManager.default.fileExists(atPath: video.path) else { throw error }
            throw DeviceLoopError.adding(detail: "video kept at \(video.path)", to: error)
        }
    }

    /// Path, frame count and size of a finished recording, without decoding it.
    static func summary(_ stopped: StoppedRecording) async throws -> CommandResult {
        let asset = AVURLAsset(url: stopped.video)
        var frames = 0
        if let track = try await asset.loadTracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            reader.startReading()
            while let sample = output.copyNextSampleBuffer() {
                frames += CMSampleBufferGetNumSamples(sample)
            }
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: stopped.video.path)[.size] as? Int) ?? 0
        let megabytes = (Double(bytes) / 100_000).rounded() / 10
        let text = [
            stopped.handle.summary,
            "video \(stopped.video.path) | \(frames) frames, \(VideoAnalyzer.seconds(stopped.endAt))s recorded, \(megabytes) MB",
            stopped.handle.simulator ? "note: simulators write frames only when the screen changes" : nil,
        ]
        return CommandResult(
            text: text.compactMap { $0 }.joined(separator: "\n"),
            json: [
                "video": .string(stopped.video.path),
                "frames": .number(Double(frames)),
                "wallDurationSec": .number(VideoAnalyzer.seconds(stopped.endAt)),
                "bytes": .number(Double(bytes)),
                "backend": .string(stopped.handle.simulator ? "simctl" : "usb"),
            ],
            files: [stopped.video]
        )
    }

    /// The step in the `ui do` grammar, without the text of a type step.
    static func describe(_ step: UIStep) -> String {
        switch step {
            case .tap(let target, let count, let holdMs):
                return "\(holdMs != nil ? "hold" : count == 2 ? "doubletap" : "tap") \(describe(target))"
            case .swipe(let direction, let target, _):
                return "swipe \(direction)\(target.map { " \(describe($0))" } ?? "")"
            case .drag(let from, let to, _, _):
                return "drag \(Int(from.x)),\(Int(from.y)) \(Int(to.x)),\(Int(to.y))"
            case .type:
                return "type"
            case .press(let button):
                return "press \(button)"
            case .launch(let bundleID, _, _):
                return "launch \(bundleID)"
            case .openURL(let url):
                return "open \(url)"
            case .sleep(let ms):
                return "sleep \(ms)"
        }
    }

    static func describe(_ target: ElementTarget) -> String {
        if let point = target.point { return "\(Int(point.x)),\(Int(point.y))" }
        if let ref = target.ref { return "@\(ref)" }
        if let id = target.query?.id { return "id=\(id)" }
        if let contains = target.query?.labelContains { return "label~=\(contains)" }
        return "\"\(target.query?.label ?? "")\""
    }
}

/// The process that runs inside the capture helper app and writes frames from a USB device to disk.
public enum CaptureHelper {
    public static func main(_ arguments: [String]) async throws {
        let options = try USBCapture.Options(arguments)
        do {
            try await USBCapture(options).run()
        } catch {
            let failure = error as? DeviceLoopError ?? DeviceLoopError(.internalError, "\(error)")
            try? JSONEncoder().encode(failure).write(to: options.state.appending(path: "error.json"), options: .atomic)
            throw failure
        }
    }
}
