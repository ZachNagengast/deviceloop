//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The pixels that differ between two screenshots of the same size, outside masks given in points.
public struct ImageDiff: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable {
        case same
        /// More than the allowed percent of the unmasked pixels changed.
        case changed
        /// The images could not be compared, see `reason`.
        case inconclusive
    }

    /// A pixel changed when one of its channels differs by more than this, out of 255.
    public static let threshold = 16
    /// Changed pixels in touching tiles of this many pixels share a box.
    static let tile = 32

    public var verdict: Verdict
    public var reason: String?
    /// Unmasked pixels that changed.
    public var changedPixels = 0
    /// Pixels outside the masks.
    public var comparedPixels = 0
    /// x, y, width and height in points of the changed pixels in each group of touching tiles.
    public var boxes: [[Double]] = []
    /// The diff image, relative to the comparison folder.
    public var image: String?

    /// `screenshot changed: 1.042% of unmasked pixels, 100 of 9600, in [20,10,5,5]`, or why the images were not compared.
    public var line: String {
        if verdict == .inconclusive { return "screenshots not compared: \(reason ?? "")" }
        let percent = comparedPixels == 0 ? 0 : Double(changedPixels) * 100 / Double(comparedPixels)
        var line = "screenshot \(verdict.rawValue): \(ParityText.number((percent * 1000).rounded() / 1000))% of unmasked pixels"
        line += ", \(changedPixels) of \(comparedPixels)"
        if !boxes.isEmpty { line += ", in " + boxes.map { "[\(TreeDiff.points($0))]" }.joined(separator: " ") }
        return line
    }

    /// Compares the PNGs at `baseline` and `candidate`. `masks` are x, y, width and height in points, converted to pixels
    /// with `pointScale`. Changed when more than `maxDiffPercent` of the unmasked pixels changed. Returns the diff image as
    /// PNG when a pixel changed: changed pixels red, masks dark blue, the rest the candidate at a quarter brightness.
    public static func compare(
        _ baseline: URL, _ candidate: URL, pointScale: Double, masks: [[Double]], maxDiffPercent: Double
    ) throws -> (diff: ImageDiff, png: Data?) {
        guard let base = rgba(baseline) else {
            return (ImageDiff(verdict: .inconclusive, reason: "\(baseline.lastPathComponent) does not decode as an image."), nil)
        }
        guard let other = rgba(candidate) else {
            return (ImageDiff(verdict: .inconclusive, reason: "\(candidate.lastPathComponent) does not decode as an image."), nil)
        }
        guard base.width == other.width, base.height == other.height else {
            let sizes = "\(base.width)x\(base.height) px vs \(other.width)x\(other.height) px"
            return (ImageDiff(verdict: .inconclusive, reason: "the screenshots differ in size, \(sizes)."), nil)
        }
        let width = base.width
        func pixel(_ points: Double, _ rule: FloatingPointRoundingRule, limit: Int) -> Int {
            Int(min(max((points * pointScale).rounded(rule), 0), Double(limit)))
        }
        let rects = masks.map { mask in
            (
                minX: pixel(mask[0], .down, limit: width), minY: pixel(mask[1], .down, limit: base.height),
                maxX: pixel(mask[0] + mask[2], .up, limit: width), maxY: pixel(mask[1] + mask[3], .up, limit: base.height)
            )
        }
        var diff = ImageDiff(verdict: .same)
        var pixels = [UInt8](repeating: 255, count: base.bytes.count)
        let columns = (width + tile - 1) / tile
        var tiles: [Int: (minX: Int, minY: Int, maxX: Int, maxY: Int)] = [:]
        for y in 0 ..< base.height {
            for x in 0 ..< width {
                let offset = (y * width + x) * 4
                if rects.contains(where: { x >= $0.minX && x < $0.maxX && y >= $0.minY && y < $0.maxY }) {
                    pixels[offset] = 0
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = 96
                    continue
                }
                diff.comparedPixels += 1
                var delta = 0
                for channel in 0 ..< 4 {
                    delta = max(delta, abs(Int(base.bytes[offset + channel]) - Int(other.bytes[offset + channel])))
                }
                if delta > threshold {
                    diff.changedPixels += 1
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = 0
                    let key = (y / tile) * columns + x / tile
                    let box = tiles[key] ?? (x, y, x, y)
                    tiles[key] = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
                } else {
                    for channel in 0 ..< 3 { pixels[offset + channel] = other.bytes[offset + channel] / 4 }
                }
            }
        }
        while let start = tiles.keys.min(), var box = tiles.removeValue(forKey: start) {
            var group = [start]
            while let key = group.popLast() {
                for row in -1 ... 1 {
                    for column in -1 ... 1 where (0 ..< columns).contains(key % columns + column) {
                        guard let next = tiles.removeValue(forKey: key + row * columns + column) else { continue }
                        box = (min(box.minX, next.minX), min(box.minY, next.minY), max(box.maxX, next.maxX), max(box.maxY, next.maxY))
                        group.append(key + row * columns + column)
                    }
                }
            }
            diff.boxes.append(
                [box.minX, box.minY, box.maxX - box.minX + 1, box.maxY - box.minY + 1].map { Double($0) / pointScale })
        }
        if Double(diff.changedPixels) * 100 > maxDiffPercent * Double(diff.comparedPixels) { diff.verdict = .changed }
        return (diff, diff.changedPixels > 0 ? try png(pixels, width: width, height: base.height) : nil)
    }

    /// The pixels of the image at `url` as sRGB RGBA bytes, rows from the top, or nil when it does not decode.
    static func rgba(_ url: URL) -> (width: Int, height: Int, bytes: [UInt8])? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? (image.width, image.height, bytes) : nil
    }

    /// PNG data of sRGB RGBA bytes, rows from the top.
    static func png(_ bytes: [UInt8], width: Int, height: Int) throws -> Data {
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent),
            let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw DeviceLoopError(.internalError, "Could not create the screenshot diff image.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw DeviceLoopError(.internalError, "Could not encode the screenshot diff image.")
        }
        return data as Data
    }
}
