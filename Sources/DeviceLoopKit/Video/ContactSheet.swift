//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A grid of timestamped frames from a recording, small enough for a vision model.
enum ContactSheet {
    struct Cell: Sendable {
        /// Seconds since the first frame.
        var time: Double
        var label: String
        var highlight: Bool
    }

    static let maxCells = 16
    static let maxEdge = 1568.0

    /// Frame before the action, first change, first frame after each feedback, both sides of every gap candidate,
    /// evenly spaced changes, last frame.
    static func cells(for result: VideoAnalyzer.Result, actionAt: Double?) -> [Cell] {
        let frames = result.frames
        guard let first = frames.first, let last = frames.last else { return [] }
        let from = actionAt ?? 0
        var picked: [Int] = []
        func add(_ index: Int?) {
            guard let index, !picked.contains(index), picked.count < maxCells else { return }
            picked.append(index)
        }
        add(actionAt.flatMap { action in frames.last { $0.time <= action }?.index } ?? first.index)
        let changed = frames.filter { $0.changed && $0.time >= from }
        add(changed.first?.index)
        for index in result.transitionStarts { add(index) }
        for index in result.candidateFrames.sorted() { add(index) }
        let room = maxCells - picked.count - 1
        if room > 0, !changed.isEmpty {
            let count = min(room, changed.count)
            for step in 0 ..< count { add(changed[step * changed.count / count].index) }
        }
        add(last.index)

        return picked.sorted().map { index in
            let frame = frames[index]
            let label: String
            if let actionAt {
                let offset = Int(((frame.time - actionAt) * 1000).rounded())
                label = "#\(index) \(offset >= 0 ? "+" : "")\(offset)ms"
            } else {
                label = "#\(index) \(String(format: "%.3f", frame.time))s"
            }
            return Cell(time: frame.time, label: label, highlight: result.candidateFrames.contains(index))
        }
    }

    /// Crops to the changed area when it covers less than 40 percent of the screen, with 10 percent padding.
    static func crop(for result: VideoAnalyzer.Result) -> CGRect? {
        guard result.transformIsIdentity, let region = result.changedRegion else { return nil }
        let screen = CGRect(origin: .zero, size: result.sourceSize)
        guard region.width * region.height < 0.4 * screen.width * screen.height else { return nil }
        return region.insetBy(dx: -0.1 * region.width, dy: -0.1 * region.height).intersection(screen).integral
    }

    /// Renders `cells` from the video at `url` and returns PNG data.
    static func render(_ url: URL, cells: [Cell], firstPTS: Double, crop: CGRect?) async throws -> Data {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var images: [CGImage] = []
        for cell in cells {
            // Half a millisecond past the frame's PTS so rounding never lands on the previous frame.
            let time = CMTime(seconds: firstPTS + cell.time + 0.0005, preferredTimescale: 1_000_000)
            let image = try await generator.image(at: time).image
            images.append(crop.flatMap { image.cropping(to: $0) } ?? image)
        }
        guard let sample = images.first else {
            throw DeviceLoopError(.internalError, "No frames to put on the contact sheet.")
        }

        let gap = 8.0
        let labelHeight = 20.0
        let aspect = Double(sample.width) / Double(sample.height)
        var best = (columns: 1, width: 0.0)
        for columns in 1 ... min(8, images.count) {
            let rows = Double((images.count + columns - 1) / columns)
            let byWidth = (maxEdge - gap * Double(columns + 1)) / Double(columns)
            let byHeight = (maxEdge - gap - rows * (labelHeight + gap)) / rows * aspect
            let width = min(byWidth, byHeight, Double(sample.width) * 2)
            if width > best.width { best = (columns, width) }
        }
        let columns = best.columns
        let rows = (images.count + columns - 1) / columns
        let cellWidth = best.width.rounded(.down)
        let cellHeight = (cellWidth / aspect).rounded(.down)
        let sheetWidth = Int(gap + Double(columns) * (cellWidth + gap))
        let sheetHeight = Int(gap + Double(rows) * (cellHeight + labelHeight + gap))

        guard
            let context = CGContext(
                data: nil,
                width: sheetWidth,
                height: sheetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw DeviceLoopError(.internalError, "Could not create the contact sheet bitmap.") }
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
        context.interpolationQuality = .high

        let fontSize = min(14, max(10, cellWidth / 12))
        let font = CTFontCreateWithName("Menlo-Regular" as CFString, fontSize, nil)
        let red = CGColor(red: 1, green: 0.27, blue: 0.23, alpha: 1)
        for (position, (cell, image)) in zip(cells, images).enumerated() {
            let x = gap + Double(position % columns) * (cellWidth + gap)
            let top = gap + Double(position / columns) * (cellHeight + labelHeight + gap)
            let frame = CGRect(x: x, y: Double(sheetHeight) - top - cellHeight, width: cellWidth, height: cellHeight)
            context.draw(image, in: frame)
            if cell.highlight {
                context.setStrokeColor(red)
                context.setLineWidth(3)
                context.stroke(frame.insetBy(dx: 1.5, dy: 1.5))
            }
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): cell.highlight ? red : CGColor(gray: 0.92, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: cell.label + (cell.highlight ? " gap" : ""), attributes: attributes)
            )
            context.textPosition = CGPoint(x: x + 2, y: frame.minY - labelHeight + 6)
            CTLineDraw(line, context)
        }

        guard let sheet = context.makeImage() else {
            throw DeviceLoopError(.internalError, "Could not finish the contact sheet image.")
        }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw DeviceLoopError(.internalError, "Could not encode the contact sheet.")
        }
        CGImageDestinationAddImage(destination, sheet, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw DeviceLoopError(.internalError, "Could not encode the contact sheet.")
        }
        return png as Data
    }
}
