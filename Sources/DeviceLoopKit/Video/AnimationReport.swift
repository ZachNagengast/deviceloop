//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// The JSON summary of one analyzed recording. Times are seconds since the first frame.
struct AnimationReport: Codable, Sendable {
    var schema = "deviceloop.animation/2"
    /// Nil when the recording was deleted after analysis.
    var video: String?
    var recording: Recording
    var action: Action?
    var response: Response?
    var segments: [Segment]
    var cadence: Cadence
    var candidates: Candidates
    /// How an Instruments trace lines up with the video. Nil without a trace.
    var trace: TraceAlignment?
    var thresholds: Thresholds
    var contactSheet: String?
    var warnings: [String]

    struct Recording: Codable, Sendable {
        /// `simctl`, `usb` or `file`.
        var backend: String
        var codec: String
        var width: Int
        var height: Int
        var frames: Int
        var identicalFrames: Int
        var lastFrameAt: Double
        /// Container duration. Simulator recordings report less than the wall time.
        var containerDurationSec: Double
        var wallDurationSec: Double?
        var recorderDrops: Int
        var captureSource: CaptureSource?
        /// How USB frame times reached the host clock: `host` converted from the capture session clock, `arrival`
        /// shifted by the first frame's arrival time. Nil for other backends.
        var clock: String?
        /// Range of arrival time minus timestamp over the frames, with the `arrival` clock.
        var arrivalSpreadMs: Double?
    }

    /// The AVFoundation device a USB recording came from, as provenance. Not a device identity.
    struct CaptureSource: Codable, Sendable, Equatable {
        var uniqueID: String
        var name: String
    }

    struct Action: Codable, Sendable {
        var step: String
        /// `ran` once the step returned.
        var status: String
        var sentAt: Double
        var ackAt: Double
        /// From send to ack. The input lands somewhere inside it.
        var windowMs: Double
        var note: String?
        var reconnect: Reconnect?
    }

    /// A device tunnel address change seen after capture started.
    struct Reconnect: Codable, Sendable {
        var from: String?
        var to: String
        /// Seconds since the first frame when the new address was seen.
        var at: Double
    }

    struct Response: Codable, Sendable {
        var feedback: Feedback?
        /// First change of the transition, after any feedback.
        var firstChangeAt: Double?
        /// From `action.sentAt`, not from the touch.
        var latencyMs: Double?
        /// Duration of the motion segment that starts the transition.
        var animationMs: Double?
        /// Last change after the action.
        var lastChangeAt: Double?
        var lastChangeMs: Double?
        /// No change during the last `observationWindowMs` of the recording. Says nothing about the app being idle.
        var unchangedAtEnd: Bool
        var observationWindowMs: Double
    }

    /// A short, small change split from the larger change after it, such as a touch-down highlight before a push.
    struct Feedback: Codable, Sendable {
        var at: Double
        /// From `action.sentAt`.
        var latencyMs: Double
        /// x, y, width, height of the changed area in source pixels.
        var region: [Int]
    }

    struct Segment: Codable, Sendable {
        var start: Double
        var end: Double
        var durationMs: Double
        /// Changed frames in the segment.
        var frames: Int
        /// Median interval between changed frames.
        var medianIntervalMs: Double?
        var peakAt: Double
        /// x, y, width, height of the changed area in source pixels.
        var region: [Int]
        /// Change per slot normalized to the peak, at most 60 values.
        var energy: [Double]
    }

    struct Cadence: Codable, Sendable {
        var slotMs: Double
        var fps: Double
        /// `measured` from frame timestamps, or `assumed`.
        var fpsSource: String
        /// Gaps shorter than this cannot be seen in this recording.
        var detectionFloorMs: Double
        var medianIntervalMs: Double?
        var intervalHistogramMs: [String: Int]
    }

    /// Visual gap candidates from the video, not native hitch metrics. Totals count only jumps.
    struct Candidates: Codable, Sendable {
        var count: Int
        var jumps: Int
        var totalMs: Double
        /// Visual estimate of jump time per second of motion.
        var visualMsPerMotionSec: Double
        /// Holes with a recorder drop, or with no frames on USB, left out of the counts and totals above.
        var recorderGaps: Int
        /// Time of the first frame after each recorder gap.
        var recorderGapsAt: [Double]
        var items: [Candidate]
    }

    struct Candidate: Codable, Sendable {
        /// Time of the first frame after the hole.
        var at: Double
        var missedSlots: Int
        var durationMs: Double
        /// Frames inside the hole that showed no change.
        var repeatedFrames: Int
        /// `jump` when content caught up after the hole, `delay` when the motion slowed.
        var kind: String
        var catchUpRatio: Double
        var confidence: String
        /// `confirmed`, `notConfirmed`, `inconclusive` or `unavailable` against displayed-surface gaps. Nil without a trace.
        var traceVerdict: String?
        /// The displayed-surface gap that confirmed the candidate, from swap to swap.
        var traceGapMs: Double?
    }

    struct TraceAlignment: Codable, Sendable {
        /// `onset` when the first motion onset matched a displayed-surface swap after a still screen, `clock` otherwise.
        var method: String
        /// Trace seconds at video time zero.
        var offsetSec: Double
        /// Trace seconds at video time zero from the TOC start date and the host clocks alone.
        var clockOffsetSec: Double
        /// Longest distance from a segment start or end or a candidate to the nearest swap. Nil with `clock`.
        var residualMs: Double?
        /// The display with the most swaps. Nil without displayed-surface swaps.
        var display: String?
        /// Median interval between swaps. Gaps are intervals over 1.5 periods.
        var periodMs: Double?
        /// Hitch table rows, times from the start of the trace. Verdicts do not use them.
        var hitches: [TraceSummary.Hitch]?
        /// Displayed-surface gaps that start and end inside a motion segment. Nil without displayed-surface swaps.
        var gaps: [TraceGap]?
        /// The kept trace. Nil when it was deleted after export.
        var file: String?
    }

    struct TraceGap: Codable, Sendable, Equatable {
        /// Video time of the swap before the gap.
        var at: Double
        var durationMs: Double
    }

    struct Thresholds: Codable, Sendable {
        var pixelDelta: Double
        var tileMAD: Double
        var tileFraction: Double
        var mergeGapMs: Double
        var observationWindowMs: Double
        /// x, y, width, height in source pixels of the analyzed area and the ignored areas.
        var region: [Int]?
        var masks: [[Int]]
    }

    /// Compact lines for agents, without the target header.
    var lines: [String] {
        var lines: [String] = []
        let wall = recording.wallDurationSec.map { ", \(text($0))s recorded" } ?? ""
        lines.append(
            "video \(video ?? "not kept") | \(recording.codec) \(recording.width)x\(recording.height) | \(recording.frames) frames\(wall)"
        )
        if thresholds.region != nil || !thresholds.masks.isEmpty {
            let region = thresholds.region.map { "region \(area($0))" }
            let masks = thresholds.masks.isEmpty ? nil : "masks \(thresholds.masks.map(area).joined(separator: " "))"
            lines.append("analyzed " + [region, masks].compactMap { $0 }.joined(separator: ", "))
        }
        if let action {
            lines.append(
                "action \(action.step) at \(text(action.sentAt))s: \(action.status), window \(text(action.windowMs))ms from send to ack"
                    + (action.note.map { ", \($0)" } ?? ""))
            if let reconnect = action.reconnect {
                lines.append("tunnel moved from \(reconnect.from ?? "none") to \(reconnect.to) at \(text(reconnect.at))s")
            }
        }
        if let response {
            if let feedback = response.feedback {
                lines.append("feedback \(text(feedback.at))s (+\(text(feedback.latencyMs))ms from send), region \(box(feedback.region))")
            }
            if let first = response.firstChangeAt, let latency = response.latencyMs {
                var parts = ["response first change \(text(first))s (+\(text(latency))ms from send)"]
                if let animation = response.animationMs { parts.append("animation \(text(animation))ms") }
                if let lastChangeAt = response.lastChangeAt, let lastChange = response.lastChangeMs {
                    parts.append("last change \(text(lastChangeAt))s (+\(text(lastChange))ms)")
                }
                let window = "in the last \(text(response.observationWindowMs)) ms of the recording"
                parts.append(response.unchangedAtEnd ? "no change \(window)" : "changed \(window)")
                lines.append(parts.joined(separator: ", "))
            } else {
                lines.append("response no screen change after the action")
            }
        }
        lines.append(segments.isEmpty ? "motion none" : "segments \(segments.count)")
        for (number, segment) in segments.enumerated() {
            let median = segment.medianIntervalMs.map { ", \(text($0))ms median" } ?? ""
            lines.append(
                "  \(number + 1) \(text(segment.start))-\(text(segment.end))s \(text(segment.durationMs))ms, "
                    + "\(segment.frames) changed frame\(segment.frames == 1 ? "" : "s")\(median), region \(box(segment.region))"
            )
            if segment.energy.count > 1 { lines.append("    energy |\(ramp(segment.energy))|") }
        }
        let common = cadence.intervalHistogramMs.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key)ms x\($0.value)" }
        lines.append(
            "cadence \(text(cadence.slotMs))ms slots (detection floor), \(text(cadence.fps)) fps \(cadence.fpsSource)"
                + (common.isEmpty ? "" : ", intervals " + common.joined(separator: " "))
        )
        let delays = candidates.count - candidates.jumps
        lines.append(
            "gap candidates \(candidates.count), \(candidates.jumps) jump\(candidates.jumps == 1 ? "" : "s") "
                + "\(text(candidates.totalMs))ms total, visual estimate \(text(candidates.visualMsPerMotionSec))ms per motion second, "
                + "\(delays) delay\(delays == 1 ? "" : "s")"
        )
        if let trace {
            var parts = ["trace alignment \(trace.method), offset \(text(trace.offsetSec))s (clock \(text(trace.clockOffsetSec))s)"]
            if let residual = trace.residualMs { parts.append("residual \(text(residual))ms") }
            if let display = trace.display, let period = trace.periodMs {
                parts.append("\(display) \(text(period))ms period")
            } else {
                parts.append("no displayed-surface swaps")
            }
            if let gaps = trace.gaps { parts.append("\(gaps.count) gap\(gaps.count == 1 ? "" : "s") in motion") }
            parts.append(trace.hitches.map { "\($0.count) hitch row\($0.count == 1 ? "" : "s")" } ?? "no hitch table")
            lines.append(parts.joined(separator: ", "))
            if let file = trace.file { lines.append("trace \(file)") }
        }
        if candidates.recorderGaps > 0 {
            let times = candidates.recorderGapsAt.map { "\(text($0))s" }.joined(separator: " ")
            lines.append("recorder gaps \(candidates.recorderGaps) at \(times), left out of the totals")
        }
        let shown = (candidates.items.filter { $0.kind == "jump" } + candidates.items.filter { $0.kind != "jump" }).prefix(8)
        for candidate in shown.sorted(by: { $0.at < $1.at }) {
            var parts = [
                "  \(text(candidate.at))s missed \(candidate.missedSlots) slot\(candidate.missedSlots == 1 ? "" : "s")"
                    + " (\(text(candidate.durationMs))ms)",
                "\(candidate.kind) x\(text(candidate.catchUpRatio))",
                candidate.confidence,
            ]
            if candidate.repeatedFrames > 0 { parts.append("\(candidate.repeatedFrames) repeated") }
            if let verdict = candidate.traceVerdict {
                parts.append("trace \(verdict)" + (candidate.traceGapMs.map { " \(text($0))ms gap" } ?? ""))
            }
            lines.append(parts.joined(separator: ", "))
        }
        if candidates.items.count > shown.count { lines.append("  \(candidates.items.count - shown.count) more in --json") }
        if let contactSheet { lines.append("sheet \(contactSheet)") }
        lines.append(contentsOf: warnings.map { "warning: \($0)" })
        return lines
    }

    private func text(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private func area(_ values: [Int]) -> String {
        values.map(String.init).joined(separator: ",")
    }

    /// x,y wxh.
    private func box(_ values: [Int]) -> String {
        "\(values[0]),\(values[1]) \(values[2])x\(values[3])"
    }

    /// Energy as an ASCII ramp, one character per value.
    private func ramp(_ values: [Double]) -> String {
        let levels = Array(" .:-=+*#%@")
        return String(values.map { levels[min(levels.count - 1, Int(($0 * Double(levels.count - 1)).rounded()))] })
    }
}
