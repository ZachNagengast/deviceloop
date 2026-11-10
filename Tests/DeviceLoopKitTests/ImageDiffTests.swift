//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct ImageDiffTests {
    /// Writes a gray PNG of `width` by `height` pixels with white `blocks` of x, y, width and height in pixels, and returns
    /// its path in `folder`.
    static func png(
        _ name: String, in folder: URL, width: Int = 120, height: Int = 80, blocks: [[Int]] = [], gray: UInt8 = 60
    ) throws -> URL {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let white = blocks.contains { x >= $0[0] && x < $0[0] + $0[2] && y >= $0[1] && y < $0[1] + $0[3] }
                for channel in 0 ..< 3 { bytes[(y * width + x) * 4 + channel] = white ? 255 : gray }
            }
        }
        let url = folder.appending(path: name)
        try ImageDiff.png(bytes, width: width, height: height).write(to: url)
        return url
    }

    /// Runs `body` with a new temporary folder, then removes it.
    static func folder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "deviceloop-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    @Test func changedBlockIsFoundWithItsBoxInPoints() throws {
        try Self.folder { folder in
            let baseline = try Self.png("a.png", in: folder)
            let candidate = try Self.png("b.png", in: folder, blocks: [[40, 20, 10, 10]])
            let (diff, png) = try ImageDiff.compare(baseline, candidate, pointScale: 2, masks: [], maxDiffPercent: 0.1)
            #expect(diff.verdict == .changed)
            #expect(diff.changedPixels == 100)
            #expect(diff.comparedPixels == 9600)
            #expect(diff.boxes == [[20, 10, 5, 5]])
            #expect(diff.line == "screenshot changed: 1.042% of unmasked pixels, 100 of 9600, in [20,10,5,5]")
            #expect(png != nil)
        }
    }

    @Test func changeInsideAMaskIsSame() throws {
        try Self.folder { folder in
            let baseline = try Self.png("a.png", in: folder)
            let candidate = try Self.png("b.png", in: folder, blocks: [[40, 20, 10, 10]])
            let (diff, png) = try ImageDiff.compare(baseline, candidate, pointScale: 2, masks: [[18, 8, 9, 9]], maxDiffPercent: 0.1)
            #expect(diff.verdict == .same)
            #expect(diff.changedPixels == 0)
            #expect(diff.comparedPixels == 9600 - 18 * 18)
            #expect(png == nil)
        }
    }

    @Test func maskFarBeyondTheImageCoversIt() throws {
        try Self.folder { folder in
            let baseline = try Self.png("a.png", in: folder)
            let candidate = try Self.png("b.png", in: folder, blocks: [[40, 20, 10, 10]])
            let masks = [[-1e20, -1e20, 1e30, 1e30]]
            let diff = try ImageDiff.compare(baseline, candidate, pointScale: 3, masks: masks, maxDiffPercent: 0.1).diff
            #expect(diff.verdict == .same)
            #expect(diff.comparedPixels == 0)
        }
    }

    @Test func differentPixelSizesAreInconclusive() throws {
        try Self.folder { folder in
            let baseline = try Self.png("a.png", in: folder)
            let candidate = try Self.png("b.png", in: folder, width: 80, height: 120)
            let (diff, png) = try ImageDiff.compare(baseline, candidate, pointScale: 2, masks: [], maxDiffPercent: 0.1)
            #expect(diff.verdict == .inconclusive)
            #expect(diff.reason == "the screenshots differ in size, 120x80 px vs 80x120 px.")
            #expect(png == nil)
        }
    }

    @Test func changeUpToMaxDiffIsSameButKeepsItsBox() throws {
        try Self.folder { folder in
            let baseline = try Self.png("a.png", in: folder)
            let candidate = try Self.png("b.png", in: folder, blocks: [[0, 0, 3, 3]])
            let (diff, png) = try ImageDiff.compare(baseline, candidate, pointScale: 1, masks: [], maxDiffPercent: 0.1)
            #expect(diff.verdict == .same)
            #expect(diff.boxes == [[0, 0, 3, 3]])
            #expect(png != nil)
        }
    }

    @Test(arguments: [(76 as UInt8, 0), (77, 9600)])
    func pixelChangesOnlyAboveTheThreshold(gray: UInt8, changed: Int) throws {
        try Self.folder { folder in
            let baseline = try Self.png("a.png", in: folder)
            let candidate = try Self.png("b.png", in: folder, gray: gray)
            #expect(try ImageDiff.compare(baseline, candidate, pointScale: 1, masks: [], maxDiffPercent: 0.1).diff.changedPixels == changed)
        }
    }

    @Test func blocksInTilesThatDoNotTouchGetTheirOwnBoxes() throws {
        try Self.folder { folder in
            let baseline = try Self.png("a.png", in: folder)
            let candidate = try Self.png("b.png", in: folder, blocks: [[100, 2, 4, 4], [2, 60, 6, 6], [30, 62, 4, 4]])
            let diff = try ImageDiff.compare(baseline, candidate, pointScale: 1, masks: [], maxDiffPercent: 0.1).diff
            #expect(diff.boxes == [[100, 2, 4, 4], [2, 60, 32, 6]])
        }
    }
}
