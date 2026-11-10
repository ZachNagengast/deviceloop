//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import AVFoundation
import Accelerate
import Foundation

/// Turns a screen recording into motion segments, response timing, cadence and visual gap candidates.
enum VideoAnalyzer {
    struct Options: Sendable {
        /// Video time of the action, in seconds since the first frame.
        var actionAt: Double?
        /// Video time when recording stopped. Simulators write no frames while the screen is still.
        var endAt: Double?
        var backend = "file"
        var simulator = false
        /// Display or recorder rate when the backend is known. Estimated from the recording otherwise.
        var refreshHz: Double?
        /// True when `refreshHz` comes from frame timestamps.
        var refreshMeasured = false
        /// Video times where the recorder dropped frames before they reached the file.
        var recorderDrops: [Double] = []
        var captureSource: AnimationReport.CaptureSource?
        /// `host` or `arrival` for USB recordings.
        var clock: String?
        /// Range of arrival time minus timestamp in seconds, with the `arrival` clock.
        var arrivalSpread: Double?
        var observationWindow = 0.3
        /// Area to analyze in source pixels. The whole frame when nil.
        var region: CGRect?
        /// Areas to ignore in source pixels.
        var masks: [CGRect] = []
    }

    struct Frame: Sendable {
        var index: Int
        /// Seconds since the first frame.
        var time: Double
        /// Mean absolute luma difference to the previous frame over unmasked tiles, 0 to 255.
        var meanAbsDiff: Float
        var changedTiles: [Int]
        var changed: Bool { !changedTiles.isEmpty }
    }

    struct Result: Sendable {
        var report: AnimationReport
        var frames: [Frame]
        /// Presentation time of the first frame in the asset timeline.
        var firstPTS: Double
        /// Frames on either side of each gap candidate.
        var candidateFrames: Set<Int>
        /// First frame of each change that follows feedback.
        var transitionStarts: [Int]
        /// Union of all changed tiles in source pixels, top-left origin.
        var changedRegion: CGRect?
        var sourceSize: CGSize
        var transformIsIdentity: Bool
    }

    static let analysisWidth = 320
    static let tileSize = 16
    static let pixelDelta: Float = 12
    static let maxHoleSlots = 6
    /// Segments whose changes are at least this many slots apart are stepped animations.
    static let minStepSlots = 3
    /// Feedback, such as a touch-down highlight, spans at most this many slots before a hole.
    static let maxFeedbackSlots = 3
    /// Feedback peak slot energy is at most this fraction of the median slot energy of the change after the hole.
    static let feedbackEnergyRatio = 0.25
    /// Feedback changes at most this fraction of the tiles that the change after the hole changes.
    static let feedbackAreaRatio = 0.25

    static func analyze(_ url: URL, options: Options = Options()) async throws -> Result {
        let decoded = try await decode(url)
        var grid = decoded.grid
        try grid.restrict(to: options.region, masks: options.masks)
        let quietUntil = options.actionAt ?? 0.3
        let thresholds = calibrate(decoded.frames, grid: grid, quietUntil: quietUntil)
        let frames = decoded.frames.enumerated().map { index, raw in
            let changed = grid.unmasked.filter {
                raw.tileMAD[$0] >= thresholds.mad || raw.tileFraction[$0] >= thresholds.fraction
            }
            let mad = grid.unmasked.reduce(Float(0)) { $0 + raw.tileMAD[$1] } / Float(max(grid.unmasked.count, 1))
            return Frame(index: index, time: raw.time, meanAbsDiff: mad, changedTiles: index == 0 ? [] : changed)
        }

        let intervals = zip(frames.dropFirst(), frames).map { $0.time - $1.time }
        let medianInterval = median(intervals)
        let mergeGap = max(0.25, 3 * (medianInterval ?? 0))
        let merged = segments(frames, mergeGap: mergeGap)
        let estimatedSlot = slotSeconds(frames, segments: merged)
        let slot = options.refreshHz.map { 1 / $0 } ?? estimatedSlot ?? 1.0 / 60
        let slotMeasured = options.refreshHz == nil ? estimatedSlot != nil : options.refreshMeasured
        let repeatsStillFrames = options.backend == "usb"
        let (segmentRanges, feedback) = splitFeedback(frames, segments: merged, slot: slot, repeatsStillFrames: repeatsStillFrames)
        let described = segmentRanges.map { describe($0, frames: frames, grid: grid, slot: slot) }
        let quietDiff = median(frames.dropFirst().filter { $0.time < quietUntil }.map { Double($0.meanAbsDiff) }) ?? 0
        let (found, recorderGaps) = candidates(
            frames, segments: segmentRanges, slot: slot, drops: options.recorderDrops, repeatsStillFrames: repeatsStillFrames,
            quietDiff: quietDiff)

        let lastFrameAt = frames.last?.time ?? 0
        let endAt = options.endAt ?? max(lastFrameAt, decoded.info.containerDuration)
        var warnings: [String] = []
        if options.simulator { warnings.append("simulator timing is not device timing") }
        if slot > 1.0 / 60 + 0.001 {
            warnings.append("recording cadence of \(String(format: "%g", ms(slot))) ms hides shorter gaps")
        }
        if options.clock == "arrival" {
            let spread = options.arrivalSpread.map { ", arrival lag varied by \(String(format: "%g", ms($0))) ms" } ?? ""
            warnings.append("frame times are aligned by arrival, not by the capture clock\(spread)")
        }
        if decoded.skippedFrames > 0 {
            warnings.append("\(decoded.skippedFrames) frames changed size mid-recording (rotation) and were skipped")
        }

        var response: AnimationReport.Response?
        if let actionAt = options.actionAt {
            let lastChange = frames.last { $0.changed && $0.time >= actionAt }
            var firstChange = frames.first { $0.changed && $0.time >= actionAt }
            var position = firstChange.flatMap { first in segmentRanges.firstIndex { $0.contains(first.index) } }
            var responseFeedback: AnimationReport.Feedback?
            if let first = firstChange, let current = position, feedback.contains(current) {
                responseFeedback = AnimationReport.Feedback(
                    at: seconds(first.time), latencyMs: ms(first.time - actionAt), region: described[current].region)
                position = current + 1
                firstChange = frames[segmentRanges[current + 1].lowerBound]
            }
            let responseSegment = position.map { segmentRanges[$0] }
            let quiet = endAt - (lastChange?.time ?? actionAt)
            response = AnimationReport.Response(
                feedback: responseFeedback,
                firstChangeAt: firstChange.map { seconds($0.time) },
                latencyMs: firstChange.map { ms($0.time - actionAt) },
                animationMs: responseSegment.map { ms(frames[$0.upperBound].time - frames[$0.lowerBound].time) },
                lastChangeAt: lastChange.map { seconds($0.time) },
                lastChangeMs: lastChange.map { ms($0.time - actionAt) },
                unchangedAtEnd: quiet >= options.observationWindow,
                observationWindowMs: ms(options.observationWindow)
            )
            if quiet < options.observationWindow {
                warnings.append("screen was still changing when recording stopped, retry with a longer wait")
            }
        }

        let motionSeconds = segmentRanges.reduce(0) { $0 + frames[$1.upperBound].time - frames[$1.lowerBound].time }
        let jumps = found.map(\.item).filter { $0.kind == "jump" }
        let totalJumpMs = jumps.reduce(0) { $0 + $1.durationMs }
        let ratio = motionSeconds > 0 ? totalJumpMs / motionSeconds : 0
        let report = AnimationReport(
            video: url.path,
            recording: AnimationReport.Recording(
                backend: options.backend,
                codec: decoded.info.codec,
                width: decoded.info.width,
                height: decoded.info.height,
                frames: frames.count,
                identicalFrames: frames.dropFirst().filter { !$0.changed && $0.meanAbsDiff < 0.05 }.count,
                lastFrameAt: seconds(lastFrameAt),
                containerDurationSec: seconds(decoded.info.containerDuration),
                wallDurationSec: options.endAt.map(seconds),
                recorderDrops: options.recorderDrops.count,
                captureSource: options.captureSource,
                clock: options.clock,
                arrivalSpreadMs: options.arrivalSpread.map(ms)
            ),
            response: response,
            segments: described,
            cadence: AnimationReport.Cadence(
                slotMs: ms(slot),
                fps: (10 / slot).rounded() / 10,
                fpsSource: slotMeasured ? "measured" : "assumed",
                detectionFloorMs: ms(slot),
                medianIntervalMs: medianInterval.map(ms),
                intervalHistogramMs: histogram(intervals)
            ),
            candidates: AnimationReport.Candidates(
                count: found.count,
                jumps: jumps.count,
                totalMs: (totalJumpMs * 10).rounded() / 10,
                visualMsPerMotionSec: (ratio * 10).rounded() / 10,
                recorderGaps: recorderGaps.count,
                recorderGapsAt: recorderGaps,
                items: found.map(\.item)
            ),
            thresholds: AnimationReport.Thresholds(
                pixelDelta: Double(pixelDelta),
                tileMAD: (Double(thresholds.mad) * 100).rounded() / 100,
                tileFraction: (Double(thresholds.fraction) * 1000).rounded() / 1000,
                mergeGapMs: ms(mergeGap),
                observationWindowMs: ms(options.observationWindow),
                region: options.region.map(pixels),
                masks: options.masks.map(pixels)
            ),
            warnings: warnings
        )

        let changedTiles = Set(frames.flatMap(\.changedTiles))
        return Result(
            report: report,
            frames: frames,
            firstPTS: decoded.info.firstPTS,
            candidateFrames: Set(found.flatMap { [$0.before, $0.after] }),
            transitionStarts: feedback.map { segmentRanges[$0 + 1].lowerBound },
            changedRegion: changedTiles.isEmpty ? nil : grid.sourceRect(of: changedTiles),
            sourceSize: CGSize(width: decoded.info.width, height: decoded.info.height),
            transformIsIdentity: decoded.info.transformIsIdentity
        )
    }

    struct Info {
        var codec: String
        var width: Int
        var height: Int
        var containerDuration: Double
        var firstPTS: Double
        var transformIsIdentity: Bool
    }

    struct RawFrame {
        var time: Double
        var tileMAD: [Float]
        var tileFraction: [Float]
    }

    /// The analysis raster: the luma plane scaled to 320 px wide and cut into 16 px tiles.
    struct Grid {
        var width: Int
        var height: Int
        var columns: Int
        var rows: Int
        var sourceWidth: Int
        var sourceHeight: Int
        /// Tiles outside the status bar and home indicator bands.
        var unmasked: [Int]

        init(sourceWidth: Int, sourceHeight: Int) {
            self.sourceWidth = sourceWidth
            self.sourceHeight = sourceHeight
            width = VideoAnalyzer.analysisWidth
            let scaledHeight = Double(sourceHeight) * Double(width) / Double(max(sourceWidth, 1))
            rows = max(1, Int((scaledHeight / Double(VideoAnalyzer.tileSize)).rounded()))
            height = rows * VideoAnalyzer.tileSize
            columns = width / VideoAnalyzer.tileSize
            // Fixed bands stand in for the status bar (top 6%) and home indicator (bottom 4%).
            let rows = rows
            let columns = columns
            unmasked = (0 ..< rows).filter { row in
                let center = (Double(row) + 0.5) / Double(rows)
                return center >= 0.06 && center <= 0.96
            }.flatMap { row in (0 ..< columns).map { row * columns + $0 } }
        }

        /// Keeps the unmasked tiles that overlap `region` and none of `masks`. Throws when an area leaves the frame
        /// or no tile is left.
        mutating func restrict(to region: CGRect?, masks: [CGRect]) throws {
            let frame = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
            if let outside = ([region].compactMap { $0 } + masks).first(where: { !frame.contains($0) }) {
                throw DeviceLoopError(
                    .badArguments,
                    "The area \(VideoAnalyzer.pixels(outside).map(String.init).joined(separator: ",")) is outside the "
                        + "\(sourceWidth)x\(sourceHeight) source frame.",
                    fix: "Pass x,y,w,h in source pixels within 0,0,\(sourceWidth),\(sourceHeight)."
                )
            }
            unmasked = unmasked.filter { tile in
                let rect = sourceRect(of: [tile])
                return (region.map { rect.intersects($0) } ?? true) && !masks.contains { rect.intersects($0) }
            }
            if unmasked.isEmpty {
                throw DeviceLoopError(
                    .badArguments,
                    "The region and masks leave nothing to analyze. The top 6% and bottom 4% of the frame are not analyzed.",
                    fix: "Pass a region below the status bar and above the home indicator, or fewer masks."
                )
            }
        }

        /// Bounding box of `tiles` in source pixels.
        func sourceRect(of tiles: Set<Int>) -> CGRect {
            let columnsUsed = tiles.map { $0 % columns }
            let rowsUsed = tiles.map { $0 / columns }
            let scaleX = Double(sourceWidth) / Double(width)
            let scaleY = Double(sourceHeight) / Double(height)
            let tile = Double(VideoAnalyzer.tileSize)
            let minX = Double(columnsUsed.min() ?? 0) * tile * scaleX
            let maxX = Double((columnsUsed.max() ?? 0) + 1) * tile * scaleX
            let minY = Double(rowsUsed.min() ?? 0) * tile * scaleY
            let maxY = Double((rowsUsed.max() ?? 0) + 1) * tile * scaleY
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).integral
        }
    }

    static func decode(_ url: URL) async throws -> (info: Info, grid: Grid, frames: [RawFrame], skippedFrames: Int) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DeviceLoopError(.badArguments, "No video at \(url.path).", fix: "Pass the path of an MP4 or MOV file.")
        }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw DeviceLoopError(
                .badArguments, "\(url.lastPathComponent) has no readable video track.", fix: "Pass an MP4 or MOV screen recording.")
        }
        let (formats, transform) = try await track.load(.formatDescriptions, .preferredTransform)
        let duration = try await asset.load(.duration)
        let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown"

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw DeviceLoopError(.internalError, "Could not decode \(url.lastPathComponent).", detail: reader.error.map { "\($0)" })
        }

        var grid: Grid?
        var firstPTS: Double?
        var frames: [RawFrame] = []
        var skipped = 0
        var luma: [UInt8] = []
        var current: [Float] = []
        var previous: [Float] = []
        var difference: [Float] = []
        var overThreshold: [Float] = []
        var rowSums: [Float] = []
        let ones = [Float](repeating: 1, count: tileSize)

        while let sample = output.copyNextSampleBuffer() {
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            CVPixelBufferLockBaseAddress(image, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            let width = CVPixelBufferGetWidthOfPlane(image, 0)
            let height = CVPixelBufferGetHeightOfPlane(image, 0)
            if grid == nil {
                let created = Grid(sourceWidth: width, sourceHeight: height)
                grid = created
                firstPTS = pts
                luma = [UInt8](repeating: 0, count: created.width * created.height)
                current = [Float](repeating: 0, count: luma.count)
                previous = current
                difference = current
                overThreshold = current
                rowSums = [Float](repeating: 0, count: created.height * created.columns)
            }
            guard let grid, let origin = firstPTS, width == grid.sourceWidth, height == grid.sourceHeight else {
                skipped += 1
                continue
            }

            var source = vImage_Buffer(
                data: CVPixelBufferGetBaseAddressOfPlane(image, 0),
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: CVPixelBufferGetBytesPerRowOfPlane(image, 0)
            )
            luma.withUnsafeMutableBytes { bytes in
                var destination = vImage_Buffer(
                    data: bytes.baseAddress,
                    height: vImagePixelCount(grid.height),
                    width: vImagePixelCount(grid.width),
                    rowBytes: grid.width
                )
                _ = vImageScale_Planar8(&source, &destination, nil, vImage_Flags(kvImageNoFlags))
            }
            vDSP.convertElements(of: luma, to: &current)

            if frames.isEmpty {
                let zeros = [Float](repeating: 0, count: grid.rows * grid.columns)
                frames.append(RawFrame(time: pts - origin, tileMAD: zeros, tileFraction: zeros))
            } else {
                vDSP.subtract(current, previous, result: &difference)
                vDSP.absolute(difference, result: &difference)
                vDSP.add(-pixelDelta, difference, result: &overThreshold)
                vDSP.clip(overThreshold, to: 0 ... 1, result: &overThreshold)
                let area = Float(tileSize * tileSize)
                frames.append(
                    RawFrame(
                        time: pts - origin,
                        tileMAD: vDSP.divide(tileSums(difference, grid: grid, ones: ones, rowSums: &rowSums), area),
                        tileFraction: vDSP.divide(tileSums(overThreshold, grid: grid, ones: ones, rowSums: &rowSums), area)
                    )
                )
            }
            swap(&previous, &current)
        }
        if reader.status == .failed {
            throw DeviceLoopError(.internalError, "Decoding \(url.lastPathComponent) failed.", detail: reader.error.map { "\($0)" })
        }
        guard let grid, let firstPTS else {
            throw DeviceLoopError(
                .badArguments, "\(url.lastPathComponent) has no video frames.", fix: "Record again and make sure the screen is on.")
        }
        let info = Info(
            codec: codec,
            width: grid.sourceWidth,
            height: grid.sourceHeight,
            containerDuration: duration.seconds,
            firstPTS: firstPTS,
            transformIsIdentity: transform.isIdentity
        )
        return (info, grid, frames, skipped)
    }

    /// Sums `values` (one per analysis pixel, row-major) over each 16x16 tile.
    static func tileSums(_ values: [Float], grid: Grid, ones: [Float], rowSums: inout [Float]) -> [Float] {
        let size = vDSP_Length(tileSize)
        vDSP_mmul(values, 1, ones, 1, &rowSums, 1, vDSP_Length(grid.height * grid.columns), 1, size)
        var tiles = [Float](repeating: 0, count: grid.rows * grid.columns)
        rowSums.withUnsafeBufferPointer { rows in
            tiles.withUnsafeMutableBufferPointer { tilePointer in
                for row in 0 ..< grid.rows {
                    vDSP_mmul(
                        ones, 1,
                        rows.baseAddress! + row * tileSize * grid.columns, 1,
                        tilePointer.baseAddress! + row * grid.columns, 1,
                        1, vDSP_Length(grid.columns), size
                    )
                }
            }
        }
        return tiles
    }

    /// Tile thresholds from the quiet frames before `quietUntil`: 3x the median over frames of each frame's p99
    /// tile value, clamped to 3...10 for MAD and 0.08...0.5 for the changed-pixel fraction.
    static func calibrate(_ frames: [RawFrame], grid: Grid, quietUntil: Double) -> (mad: Float, fraction: Float) {
        let quiet = frames.dropFirst().filter { $0.time < quietUntil }
        let madFloor = median(quiet.map { frame in Double(percentile(grid.unmasked.map { frame.tileMAD[$0] }, 0.99)) }) ?? 0
        let fractionFloor = median(quiet.map { frame in Double(percentile(grid.unmasked.map { frame.tileFraction[$0] }, 0.99)) }) ?? 0
        return (
            mad: Float(min(10, max(3, 3 * madFloor))),
            fraction: Float(min(0.5, max(0.08, 3 * fractionFloor)))
        )
    }

    /// Changed frames grouped into motion segments, as closed index ranges into `frames`.
    static func segments(_ frames: [Frame], mergeGap: Double) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        for frame in frames where frame.changed {
            if let last = ranges.last, frame.time - frames[last.upperBound].time <= mergeGap {
                ranges[ranges.count - 1] = last.lowerBound ... frame.index
            } else {
                ranges.append(frame.index ... frame.index)
            }
        }
        return ranges
    }

    /// Splits feedback off the start of segments. Returns the segments and the positions of the feedback segments,
    /// each followed by the change after its hole.
    static func splitFeedback(
        _ frames: [Frame], segments: [ClosedRange<Int>], slot: Double, repeatsStillFrames: Bool
    ) -> (segments: [ClosedRange<Int>], feedback: [Int]) {
        var split: [ClosedRange<Int>] = []
        var feedback: [Int] = []
        for range in segments {
            if let hole = feedbackHole(frames, range: range, slot: slot, repeatsStillFrames: repeatsStillFrames) {
                feedback.append(split.count)
                split += [range.lowerBound ... hole.lowerBound, hole.upperBound ... range.upperBound]
            } else {
                split.append(range)
            }
        }
        return (split, feedback)
    }

    /// The last feedback frame and the first frame after the hole, when the segment starts with a run of at most
    /// `maxFeedbackSlots` slots that is weak and small next to the change after it. A hole with no frames on USB is a
    /// recorder gap, not feedback.
    static func feedbackHole(
        _ frames: [Frame], range: ClosedRange<Int>, slot: Double, repeatsStillFrames: Bool
    ) -> ClosedRange<Int>? {
        let changed = range.filter { frames[$0].changed }
        let origin = frames[range.lowerBound].time
        let slots = changed.map { Int(((frames[$0].time - origin) / slot).rounded()) }
        guard let hole = slots.indices.dropFirst().first(where: { slots[$0] - slots[$0 - 1] > 1 }),
            slots[hole - 1] < maxFeedbackSlots, !repeatsStillFrames || changed[hole] - changed[hole - 1] > 1
        else { return nil }
        var energy: [Int: Double] = [:]
        for (slotIndex, index) in zip(slots, changed) { energy[slotIndex, default: 0] += Double(frames[index].meanAbsDiff) }
        let leadPeak = energy.filter { $0.key < slots[hole] }.values.max() ?? 0
        let restMedian = median(energy.filter { $0.key >= slots[hole] }.map(\.value)) ?? 0
        let leadTiles = Set(changed[..<hole].flatMap { frames[$0].changedTiles }).count
        let restTiles = Set(changed[hole...].flatMap { frames[$0].changedTiles }).count
        guard leadPeak <= feedbackEnergyRatio * restMedian, Double(leadTiles) <= feedbackAreaRatio * Double(restTiles) else {
            return nil
        }
        return changed[hole - 1] ... changed[hole]
    }

    /// Slot from the frame intervals during motion, or nil with too few. Simulator bursts 3 to 5 ms apart fall inside
    /// one 60 Hz slot.
    static func slotSeconds(_ frames: [Frame], segments: [ClosedRange<Int>]) -> Double? {
        snappedSlot(segments.flatMap { range in range.dropFirst().map { frames[$0].time - frames[$0 - 1].time } })
    }

    /// The median of `intervals` snapped to 60, 30, 24, 15 or 10 Hz, or nil with fewer than 5 intervals.
    static func snappedSlot(_ intervals: [Double]) -> Double? {
        guard intervals.count >= 5, let interval = median(intervals), interval > 0 else { return nil }
        let rates: [Double] = [60, 30, 24, 15, 10]
        return rates.min { abs(log(interval * $0)) < abs(log(interval * $1)) }.map { 1 / $0 }
    }

    struct FoundCandidate {
        var item: AnimationReport.Candidate
        var before: Int
        var after: Int
    }

    /// Holes of unchanged slots between changed slots of one segment: 1 to 6 slots, or longer when the content was
    /// moving into the hole and catches up after it. Holes that hold a recorder drop, or no frames on USB, are recorder gaps.
    /// `quietDiff` is the median frame difference of the quiet frames before the action.
    static func candidates(
        _ frames: [Frame], segments: [ClosedRange<Int>], slot: Double, drops: [Double], repeatsStillFrames: Bool = false,
        quietDiff: Double = 0
    ) -> (found: [FoundCandidate], recorderGaps: [Double]) {
        var found: [FoundCandidate] = []
        var recorderGaps: [Double] = []
        for range in segments {
            let origin = frames[range.lowerBound].time
            var slotEnergy: [Int: Float] = [:]
            var slotFrames: [Int: [Int]] = [:]
            for index in range where frames[index].changed {
                let slotIndex = Int(((frames[index].time - origin) / slot).rounded())
                slotEnergy[slotIndex, default: 0] += frames[index].meanAbsDiff
                slotFrames[slotIndex, default: []].append(index)
            }
            let changedSlots = slotEnergy.keys.sorted()
            guard changedSlots.count >= 3 else { continue }
            let typical = max(median(changedSlots.map { Double(slotEnergy[$0]!) }) ?? 0, 0.001)
            let typicalFrame = median(range.filter { frames[$0].changed }.map { Double(frames[$0].meanAbsDiff) }) ?? 0
            let step = median(zip(changedSlots.dropFirst(), changedSlots).map { Double($0 - $1) }) ?? 1
            for (previous, next) in zip(changedSlots, changedSlots.dropFirst()) {
                guard next - previous > 1 else { continue }
                let before = slotFrames[previous]!.last!
                let after = slotFrames[next]!.first!
                let repeatedFrames = after - before - 1
                if drops.contains(where: { $0 > frames[before].time && $0 < frames[after].time })
                    || (repeatsStillFrames && repeatedFrames == 0)
                {
                    recorderGaps.append(seconds(frames[after].time))
                    continue
                }
                // A stepped animation holds still for up to its usual step between changes, and misses only the slots past it.
                let missed = next - previous - (step >= Double(minStepSlots) ? Int(step) : 1)
                guard missed >= 1 else { continue }
                // Hole frames that changed by half the typical frame change or more hold motion under the tile thresholds.
                let holeFrames = frames[before + 1 ..< after]
                if !holeFrames.isEmpty
                    && holeFrames.allSatisfy({ Double($0.meanAbsDiff) - quietDiff >= 0.5 * (typicalFrame - quietDiff) })
                {
                    continue
                }
                let ratio = Double(slotEnergy[next]!) / typical
                // Skips ease-out tails, where the change after the hole is under half the typical change.
                guard ratio >= 0.5 else { continue }
                let jumped = ratio >= 1.5
                let wasMoving = Double(slotEnergy[previous]!) >= 0.5 * typical
                // A longer hole that does not interrupt one motion is a pause between motions.
                guard missed <= maxHoleSlots || (jumped && wasMoving) else { continue }
                found.append(
                    FoundCandidate(
                        item: AnimationReport.Candidate(
                            at: seconds(frames[after].time),
                            missedSlots: missed,
                            durationMs: ms(Double(missed) * slot),
                            repeatedFrames: repeatedFrames,
                            kind: jumped ? "jump" : "delay",
                            catchUpRatio: (ratio * 10).rounded() / 10,
                            confidence: jumped ? "high" : "medium"
                        ),
                        before: before,
                        after: after
                    )
                )
            }
        }
        return (found, recorderGaps)
    }

    static func describe(_ range: ClosedRange<Int>, frames: [Frame], grid: Grid, slot: Double) -> AnimationReport.Segment {
        let start = frames[range.lowerBound].time
        let end = frames[range.upperBound].time
        let changed = range.map { frames[$0] }.filter(\.changed)
        let intervals = zip(changed.dropFirst(), changed).map { $0.time - $1.time }
        let peak = changed.max { $0.meanAbsDiff < $1.meanAbsDiff } ?? frames[range.lowerBound]

        var energy = [Double](repeating: 0, count: Int(((end - start) / slot).rounded()) + 1)
        for frame in changed {
            energy[min(energy.count - 1, Int(((frame.time - start) / slot).rounded()))] += Double(frame.meanAbsDiff)
        }
        let binSize = Int((Double(energy.count) / 60).rounded(.up))
        energy = stride(from: 0, to: energy.count, by: binSize).map { energy[$0 ..< min($0 + binSize, energy.count)].max() ?? 0 }
        let top = max(energy.max() ?? 0, 0.001)
        let region = grid.sourceRect(of: Set(changed.flatMap(\.changedTiles)))

        return AnimationReport.Segment(
            start: seconds(start),
            end: seconds(end),
            durationMs: ms(end - start),
            frames: changed.count,
            medianIntervalMs: median(intervals).map(ms),
            peakAt: seconds(peak.time),
            region: pixels(region),
            energy: energy.map { ($0 / top * 100).rounded() / 100 }
        )
    }

    /// Frame intervals rounded to 1/600 s, the 8 most common, keyed by milliseconds.
    static func histogram(_ intervals: [Double]) -> [String: Int] {
        let counts = Dictionary(grouping: intervals) { ($0 * 600).rounded() }.mapValues(\.count)
        let top = counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(8)
        return Dictionary(uniqueKeysWithValues: top.map { (String(format: "%.1f", $0.key / 0.6), $0.value) })
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func percentile(_ values: [Float], _ fraction: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    /// x, y, width and height as whole pixels.
    static func pixels(_ rect: CGRect) -> [Int] { [Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height)] }

    static func seconds(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    static func ms(_ value: Double) -> Double { (value * 10_000).rounded() / 10 }

    static func fourCC(_ code: FourCharCode) -> String {
        let characters = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xff))) }
        return String(characters).trimmingCharacters(in: .whitespaces)
    }
}
