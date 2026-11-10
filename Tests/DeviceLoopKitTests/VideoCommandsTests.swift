//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import ImageIO
import Testing

@testable import DeviceLoopKit

@Suite(.serialized) struct VideoCommandsTests {
    @Test func inspectReturnsJPEGContactSheetAndKeepsPNGOnDisk() async throws {
        let video = try await SyntheticVideo.write(boxAt: VideoAnalyzerTests.movingBox())
        defer { try? FileManager.default.removeItem(at: video) }
        let result = try await VideoCommands.inspect(video, sheet: true)
        defer {
            for path in result.images.compactMap(\.path) { try? FileManager.default.removeItem(at: path) }
        }

        #expect(result.text.hasPrefix("video \(video.path)"))
        #expect(result.json["schema"]?.string == "deviceloop.animation/2")
        let image = try #require(result.images.first)
        let png = try #require(image.path)
        #expect(image.mimeType == "image/jpeg")
        #expect(png.pathExtension == "png")
        #expect(result.text.contains(png.path))
        let jpegSource = try #require(CGImageSourceCreateWithData(image.data as CFData, nil))
        let jpeg = try #require(CGImageSourceCreateImageAtIndex(jpegSource, 0, nil))
        let pixels = try ScreenshotImage.pixelSize(of: png)
        #expect(jpeg.width == pixels.width && jpeg.height == pixels.height)
    }

    @Test func reportLabelsGapsAsVisualCandidatesWithoutAppleBands() async throws {
        var positions = VideoAnalyzerTests.movingBox()
        positions[30] = positions[29]
        let video = try await SyntheticVideo.write(boxAt: positions)
        defer { try? FileManager.default.removeItem(at: video) }
        let result = try await VideoCommands.inspect(video, sheet: false)

        let candidates = try #require(result.json["candidates"]?.object)
        #expect(result.json["hitches"] == nil)
        #expect(candidates["rating"] == nil)
        #expect(candidates["count"]?.number == 1)
        #expect(result.text.contains("\ngap candidates 1, 1 jump 16.7ms total, visual estimate "))
    }

    /// Stops a finished USB recording of `video` whose capture helper wrote `sidecar`.
    static func stopUSBRecording(_ video: URL, sidecar: CaptureSidecar) async throws -> StoppedRecording {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let state = try Paths.ensureDirectory(Recorder.stateDirectory(id))
        try JSONEncoder().encode(sidecar).write(to: state.appending(path: "frames.json"))
        FileManager.default.createFile(atPath: state.appending(path: "done").path, contents: nil)
        let handle = RecordingHandle(
            id: id, udid: "test", summary: "test", simulator: false, pid: 0, video: video.path, startedAt: sidecar.firstFrameAt)
        return try await Recorder.stop(handle)
    }

    @Test func usbCadenceIsMeasuredFromSidecarTimestamps() async throws {
        let video = try await SyntheticVideo.write(boxAt: VideoAnalyzerTests.movingBox())
        defer { try? FileManager.default.removeItem(at: video) }
        let sidecar = CaptureSidecar(
            firstFrameAt: 10, frames: (0 ... 30).map { 10 + Double($0) / 30 }, drops: [], width: SyntheticVideo.width,
            height: SyntheticVideo.height)

        let stopped = try await Self.stopUSBRecording(video, sidecar: sidecar)
        let cadence = try await VideoAnalyzer.analyze(video, options: VideoCommands.options(for: stopped)).report.cadence

        #expect(abs(stopped.endAt - 31.0 / 30) < 0.001)
        #expect(cadence.slotMs == 33.3)
        #expect(cadence.fps == 30)
        #expect(cadence.fpsSource == "measured")
    }

    @Test func usbReportCarriesTheCaptureSourceFromTheSidecar() async throws {
        let video = try await SyntheticVideo.write(boxAt: VideoAnalyzerTests.movingBox())
        defer { try? FileManager.default.removeItem(at: video) }
        let source = AnimationReport.CaptureSource(uniqueID: "00008130-000A1B2C3D4E5F60", name: "Test iPhone 15 Pro Max")
        let sidecar = CaptureSidecar(
            firstFrameAt: 10, frames: (0 ... 30).map { 10 + Double($0) / 60 }, drops: [], width: SyntheticVideo.width,
            height: SyntheticVideo.height, source: source)

        let stopped = try await Self.stopUSBRecording(video, sidecar: sidecar)
        let recording = try await VideoAnalyzer.analyze(video, options: VideoCommands.options(for: stopped)).report.recording

        #expect(recording.captureSource == source)
    }

    @Test func hostClockSidecarReportsTheHostClock() async throws {
        let video = try await SyntheticVideo.write(boxAt: VideoAnalyzerTests.movingBox())
        defer { try? FileManager.default.removeItem(at: video) }
        let sidecar = CaptureSidecar(
            clock: "host", firstFrameAt: 10, frames: (0 ... 30).map { 10 + Double($0) / 60 }, drops: [],
            width: SyntheticVideo.width, height: SyntheticVideo.height)

        let stopped = try await Self.stopUSBRecording(video, sidecar: sidecar)
        let report = try await VideoAnalyzer.analyze(video, options: VideoCommands.options(for: stopped)).report

        #expect(report.recording.clock == "host")
        #expect(report.recording.arrivalSpreadMs == nil)
        #expect(!report.warnings.contains { $0.contains("arrival") })
    }

    @Test func arrivalClockSidecarReportsTheArrivalSpread() async throws {
        let video = try await SyntheticVideo.write(boxAt: VideoAnalyzerTests.movingBox())
        defer { try? FileManager.default.removeItem(at: video) }
        let sidecar = CaptureSidecar(
            clock: "arrival", arrivalSpread: 0.0042, firstFrameAt: 10, frames: (0 ... 30).map { 10 + Double($0) / 60 },
            drops: [], width: SyntheticVideo.width, height: SyntheticVideo.height)

        let stopped = try await Self.stopUSBRecording(video, sidecar: sidecar)
        let report = try await VideoAnalyzer.analyze(video, options: VideoCommands.options(for: stopped)).report

        #expect(report.recording.clock == "arrival")
        #expect(report.recording.arrivalSpreadMs == 4.2)
        #expect(report.warnings.contains("frame times are aligned by arrival, not by the capture clock, arrival lag varied by 4.2 ms"))
    }

    @Test func sameNamedDeviceOnTheNetworkMakesUSBCaptureAmbiguous() throws {
        var targets = try Self.recordedTargets()
        let wired = try #require(targets.first { $0.name == "Test iPhone 15 Pro Max" })
        let index = try #require(targets.firstIndex { $0.name == "Test iPhone 17 Pro Max" })
        targets[index].name = "test iphone 15 pro max"
        let error = #expect(throws: DeviceLoopError.self) { try Recorder.requireUSBSource(wired, among: targets) }

        #expect(error?.code == .deviceAmbiguous)
        #expect(error?.alternatives.count == 2)
    }

    @Test func networkOnlyDeviceCannotBeCapturedOverUSB() throws {
        let targets = try Self.recordedTargets()
        let wireless = try #require(targets.first { $0.name == "Test iPhone 17 Pro Max" })
        let error = #expect(throws: DeviceLoopError.self) { try Recorder.requireUSBSource(wireless, among: targets) }

        #expect(error?.code == .unsupportedOnTarget)
    }

    @Test func uniquelyNamedWiredDevicePassesTheUSBSourceCheck() throws {
        let targets = try Self.recordedTargets()
        let wired = try #require(targets.first { $0.name == "Test iPhone 15 Pro Max" })

        try Recorder.requireUSBSource(wired, among: targets)
    }

    @Test func disconnectedDeviceWithTheSameNameLeavesUSBCaptureUnambiguous() throws {
        var targets = try Self.recordedTargets()
        let wired = try #require(targets.first { $0.name == "Test iPhone 15 Pro Max" })
        let index = try #require(targets.firstIndex { $0.name == "Test iPhone 11" })
        #expect(!targets[index].isReady)
        targets[index].name = wired.name

        try Recorder.requireUSBSource(wired, among: targets)
    }

    @Test func preflightRejectsADeviceOnTheLocalNetwork() async throws {
        let targets = try Self.recordedTargets()
        let wireless = try #require(targets.first { $0.name == "Test iPhone 17 Pro Max" })
        await #expect {
            try await Recorder.preflight(wireless, list: { targets }, wiredTimeout: .zero)
        } throws: {
            ($0 as? DeviceLoopError)?.code == .unsupportedOnTarget
        }
    }

    @Test func preflightWaitsOutTheUSBCaptureCooldown() async throws {
        var wired = device(tunnel: "fd00::1")
        wired.transport = "wired"
        try Paths.ensureDirectory(Recorder.directory)
        let endedAt = Date().timeIntervalSince1970 - Recorder.captureCooldown + 0.5
        try Data("\(endedAt)".utf8).write(to: Recorder.lastCaptureEnd)
        let start = ContinuousClock.now
        try await Recorder.preflight(wired, list: { [wired] }, wiredTimeout: .zero)
        #expect(ContinuousClock.now - start >= .milliseconds(400))
    }

    @Test func actionReportsTheWindowFromSendToAck() async throws {
        let video = try await SyntheticVideo.write(boxAt: VideoAnalyzerTests.movingBox())
        defer { try? FileManager.default.removeItem(at: video) }
        var options = VideoAnalyzer.Options()
        options.actionAt = 0.25
        let action = AnimationReport.Action(
            step: "tap id=fixture.counter.increment", status: "ran", sentAt: 0.25, ackAt: 0.335, windowMs: 85,
            note: "XCTest idle waits fall inside the window")
        let result = try await VideoCommands.analyzed(video, header: nil, options: options, action: action, sheet: false, keepVideo: true)

        #expect(result.json["action"]?["windowMs"]?.number == 85)
        #expect(
            result.text.contains(
                "\naction tap id=fixture.counter.increment at 0.25s: ran, window 85ms from send to ack, XCTest idle waits fall inside the window\n"
            ))
        #expect(result.text.contains("\nresponse first change 0.35s (+100ms from send)"))
    }

    @Test func areaNeedsFourIntegersWithAPositiveSize() throws {
        #expect(try VideoCommands.area("0, 300,1206,1800") == CGRect(x: 0, y: 300, width: 1206, height: 1800))
        for text in ["0,300,1206", "0,300,1206,0", "0,,1206,1800", "a,b,c,d", "0,300,1206,1800,1"] {
            #expect(throws: DeviceLoopError.self) { try VideoCommands.area(text) }
        }
    }

    @Test func simulatorCadenceIsAssumed60Hz() async throws {
        let video = try await SyntheticVideo.write(boxAt: VideoAnalyzerTests.movingBox())
        defer { try? FileManager.default.removeItem(at: video) }
        let handle = RecordingHandle(id: "test", udid: "test", summary: "test", simulator: true, pid: 0, video: video.path, startedAt: 0)
        let stopped = StoppedRecording(handle: handle, video: video, endAt: 1.5, drops: [])
        let cadence = try await VideoAnalyzer.analyze(video, options: VideoCommands.options(for: stopped)).report.cadence

        #expect(cadence.fps == 60)
        #expect(cadence.fpsSource == "assumed")
    }

    @Test func recorderIsRunningOnlyWhilePidStartTimeMatches() throws {
        let pid = getpid()
        let start = try #require(Recorder.processStart(pid))
        var handle = RecordingHandle(
            id: "test", udid: "test", summary: "test", simulator: true, pid: pid, pidStart: start, video: "/tmp/test.mp4", startedAt: 0)
        #expect(Recorder.isRunning(handle))
        handle.pidStart = start + 1
        #expect(!Recorder.isRunning(handle))
        handle.pidStart = nil
        #expect(!Recorder.isRunning(handle))
    }

    @Test func interruptSleepEndsWhenTaskIsCancelled() async {
        let interrupt = InterruptFlag()
        defer { interrupt.remove() }
        let sleeper = Task { await interrupt.sleep(seconds: 30) }
        sleeper.cancel()
        #expect(await sleeper.value)
    }

    @Test func removingOneInterruptFlagKeepsSignalsIgnoredForAnother() {
        let first = InterruptFlag()
        let second = InterruptFlag()
        first.remove()
        var action = sigaction()
        sigaction(SIGINT, nil, &action)
        #expect(unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self))
        second.remove()
    }

    @Test func captureHelperRequiresNameOutputAndState() throws {
        let options = try USBCapture.Options(["--name", "Test iPhone", "--output", "/tmp/a.mp4", "--state", "/tmp/state"])
        #expect(options.name == "Test iPhone")
        #expect(options.state.path == "/tmp/state")
        #expect(throws: DeviceLoopError.self) { try USBCapture.Options(["--name", "Test iPhone", "--output", "/tmp/a.mp4"]) }
    }

    @Test(arguments: [true, false])
    func recordRefusesAnExistingOutputAndKeepsIt(folder: Bool) async throws {
        let output = FileManager.default.temporaryDirectory.appending(path: "deviceloop-video-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        if folder { try Paths.ensureDirectory(output) }
        let kept = folder ? output.appending(path: "kept.txt") : output
        try Data("kept".utf8).write(to: kept)
        await #expect {
            try await VideoCommands.record(target(.simulator), output: output, durationMs: 0)
        } throws: {
            ($0 as? DeviceLoopError)?.code == .badArguments
        }
        #expect(try Data(contentsOf: kept) == Data("kept".utf8))
    }

    @Test func captureHelperRefusesAnExistingOutputAndKeepsIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "deviceloop-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = try Paths.ensureDirectory(folder.appending(path: "video.mp4"))
        let options = try USBCapture.Options([
            "--name", "Test iPhone", "--output", output.path, "--state", folder.appending(path: "state").path,
        ])
        await #expect {
            try await USBCapture(options).run()
        } throws: {
            ($0 as? DeviceLoopError)?.code == .badArguments
        }
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    private func device(tunnel: String?, state: String = "connected") -> Target {
        Target(
            udid: "capture-test", identifier: "capture-test", name: "Capture test", kind: .device, deviceType: "iPhone",
            platform: "iOS", model: "fixture", productType: "fixture", osVersion: "test", connectionState: state, tunnelAddress: tunnel
        )
    }

    @Test func runnerStepAfterCaptureStartGetsTheReconnectedTunnelAddress() async throws {
        let listings = [[device(tunnel: nil, state: "disconnected")], [device(tunnel: "fd00::2")]]
        var calls = 0
        let refreshed = try await VideoCommands.reconnected(
            device(tunnel: "fd00::1"), for: try UIStep.parse("tap id=fixture.counter.increment"), startedAt: hostNow(),
            list: {
                calls += 1
                return listings[min(calls, listings.count) - 1]
            }
        )
        #expect(calls == 2)
        #expect(refreshed.target.tunnelAddress == "fd00::2")
        #expect(refreshed.reconnect?.from == "fd00::1")
        #expect(refreshed.reconnect?.to == "fd00::2")
    }

    @Test(arguments: ["launch com.example.app", "open https://example.com", "sleep 10"])
    func devicectlStepsSkipTheTargetRelist(step: String) async throws {
        let refreshed = try await VideoCommands.reconnected(
            device(tunnel: "fd00::1"), for: try UIStep.parse(step), startedAt: 0,
            list: {
                Issue.record("Listed targets for a step that does not use the runner")
                return []
            }
        )
        #expect(refreshed.target.tunnelAddress == "fd00::1")
        #expect(refreshed.reconnect == nil)
    }

    @Test func simulatorRunnerStepSkipsTheTargetRelist() async throws {
        let simulator = Target(
            udid: "capture-sim", identifier: "capture-sim", name: "Capture sim", kind: .simulator, deviceType: "iPhone",
            platform: "iOS", model: "fixture", productType: "fixture", osVersion: "test", connectionState: "connected", bootState: "booted"
        )
        let refreshed = try await VideoCommands.reconnected(
            simulator, for: try UIStep.parse("swipe up"), startedAt: 0,
            list: {
                Issue.record("Listed targets for a simulator")
                return []
            }
        )
        #expect(refreshed.reconnect == nil)
    }

    @Test func runnerStepWaitsForANewAddressWhenAsked() async throws {
        let listings = [[device(tunnel: "fd00::1")], [device(tunnel: nil, state: "connecting")], [device(tunnel: "fd00::2")]]
        var calls = 0
        let refreshed = try await VideoCommands.reconnected(
            device(tunnel: "fd00::1"), for: try UIStep.parse("tap id=fixture.counter.increment"), startedAt: hostNow(),
            newAddress: true,
            list: {
                calls += 1
                return listings[min(calls, listings.count) - 1]
            }
        )
        #expect(calls == 3)
        #expect(refreshed.reconnect?.to == "fd00::2")
    }

    @Test func stopWaitsUntilTheDeviceIsBackOnUSB() async {
        var wired = device(tunnel: "fd00::1")
        wired.transport = "wired"
        var network = wired
        network.transport = "localNetwork"
        let listings = [[device(tunnel: nil, state: "disconnected")], [network], [wired]]
        var calls = 0
        let handle = RecordingHandle(
            id: "test", udid: wired.udid, summary: "", simulator: false, pid: 0, video: "/dev/null", startedAt: 0)
        await VideoCommands.waitForDevice(after: StoppedRecording(handle: handle, video: URL(filePath: "/dev/null"), endAt: 0, drops: [])) {
            calls += 1
            return listings[min(calls, listings.count) - 1]
        }
        #expect(calls == 3)
    }

    @Test func cancelledStopWaitsForTheCaptureHelperAndStampsTheCooldown() async throws {
        let video = try await SyntheticVideo.write(boxAt: VideoAnalyzerTests.movingBox())
        defer { try? FileManager.default.removeItem(at: video) }
        var wired = device(tunnel: "fd00::1")
        wired.transport = "wired"
        let listing = [wired]
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let state = try Paths.ensureDirectory(Recorder.stateDirectory(id))
        let handle = RecordingHandle(
            id: id, udid: wired.udid, summary: "test", simulator: false, pid: 0, video: video.path, startedAt: 0)
        let stopping = Task { try await VideoCommands.stop(handle, list: { listing }) }
        stopping.cancel()
        try await Task.sleep(for: .milliseconds(200))
        let doneAt = Date().timeIntervalSince1970
        FileManager.default.createFile(atPath: state.appending(path: "done").path, contents: nil)

        #expect(try await stopping.value.video == video)
        #expect(try #require(Recorder.lastCaptureEnded()) >= doneAt)
    }

    /// A capture helper state directory, with a `pid` file naming no process when `pid` is true.
    private func helperState(pid: Bool) throws -> RecordingHandle {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let state = try Paths.ensureDirectory(Recorder.stateDirectory(id))
        if pid { try "\(Int32.max)".write(to: state.appending(path: "pid"), atomically: true, encoding: .utf8) }
        return RecordingHandle(id: id, udid: "test", summary: "test", simulator: false, pid: 0, video: "/dev/null", startedAt: 0)
    }

    @Test func stopOfAnExitedCaptureHelperStampsTheCooldown() async throws {
        var handle = try helperState(pid: false)
        handle.pid = .max
        let stoppedAt = Date().timeIntervalSince1970

        await #expect(throws: DeviceLoopError.self) { try await Recorder.stop(handle) }
        #expect(try #require(Recorder.lastCaptureEnded()) >= stoppedAt)
    }

    @Test func abandonedCaptureHelperStampsTheCooldown() async throws {
        let handle = try helperState(pid: true)
        defer { try? FileManager.default.removeItem(at: Recorder.stateDirectory(handle.id)) }
        let abandonedAt = Date().timeIntervalSince1970

        await Recorder.abandon(handle)
        #expect(try #require(Recorder.lastCaptureEnded()) >= abandonedAt)
    }

    @Test func abandonBeforeTheCaptureHelperRanLeavesTheCooldown() async throws {
        let handle = try helperState(pid: false)
        defer { try? FileManager.default.removeItem(at: Recorder.stateDirectory(handle.id)) }
        let before = Recorder.lastCaptureEnded()

        await Recorder.abandon(handle)
        #expect(Recorder.lastCaptureEnded() == before)
    }

    @Test func deviceThatDoesNotReconnectFailsAsOffline() async throws {
        do {
            _ = try await VideoCommands.reconnected(
                device(tunnel: "fd00::1"), for: try UIStep.parse("swipe up"), startedAt: 0, timeout: .zero,
                list: { [device(tunnel: nil, state: "disconnected")] }
            )
            Issue.record("A disconnected device was returned")
        } catch {
            #expect((error as? DeviceLoopError)?.code == .deviceOffline)
        }
    }

    @Test func captureReportShowsTheTunnelReconnect() async throws {
        let video = try await SyntheticVideo.write(boxAt: VideoAnalyzerTests.movingBox())
        defer { try? FileManager.default.removeItem(at: video) }
        let action = AnimationReport.Action(
            step: "tap id=fixture.counter.increment", status: "ran", sentAt: 0.5, ackAt: 0.6, windowMs: 100, note: nil,
            reconnect: AnimationReport.Reconnect(from: "fd00::1", to: "fd00::2", at: 0.25)
        )
        let result = try await VideoCommands.analyzed(
            video, header: nil, options: VideoAnalyzer.Options(), action: action, sheet: false, keepVideo: true)
        #expect(result.text.contains("tunnel moved from fd00::1 to fd00::2 at 0.25s"))
        #expect(result.json["action"]?["reconnect"]?["to"]?.string == "fd00::2")
    }

    @Test func failedAnalysisKeepsTheVideoAndNamesIt() async throws {
        let video = try Paths.newArtifact("corrupt", extension: "mp4")
        try Data("not a movie".utf8).write(to: video)
        defer { try? FileManager.default.removeItem(at: video) }
        do {
            _ = try await VideoCommands.analyzed(video, header: nil, options: VideoAnalyzer.Options(), keepVideo: false)
            Issue.record("A corrupt video analyzed")
        } catch {
            #expect((error as? DeviceLoopError)?.detail?.contains("video kept at \(video.path)") == true)
        }
        #expect(FileManager.default.fileExists(atPath: video.path))
    }

    @Test func missingVideoIsNotReportedAsKept() async throws {
        let video = Paths.home.appending(path: "missing-\(UUID().uuidString).mp4")
        do {
            _ = try await VideoCommands.analyzed(video, header: nil, options: VideoAnalyzer.Options(), keepVideo: true)
            Issue.record("A missing video analyzed")
        } catch {
            let failure = try #require(error as? DeviceLoopError)
            #expect(failure.message == "No video at \(video.path).")
            #expect(failure.detail == nil)
        }
    }

    @Test func describesATypeStepWithoutItsText() throws {
        #expect(VideoCommands.describe(try UIStep.parse("type hunter2")) == "type")
    }

    @Test func describesStepsInTheStepGrammar() throws {
        for step in ["tap \"Wi-Fi\"", "tap @e5", "swipe up", "drag 200,700 200,200", "sleep 500", "launch com.apple.Preferences"] {
            #expect(VideoCommands.describe(try UIStep.parse(step)) == step)
        }
    }

    private func target(_ kind: Target.Kind) -> Target {
        Target(
            udid: "00000000-0000-0000-0000-00000000F00D", identifier: "00000000-0000-0000-0000-00000000F00D", name: "Capture Target",
            kind: kind, deviceType: "iPhone", platform: "iOS", model: "fixture", productType: "fixture", osVersion: "27.0",
            connectionState: "connected", bootState: "booted")
    }

    @Test func instrumentsOnASimulatorIsUnsupportedBeforeRecording() async throws {
        await #expect {
            try await VideoCommands.capture(
                target(.simulator), step: .sleep(ms: 1), app: "com.example.app", preMs: 0, waitMs: 0, keepVideo: false, instruments: true)
        } throws: {
            ($0 as? DeviceLoopError)?.code == .unsupportedOnTarget
        }
    }

    @Test func instrumentsWithoutAppIsRejected() async throws {
        await #expect {
            try await VideoCommands.capture(
                target(.device), step: .sleep(ms: 1), app: nil, preMs: 0, waitMs: 0, keepVideo: false, instruments: true)
        } throws: {
            ($0 as? DeviceLoopError)?.code == .badArguments
        }
    }

    @Test(arguments: ["tap 120,nan", "hold id=x 600000"])
    func invalidStepIsRejectedBeforeRecording(step: String) async throws {
        await #expect {
            try await VideoCommands.capture(
                target(.device), step: try UIStep.parse(step), app: nil, preMs: 0, waitMs: 0, keepVideo: false)
        } throws: {
            ($0 as? DeviceLoopError)?.code == .badArguments
        }
    }

    @Test func instrumentsTraceLimitCoversPreRollWaitAndMarginUpTo60Seconds() throws {
        #expect(try VideoCommands.traceLimitMs(target(.device), app: "com.example.app", preMs: 300, waitMs: 1500) == 11_800)
        #expect(throws: DeviceLoopError.self) {
            try VideoCommands.traceLimitMs(target(.device), app: "com.example.app", preMs: 300, waitMs: 50_000)
        }
    }

    @Test func traceMatchMarksCandidatesAndNamesTheKeptTrace() async throws {
        var positions = VideoAnalyzerTests.movingBox()
        positions[30] = positions[29]
        let video = try await SyntheticVideo.write(boxAt: positions)
        defer { try? FileManager.default.removeItem(at: video) }
        let trace = VideoCommands.TraceMatch(swaps: nil, clockOffset: 1, hitches: nil, file: "/tmp/capture.trace")
        let result = try await VideoCommands.analyzed(
            video, header: nil, options: VideoAnalyzer.Options(), trace: trace, sheet: false, keepVideo: true)

        #expect(result.json.value(at: "candidates.items")?.array?.first?["traceVerdict"] == "unavailable")
        #expect(result.json.value(at: "trace.file") == "/tmp/capture.trace")
        #expect(result.text.contains("\ntrace /tmp/capture.trace"))
        #expect(result.files.contains(URL(filePath: "/tmp/capture.trace")))
    }

    static func recordedTargets() throws -> [Target] {
        let url = try #require(Bundle.module.url(forResource: "Resources/devicectl/list-devices", withExtension: "json"))
        let json = try JSONValue(data: Data(contentsOf: url))
        return (json.value(at: "result.devices")?.array ?? []).compactMap(Target.init(devicectl:))
    }
}
