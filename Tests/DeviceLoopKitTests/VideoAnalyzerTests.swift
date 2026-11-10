//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import AVFoundation
import Foundation
import ImageIO
import Testing

@testable import DeviceLoopKit

@Suite(.serialized) struct VideoAnalyzerTests {
    /// Box x positions for a time-based animation: still until frame 20, then 4 px per frame until frame 60.
    static func movingBox(frames: Int = 80) -> [Int?] {
        (0 ..< frames).map { 40 + 4 * min(max(0, $0 - 20), 40) }
    }

    /// The moving box with no frames written at frame 30 and at frames 45 to 47.
    static func frameLessHoles() -> [Int?] {
        var positions = movingBox()
        positions[30] = nil
        for index in 45 ... 47 { positions[index] = nil }
        return positions
    }

    /// Box x positions still through frame 26, then moving `step` px per frame to x 192, for a 128 px box.
    static func moveAfterHighlight(step: Int = 8) -> [Int?] {
        (0 ..< 80).map { min(max(0, $0 - 26) * step, 192) }
    }

    /// A 16 px highlight lit for frame 20 only, which changes frames 20 and 21 before a 5-frame hole.
    static let highlight = (area: CGRect(x: 240, y: 96, width: 16, height: 16), frames: 20 ..< 21)

    /// Writes a synthetic video, analyzes it and deletes it.
    func analyze(
        _ positions: [Int?],
        boxSize: Int = 64,
        boxTops: [Int]? = nil,
        noise: Int = 0,
        cursor: CGRect? = nil,
        flash: (area: CGRect, frames: Range<Int>)? = nil,
        scale: Int = 1,
        options: VideoAnalyzer.Options = VideoAnalyzer.Options()
    ) async throws -> AnimationReport {
        let video = try await SyntheticVideo.write(
            boxAt: positions, boxSize: boxSize, boxTops: boxTops, noise: noise, cursor: cursor, flash: flash, scale: scale)
        defer { try? FileManager.default.removeItem(at: video) }
        return try await VideoAnalyzer.analyze(video, options: options).report
    }

    @Test func continuousMotionIsOneSegmentWithoutCandidates() async throws {
        let report = try await analyze(Self.movingBox())

        let segment = try #require(report.segments.first)
        #expect(report.segments.count == 1)
        #expect(abs(segment.start - 21.0 / 60) < 0.002)
        #expect(abs(segment.end - 60.0 / 60) < 0.002)
        #expect(report.cadence.slotMs == 16.7)
        #expect(report.candidates.count == 0)
    }

    @Test func repeatedAndMissingFramesAreCandidates() async throws {
        var positions = Self.movingBox()
        positions[30] = positions[29]
        positions[45] = nil
        positions[46] = nil
        let candidates = try await analyze(positions).candidates.items

        #expect(candidates.count == 2)
        let repeated = try #require(candidates.first)
        #expect(repeated.missedSlots == 1)
        #expect(repeated.repeatedFrames == 1)
        #expect(repeated.kind == "jump")
        #expect(abs(repeated.catchUpRatio - 2) < 0.3)
        let missing = try #require(candidates.last)
        #expect(missing.missedSlots == 2)
        #expect(missing.durationMs == 33.3)
        #expect(missing.repeatedFrames == 0)
        #expect(abs(missing.catchUpRatio - 3) < 0.4)
    }

    @Test func halfRateAnimationOnA60HzRecorderIsDelaysNotJumps() async throws {
        let positions: [Int?] = (0 ..< 80).map { 40 + 4 * (min(max(0, $0 - 20), 40) / 2) }
        var options = VideoAnalyzer.Options()
        options.refreshHz = 60
        let candidates = try await analyze(positions, options: options).candidates

        #expect(candidates.count > 0)
        #expect(candidates.jumps == 0)
        #expect(candidates.visualMsPerMotionSec == 0)
    }

    @Test func freezeLongerThanSixSlotsThatCatchesUpIsACandidate() async throws {
        var positions = Self.movingBox()
        for index in 30 ..< 42 { positions[index] = positions[29] }
        let candidate = try #require(try await analyze(positions).candidates.items.first)

        #expect(candidate.missedSlots == 12)
        #expect(candidate.repeatedFrames == 12)
        #expect(candidate.kind == "jump")
    }

    @Test func longGapWithoutFramesInAUSBRecordingIsNotACandidate() async throws {
        var positions = Self.movingBox()
        for index in 30 ..< 42 { positions[index] = nil }
        var options = VideoAnalyzer.Options()
        options.backend = "usb"
        #expect(try await analyze(positions, options: options).candidates.count == 0)
    }

    @Test func frameLessHolesInAUSBRecordingAreRecorderGaps() async throws {
        var options = VideoAnalyzer.Options()
        options.backend = "usb"
        let candidates = try await analyze(Self.frameLessHoles(), options: options).candidates

        #expect(candidates.count == 0)
        #expect(candidates.recorderGaps == 2)
        #expect(candidates.recorderGapsAt == [0.517, 0.8])
    }

    @Test func frameLessHolesInAFileAreCandidates() async throws {
        let candidates = try await analyze(Self.frameLessHoles()).candidates

        #expect(candidates.count == 2)
        #expect(candidates.recorderGaps == 0)
    }

    @Test func repeatedFrameHoleInAUSBRecordingIsACandidate() async throws {
        var positions = Self.movingBox()
        positions[30] = positions[29]
        var options = VideoAnalyzer.Options()
        options.backend = "usb"
        let candidates = try await analyze(positions, options: options).candidates

        #expect(candidates.count == 1)
        #expect(candidates.recorderGaps == 0)
    }

    @Test func holeWithARecorderDropIsLeftOutOfTheTotals() async throws {
        var positions = Self.movingBox()
        positions[30] = positions[29]
        var options = VideoAnalyzer.Options()
        options.backend = "usb"
        options.recorderDrops = [0.5]
        let candidates = try await analyze(positions, options: options).candidates

        #expect(candidates.count == 0)
        #expect(candidates.totalMs == 0)
        #expect(candidates.recorderGaps == 1)
    }

    @Test func holdThatResumesAtTheSameSpeedIsNotACandidate() async throws {
        let positions: [Int?] = (0 ..< 80).map { index in
            switch index {
                case ..<20: return 40 + 4 * index
                case ..<30: return 120
                default: return 120 + 4 * (index - 30)
            }
        }
        #expect(try await analyze(positions).candidates.count == 0)
    }

    @Test func pauseBetweenTwoEaseOutMovesIsNotACandidate() async throws {
        var x = 40
        var positions: [Int?] = Array(repeating: x, count: 20)
        for _ in 0 ..< 2 {
            for step in [8, 7, 6, 5, 4, 3, 2, 1] {
                x += step
                positions.append(x)
            }
            positions += Array(repeating: x, count: 10)
        }
        #expect(try await analyze(positions).candidates.count == 0)
    }

    @Test func pauseLongerThanMergeGapSplitsSegments() async throws {
        let positions: [Int?] = (0 ..< 90).map { index in
            switch index {
                case ..<20: return 40 + 4 * index
                case ..<50: return 120
                default: return 120 + 4 * (index - 50)
            }
        }
        let report = try await analyze(positions)

        #expect(report.segments.count == 2)
        #expect(report.candidates.count == 0)
    }

    @Test func gapsWithoutFramesBetweenMotionsAreNotCandidates() async throws {
        var positions: [Int?] = (0 ..< 80).map { 40 + 4 * max(0, $0 - 60) }
        for index in 1 ..< 60 { positions[index] = nil }
        let report = try await analyze(positions)

        #expect(report.segments.count == 1)
        #expect(abs((report.segments.first?.start ?? 0) - 61.0 / 60) < 0.002)
        #expect(report.candidates.count == 0)
    }

    @Test func smallChangeIsMotion() async throws {
        let positions: [Int?] = (0 ..< 60).map { 100 + 2 * max(0, $0 - 30) }
        let report = try await analyze(positions, boxSize: 8)

        #expect(report.segments.count == 1)
    }

    @Test func noisyStillVideoHasNoMotion() async throws {
        let report = try await analyze([Int?](repeating: 100, count: 60), noise: 6)

        #expect(report.segments.isEmpty)
        #expect(report.thresholds.tileMAD > 3)
    }

    @Test func responseIsTimedFromTheAction() async throws {
        var options = VideoAnalyzer.Options()
        options.actionAt = 0.25
        options.endAt = 2
        let response = try #require(try await analyze(Self.movingBox(), options: options).response)

        #expect(response.latencyMs == 100)
        #expect(response.animationMs == 650)
        #expect(response.unchangedAtEnd)
    }

    @Test func quietEndReadsAsNoChangeInTheObservationWindow() async throws {
        var options = VideoAnalyzer.Options()
        options.actionAt = 0.25
        options.endAt = 2
        let report = try await analyze(Self.movingBox(), options: options)

        #expect(report.lines.contains { $0.hasSuffix(", no change in the last 300 ms of the recording") })
    }

    @Test func motionUpToTheStopChangesInTheObservationWindow() async throws {
        var options = VideoAnalyzer.Options()
        options.actionAt = 0.25
        options.endAt = 1.05
        let report = try await analyze(Self.movingBox(frames: 60), options: options)

        #expect(report.response?.unchangedAtEnd == false)
        #expect(report.warnings.contains { $0.contains("still changing") })
    }

    @Test func maskedBoxLeavesOneSegmentInTheOtherBoxRegion() async throws {
        var options = VideoAnalyzer.Options()
        options.masks = [CGRect(x: 0, y: 400, width: 320, height: 160)]
        let report = try await analyze(Self.movingBox(), boxTops: [128, 448], options: options)

        #expect(report.segments.count == 1)
        #expect(report.segments.first?.region == [32, 128, 240, 64])
        #expect(report.thresholds.masks == [[0, 400, 320, 160]])
    }

    @Test func regionAwayFromMotionHasNoMotion() async throws {
        var options = VideoAnalyzer.Options()
        options.region = CGRect(x: 0, y: 40, width: 320, height: 80)
        let report = try await analyze(Self.movingBox(), options: options)

        #expect(report.segments.isEmpty)
        #expect(report.lines.contains("motion none"))
        #expect(report.thresholds.region == [0, 40, 320, 80])
    }

    @Test func regionOutsideTheFrameIsRejected() async throws {
        var options = VideoAnalyzer.Options()
        options.region = CGRect(x: 0, y: 600, width: 320, height: 100)
        let error = await #expect(throws: DeviceLoopError.self) { try await analyze(Self.movingBox(frames: 30), options: options) }

        #expect(error?.code == .badArguments)
    }

    @Test func regionInsideTheStatusBarBandIsRejected() async throws {
        var options = VideoAnalyzer.Options()
        options.region = CGRect(x: 0, y: 0, width: 320, height: 30)
        let error = await #expect(throws: DeviceLoopError.self) { try await analyze(Self.movingBox(frames: 30), options: options) }

        #expect(error?.code == .badArguments)
    }

    @Test func blinkingCursorInsideAMaskIsNoMotion() async throws {
        var options = VideoAnalyzer.Options()
        options.masks = [CGRect(x: 32, y: 96, width: 64, height: 64)]
        let report = try await analyze(
            [Int?](repeating: 100, count: 180), cursor: CGRect(x: 60, y: 112, width: 4, height: 32), options: options)

        #expect(report.segments.isEmpty)
        #expect(report.candidates.count == 0)
    }

    @Test func slowMoveOfOneSourcePixelPerFrameHasNoCandidates() async throws {
        let positions: [Int?] = (0 ..< 280).map { 400 + min(max(0, $0 - 20), 240) }
        let report = try await analyze(positions, boxSize: 256, scale: 4)

        #expect(report.segments.count == 1)
        #expect(report.candidates.count == 0)
    }

    @Test func steppedMoveAt10FPSHasNoCandidates() async throws {
        let positions: [Int?] = (0 ..< 160).map { 40 + 8 * (min(max(0, $0 - 20), 120) / 6) }
        let report = try await analyze(positions)

        #expect(report.segments.count == 1)
        #expect(report.candidates.count == 0)
    }

    @Test func heldStepInA10FPSMoveReportsTheExtraDelay() async throws {
        var positions: [Int?] = (0 ..< 160).map { 40 + 8 * (min(max(0, $0 - 20), 120) / 6) }
        positions.insert(contentsOf: Array(repeating: positions[61], count: 6), at: 62)
        let candidates = try await analyze(positions).candidates.items

        #expect(candidates.count == 1)
        #expect(candidates.first?.missedSlots == 6)
        #expect(candidates.first?.durationMs == 100)
    }

    @Test func repeatedFrameInANoisyRecordingIsACandidate() async throws {
        var positions = Self.movingBox(frames: 40)
        positions[30] = positions[29]
        let candidates = try await analyze(positions, noise: 6).candidates

        #expect(candidates.count == 1)
    }

    @Test func tapFeedbackIsSplitFromTheTransition() async throws {
        var options = VideoAnalyzer.Options()
        options.actionAt = 0.25
        options.endAt = 2
        let report = try await analyze(Self.moveAfterHighlight(), boxSize: 128, flash: Self.highlight, options: options)
        let response = try #require(report.response)
        let feedback = try #require(response.feedback)

        #expect(feedback.at == 0.333)
        #expect(feedback.latencyMs == 83.3)
        #expect(feedback.region == [240, 96, 16, 16])
        #expect(response.firstChangeAt == 0.45)
        #expect(response.latencyMs == 200)
        #expect(response.animationMs == 383.3)
        #expect(report.segments.count == 2)
        #expect(report.candidates.count == 0)
        #expect(report.lines.contains("feedback 0.333s (+83.3ms from send), region 240,96 16x16"))
    }

    @Test func holeWithoutFramesAfterAHighlightInAUSBRecordingIsARecorderGap() async throws {
        var positions = Self.moveAfterHighlight()
        for index in 22 ... 26 { positions[index] = nil }
        var options = VideoAnalyzer.Options()
        options.actionAt = 0.25
        options.backend = "usb"
        let report = try await analyze(positions, boxSize: 128, flash: Self.highlight, options: options)

        #expect(report.response?.feedback == nil)
        #expect(report.candidates.recorderGaps == 1)
    }

    @Test func contactSheetShowsTheFirstFrameAfterFeedback() async throws {
        let video = try await SyntheticVideo.write(boxAt: Self.moveAfterHighlight(step: 4), boxSize: 128, flash: Self.highlight)
        defer { try? FileManager.default.removeItem(at: video) }
        var options = VideoAnalyzer.Options()
        options.actionAt = 0.25
        let result = try await VideoAnalyzer.analyze(video, options: options)
        let cells = ContactSheet.cells(for: result, actionAt: 0.25)

        #expect(result.transitionStarts == [27])
        #expect(cells.contains { $0.label.hasPrefix("#27 ") })
    }

    @Test func contactSheetFitsTheImageLimitAndMarksCandidates() async throws {
        var positions = Self.movingBox()
        positions[30] = positions[29]
        let video = try await SyntheticVideo.write(boxAt: positions)
        defer { try? FileManager.default.removeItem(at: video) }
        let result = try await VideoAnalyzer.analyze(video)
        let cells = ContactSheet.cells(for: result, actionAt: nil)
        let png = try await ContactSheet.render(video, cells: cells, firstPTS: result.firstPTS, crop: ContactSheet.crop(for: result))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        #expect(cells.count <= ContactSheet.maxCells)
        #expect(cells.filter(\.highlight).count == 2)
        #expect(max(image.width, image.height) <= Int(ContactSheet.maxEdge))
    }
}

/// Writes 60 fps H.264 test videos of a light box on a dark background.
enum SyntheticVideo {
    static let width = 320
    static let height = 640

    /// One frame per entry with a box at that x position for each of `boxTops`, one centered box by default.
    /// Nil writes no frame for that slot. `cursor` is lit for the first 30 of every 60 frames, and `flash` for its frames.
    /// `scale` multiplies the frame size, and positions and sizes are in the scaled pixels.
    static func write(
        boxAt positions: [Int?], boxSize: Int = 64, boxTops: [Int]? = nil, noise: Int = 0, cursor: CGRect? = nil,
        flash: (area: CGRect, frames: Range<Int>)? = nil, scale: Int = 1
    ) async throws -> URL {
        let width = width * scale
        let height = height * scale
        let url = FileManager.default.temporaryDirectory.appending(path: "deviceloop-test-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000],
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for (index, position) in positions.enumerated() {
            guard let position else { continue }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            let pool = try #require(adaptor.pixelBufferPool)
            var created: CVPixelBuffer?
            var status = kCVReturnSuccess
            for _ in 0 ..< 5 {
                status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
                if status == kCVReturnSuccess { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let buffer = try #require(created, "CVPixelBufferPoolCreatePixelBuffer returned \(status)")
            CVPixelBufferLockBaseAddress(buffer, [])
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let pixels = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let tops = boxTops ?? [(height - boxSize) / 2]
            let lit = [index % 60 < 30 ? cursor : nil, flash.flatMap { $0.frames.contains(index) ? $0.area : nil }].compactMap { $0 }
            for y in 0 ..< height {
                let row = pixels + y * rowBytes
                memset(row, 60, width * 4)
                if tops.contains(where: { ($0 ..< $0 + boxSize).contains(y) }) {
                    memset(row + position * 4, 220, boxSize * 4)
                }
                for area in lit where (Int(area.minY) ..< Int(area.maxY)).contains(y) {
                    memset(row + Int(area.minX) * 4, 220, Int(area.width) * 4)
                }
                if noise > 0 {
                    for x in 0 ..< width {
                        let value = UInt8(clamping: Int(row[x * 4]) + Int.random(in: -noise ... noise))
                        row[x * 4] = value
                        row[x * 4 + 1] = value
                        row[x * 4 + 2] = value
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index * 10), timescale: 600)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }
}
