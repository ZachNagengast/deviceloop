//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import AVFoundation
import CoreMediaIO
import Foundation

/// Runs inside DeviceLoopCapture.app and writes the screen of one USB device to a movie file.
///
/// State files in `--state`: `pid`, `waiting-permission`, `ready` (host time of the first frame),
/// `error.json`, `frames.json` (sidecar) and `done`. Creating `stop` ends the recording, as do SIGINT and SIGTERM.
final class USBCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Options {
        /// Device name, matched against the capture device's `localizedName`.
        var name: String
        var output: URL
        var state: URL
        var codec = AVVideoCodecType.h264
        var maxSeconds = 600.0

        init(_ arguments: [String]) throws {
            var values: [String: String] = [:]
            var remaining = arguments[...]
            while let key = remaining.popFirst() {
                guard key.hasPrefix("--"), let value = remaining.popFirst() else {
                    throw DeviceLoopError(.badArguments, "capture-helper: unexpected argument \(key).")
                }
                values[String(key.dropFirst(2))] = value
            }
            guard let name = values["name"], let output = values["output"], let state = values["state"] else {
                throw DeviceLoopError(.badArguments, "capture-helper needs --name, --output and --state.")
            }
            self.name = name
            self.output = URL(filePath: output)
            self.state = URL(filePath: state, directoryHint: .isDirectory)
            if values["codec"] == "hevc" { codec = .hevc }
            if let seconds = values["max-seconds"].flatMap(Double.init) { maxSeconds = seconds }
        }
    }

    private let options: Options
    private let queue = DispatchQueue(label: "com.argmaxinc.deviceloop.capture.frames")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var frames: [Double] = []
    private var drops: [Double] = []
    private var size = (width: 0, height: 0)
    private var stopped = false
    private var failure: DeviceLoopError?
    private var session: AVCaptureSession?
    /// The session clock that sample timestamps use. Nil places frames by arrival time.
    private var syncClock: CMClock?
    /// First frame's arrival time minus its timestamp, added to timestamps when there is no session clock.
    private var arrivalOffset = 0.0
    /// Smallest and largest arrival time minus timestamp, when there is no session clock.
    private var arrivalLag: ClosedRange<Double>?

    init(_ options: Options) {
        self.options = options
    }

    func run() async throws {
        try Paths.ensureDirectory(options.state)
        try Recorder.requireNewVideo(options.output)
        try write("\(getpid())", to: "pid")
        let interrupt = InterruptFlag()
        defer { interrupt.remove() }

        Self.allowScreenCaptureDevices()
        let device = try await findDevice()
        try await authorize()

        let session = AVCaptureSession()
        let deviceInput: AVCaptureDeviceInput
        do {
            deviceInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw DeviceLoopError(
                .recorderBusy,
                "\(options.name) screen capture could not be opened.",
                fix: "Close QuickTime or any other app recording the device, then retry.",
                detail: "\(error)"
            )
        }
        for port in deviceInput.ports where port.mediaType == .audio {
            port.isEnabled = false
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = false
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(deviceInput), session.canAddOutput(output) else {
            throw DeviceLoopError(
                .recorderBusy, "\(options.name) screen capture is in use.",
                fix: "Close QuickTime or any other app recording the device, then retry.")
        }
        session.addInput(deviceInput)
        session.addOutput(output)
        queue.sync { self.session = session }
        session.startRunning()

        let started = hostNow()
        while true {
            let (frameCount, failed) = queue.sync { (frames.count, failure) }
            if let failed { throw failed }
            if frameCount == 0, hostNow() - started > 10 {
                throw DeviceLoopError(.deviceError, "No frames from \(options.name) after 10 s.", fix: "Unlock the device and retry.")
            }
            if interrupt.isRaised || FileManager.default.fileExists(atPath: options.state.appending(path: "stop").path)
                || hostNow() - started > options.maxSeconds
            {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        queue.sync { stopped = true }
        session.stopRunning()
        let (writer, input, frames, drops, size, syncClock, arrivalLag) = queue.sync {
            (self.writer, self.input, self.frames, self.drops, self.size, self.syncClock, self.arrivalLag)
        }
        guard let writer, let input, let first = frames.first else {
            throw DeviceLoopError(.deviceError, "No frames were recorded from \(options.name).")
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw DeviceLoopError(
                .internalError, "Could not finish \(options.output.lastPathComponent).", detail: writer.error.map { "\($0)" })
        }
        let sidecar = CaptureSidecar(
            clock: syncClock == nil ? "arrival" : "host",
            arrivalSpread: arrivalLag.map { $0.upperBound - $0.lowerBound },
            firstFrameAt: first, frames: frames, drops: drops, width: size.width, height: size.height,
            source: AnimationReport.CaptureSource(uniqueID: device.uniqueID, name: device.localizedName))
        try JSONEncoder().encode(sidecar).write(to: options.state.appending(path: "frames.json"))
        try write("", to: "done")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !stopped else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        do {
            let arrival = hostNow()
            if writer == nil {
                syncClock = session?.synchronizationClock
                arrivalOffset = arrival - time.seconds
                FileHandle.standardError.write(
                    Data("first frame pts \(time.seconds) host \(arrival) clock \(syncClock == nil ? "arrival" : "host")\n".utf8))
                try startWriter(sampleBuffer, at: time)
            }
            guard let input, input.isReadyForMoreMediaData else {
                drops.append(hostTime(time))
                return
            }
            guard input.append(sampleBuffer) else {
                throw DeviceLoopError(.internalError, "Writing a frame failed.", detail: writer?.error.map { "\($0)" })
            }
            if syncClock == nil {
                let lag = arrival - time.seconds
                arrivalLag = arrivalLag.map { min($0.lowerBound, lag) ... max($0.upperBound, lag) } ?? lag ... lag
            }
            frames.append(hostTime(time))
            if frames.count == 1 { try write(String(frames[0]), to: "ready") }
        } catch {
            failure = error as? DeviceLoopError ?? DeviceLoopError(.internalError, "\(error)")
            stopped = true
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        drops.append(hostTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }

    /// Host seconds of a sample timestamp, converted from the session clock or shifted by the first frame's arrival.
    private func hostTime(_ time: CMTime) -> Double {
        syncClock.map { CMSyncConvertTime(time, from: $0, to: CMClockGetHostTimeClock()).seconds } ?? time.seconds + arrivalOffset
    }

    private func startWriter(_ sampleBuffer: CMSampleBuffer, at time: CMTime) throws {
        guard let image = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw DeviceLoopError(.internalError, "The first captured frame has no image.")
        }
        size = (CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image))
        let fileType: AVFileType = options.output.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: options.output, fileType: fileType)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: options.codec, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height]
        )
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        guard writer.startWriting() else {
            throw DeviceLoopError(.internalError, "Could not start writing \(options.output.path).", detail: writer.error.map { "\($0)" })
        }
        writer.startSession(atSourceTime: time)
        self.writer = writer
        self.input = input
    }

    /// Makes iPhones and iPads connected over USB show up as capture devices, as QuickTime does.
    static func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    private func findDevice() async throws -> AVCaptureDevice {
        let started = hostNow()
        while true {
            let external = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: nil, position: .unspecified).devices
            let devices = external.filter { $0.modelID == "iOS Device" }
            let matches = devices.filter { $0.localizedName == options.name }
            if matches.count > 1 {
                throw DeviceLoopError(
                    .deviceAmbiguous,
                    "\(matches.count) USB capture sources are named \(options.name).",
                    fix: "Rename one device or disconnect the other, then retry.",
                    alternatives: matches.map(\.uniqueID)
                )
            }
            if let device = matches.first {
                FileHandle.standardError.write(Data("capture device \(device.localizedName) [\(device.uniqueID)]\n".utf8))
                return device
            }
            if hostNow() - started > 10 {
                throw DeviceLoopError(
                    .deviceNotFound,
                    "\(options.name) did not appear as a USB screen capture source.",
                    fix: "Connect it with a USB cable, unlock it, tap Trust if asked, and retry.",
                    detail: "External capture devices: " + (external.map { "\($0.localizedName) (\($0.modelID))" }.joined(separator: ", ")),
                    alternatives: devices.map(\.localizedName)
                )
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func authorize() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                return
            case .notDetermined:
                try write("", to: "waiting-permission")
                // requestAccess cannot be cancelled, so a stop request during the dialog ends the process.
                let stopFile = options.state.appending(path: "stop").path
                let watcher = Task.detached {
                    while !Task.isCancelled {
                        if FileManager.default.fileExists(atPath: stopFile) { exit(2) }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                defer { watcher.cancel() }
                if await AVCaptureDevice.requestAccess(for: .video) { return }
            default:
                break
        }
        throw DeviceLoopError(
            .screenCaptureDenied,
            "DeviceLoopCapture is not allowed to use the camera, which USB screen capture needs.",
            fix: "Open System Settings > Privacy and Security > Camera, turn on DeviceLoopCapture, then retry."
        )
    }

    private func write(_ text: String, to name: String) throws {
        try text.write(to: options.state.appending(path: name), atomically: true, encoding: .utf8)
    }
}
