//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

// Renders a demo video: a terminal replaying a timeline on the left, the device recording on the right.
// Usage: xcrun swift scripts/demo/render.swift <timeline.json> <out.mp4>

import AVFoundation
import AppKit
import CoreText
import VideoToolbox

struct Timeline: Decodable {
    struct Event: Decodable {
        var t: Double
        var kind: String
        var text: String
    }

    var video: String
    var duration: Double
    var events: [Event]
}

let width = 1920
let height = 1080
let fps = 30.0
let typingCharsPerSecond = 40.0

let background = CGColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1)
let terminalBackground = CGColor(red: 0.09, green: 0.10, blue: 0.13, alpha: 1)
let titleBar = CGColor(red: 0.15, green: 0.16, blue: 0.20, alpha: 1)
let windowButtonColors = [
    CGColor(red: 1, green: 0.37, blue: 0.34, alpha: 1), CGColor(red: 1, green: 0.74, blue: 0.18, alpha: 1),
    CGColor(red: 0.16, green: 0.79, blue: 0.25, alpha: 1),
]
let promptColor = NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.55, alpha: 1)
let commandColor = NSColor(calibratedWhite: 0.96, alpha: 1)
let outputColor = NSColor(calibratedWhite: 0.68, alpha: 1)
let errorColor = NSColor(calibratedRed: 1, green: 0.45, blue: 0.42, alpha: 1)
let chapterColor = NSColor(calibratedWhite: 1, alpha: 1)
let captionColor = NSColor(calibratedWhite: 0.80, alpha: 1)

let mono = NSFont.monospacedSystemFont(ofSize: 21, weight: .regular)
let monoBold = NSFont.monospacedSystemFont(ofSize: 21, weight: .semibold)
let chapterFont = NSFont.systemFont(ofSize: 40, weight: .bold)
let captionFont = NSFont.systemFont(ofSize: 26, weight: .regular)

let terminalRect = CGRect(x: 60, y: 110, width: 1100, height: 860)
let videoRect = CGRect(x: 1220, y: 50, width: 640, height: 980)
let lineHeight = 30.0
let maxColumns = 82

/// One rendered terminal line with its color and font.
struct Line {
    var text: String
    var color: NSColor
    var font: NSFont
}

func wrapped(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).flatMap { raw -> [String] in
        let line = String(raw)
        var rows: [String] = []
        var row = ""
        for word in line.split(separator: " ", omittingEmptySubsequences: false) {
            if !row.isEmpty, row.count + 1 + word.count > maxColumns {
                rows.append(row)
                row = "  "
            }
            row += (row.isEmpty || row == "  " ? "" : " ") + word
            while row.count > maxColumns {
                rows.append(String(row.prefix(maxColumns)))
                row = "  " + row.dropFirst(maxColumns)
            }
        }
        return rows + [row]
    }
}

/// Terminal lines visible at `time`, with the command being typed shown up to the typed length.
func terminalLines(_ events: [Timeline.Event], at time: Double) -> [Line] {
    var lines: [Line] = []
    for event in events {
        switch event.kind {
            case "command":
                let typing = Double(event.text.count) / typingCharsPerSecond
                let start = event.t - typing
                guard time >= start else { continue }
                let typed = min(event.text.count, Int((time - start) * typingCharsPerSecond))
                let text = "$ " + String(event.text.prefix(typed))
                if !lines.isEmpty { lines.append(Line(text: "", color: outputColor, font: mono)) }
                lines += wrapped(text).map { Line(text: $0, color: commandColor, font: monoBold) }
            case "output" where time >= event.t:
                for line in wrapped(event.text) {
                    lines.append(Line(text: line, color: line.hasPrefix("ERROR") ? errorColor : outputColor, font: mono))
                }
            default:
                continue
        }
    }
    return lines
}

func latest(_ events: [Timeline.Event], kind: String, at time: Double) -> String? {
    events.last { $0.kind == kind && $0.t <= time }?.text
}

func draw(_ text: String, font: NSFont, color: NSColor, at point: CGPoint, in context: CGContext) {
    let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = point
    CTLineDraw(line, context)
}

func drawTerminalLine(_ line: Line, at point: CGPoint, in context: CGContext) {
    guard line.text.hasPrefix("$ ") else {
        draw(line.text, font: line.font, color: line.color, at: point, in: context)
        return
    }
    draw("$", font: monoBold, color: promptColor, at: point, in: context)
    draw(String(line.text.dropFirst(2)), font: line.font, color: line.color, at: CGPoint(x: point.x + 26, y: point.y), in: context)
}

func renderFrame(_ timeline: Timeline, time: Double, video: CGImage?, into buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    else { return }
    context.setFillColor(background)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    if let chapter = latest(timeline.events, kind: "chapter", at: time) {
        draw(chapter, font: chapterFont, color: chapterColor, at: CGPoint(x: terminalRect.minX, y: CGFloat(height) - 80), in: context)
    }
    if let caption = latest(timeline.events, kind: "caption", at: time) {
        draw(caption, font: captionFont, color: captionColor, at: CGPoint(x: terminalRect.minX, y: 50), in: context)
    }

    let window = CGPath(roundedRect: terminalRect, cornerWidth: 14, cornerHeight: 14, transform: nil)
    context.addPath(window)
    context.setFillColor(terminalBackground)
    context.fillPath()
    let bar = CGRect(x: terminalRect.minX, y: terminalRect.maxY - 40, width: terminalRect.width, height: 40)
    context.saveGState()
    context.addPath(window)
    context.clip()
    context.setFillColor(titleBar)
    context.fill(bar)
    context.restoreGState()
    for (index, color) in windowButtonColors.enumerated() {
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: terminalRect.minX + 18 + CGFloat(index) * 24, y: bar.midY - 7, width: 14, height: 14))
    }

    let visibleRows = Int((terminalRect.height - 70) / lineHeight)
    let lines = terminalLines(timeline.events, at: time).suffix(visibleRows)
    for (row, line) in lines.enumerated() {
        let y = bar.minY - 36 - CGFloat(row) * lineHeight
        drawTerminalLine(line, at: CGPoint(x: terminalRect.minX + 24, y: y), in: context)
    }

    if let video {
        let scale = min(videoRect.width / CGFloat(video.width), videoRect.height / CGFloat(video.height))
        let size = CGSize(width: CGFloat(video.width) * scale, height: CGFloat(video.height) * scale)
        let frame = CGRect(x: videoRect.midX - size.width / 2, y: videoRect.midY - size.height / 2, width: size.width, height: size.height)
        context.saveGState()
        let radius = size.width * 0.09
        context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.draw(video, in: frame)
        context.restoreGState()
    }
}

/// Decodes the device recording in order and hands back the latest frame at or before a time.
final class VideoFrames {
    private let output: AVAssetReaderTrackOutput
    private let reader: AVAssetReader
    private var pending: (time: Double, image: CGImage)?
    private var current: CGImage?

    init(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
    }

    func frame(at time: Double) -> CGImage? {
        while true {
            if let pending, pending.time > time { return current }
            if let pending { current = pending.image }
            guard let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else {
                pending = nil
                return current
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
            if let image { pending = (pts, image) }
        }
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: render.swift <timeline.json> <out.mp4>\n".utf8))
    exit(64)
}
let timelineURL = URL(filePath: arguments[1])
let timeline = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: timelineURL))
let outputURL = URL(filePath: arguments[2])
try? FileManager.default.removeItem(at: outputURL)

let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
    ]
)
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ]
)
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let videoURL = URL(filePath: timeline.video, relativeTo: timelineURL.deletingLastPathComponent())
let frames = try await VideoFrames(videoURL)
let frameCount = Int(timeline.duration * fps)
for index in 0 ..< frameCount {
    let time = Double(index) / fps
    while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
    guard let pool = adaptor.pixelBufferPool else { fatalError("no pixel buffer pool") }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard let buffer else { fatalError("no pixel buffer") }
    renderFrame(timeline, time: time, video: frames.frame(at: time), into: buffer)
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
}
input.markAsFinished()
await writer.finishWriting()
print("wrote \(outputURL.path) (\(frameCount) frames)")
