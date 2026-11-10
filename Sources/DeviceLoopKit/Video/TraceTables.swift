//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// The recording facts in `xctrace export --toc` output, from its first run.
struct TraceTOC: Sendable {
    var device: String?
    /// The attached process.
    var processName: String?
    var pid: Int32?
    var template: String?
    var startDate: Date?
    var durationSec: Double?
    var endReason: String?
    /// Table schemas in TOC order, each once.
    var schemas: [String]

    init(xml: Data) throws {
        let document = try XMLDocument(data: xml)
        func element(_ path: String) throws -> XMLElement? {
            try document.nodes(forXPath: "/trace-toc/run[1]/\(path)").first as? XMLElement
        }
        let target = try element("info/target")
        device = target?.elements(forName: "device").first?.attribute(forName: "uuid")?.stringValue
        let process = target?.elements(forName: "process").first
        processName = process?.attribute(forName: "name")?.stringValue
        pid = process?.attribute(forName: "pid")?.stringValue.flatMap { Int32($0) }
        template = try element("info/summary/template-name")?.stringValue
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        startDate = try element("info/summary/start-date")?.stringValue.flatMap { formatter.date(from: $0) }
        durationSec = try element("info/summary/duration")?.stringValue.flatMap { Double($0) }
        endReason = try element("info/summary/end-reason")?.stringValue
        var seen: Set<String> = []
        schemas = try document.nodes(forXPath: "/trace-toc/run[1]/data/table/@schema").compactMap(\.stringValue)
            .filter { seen.insert($0).inserted }
    }

    /// Trace seconds at video time zero, taking `startDate` as trace time zero. `wall` and `host` are read together, and
    /// `videoStartHost` is the first video frame on the same host clock.
    func clockOffset(wall: Date, host: Double, videoStartHost: Double) -> Double? {
        startDate.map { wall.addingTimeInterval(videoStartHost - host).timeIntervalSince($0) }
    }
}

/// One cell of an exported table.
struct TraceValue: Sendable, Equatable {
    /// Element text, nanoseconds for times and durations.
    var text: String
    /// xctrace's display string, for example `16.67 ms`.
    var fmt: String?

    var milliseconds: Double? { Double(text).map { $0 / 1e6 } }
}

/// One table from `xctrace export --xpath`, with each `ref` cell replaced by the value of the element whose `id` it names.
struct TraceTable: Sendable {
    /// Column mnemonics in schema order.
    var columns: [String]
    /// Cells keyed by mnemonic. Sentinel cells are left out.
    var rows: [[String: TraceValue]]

    init(xml: Data) throws {
        let document = try XMLDocument(data: xml)
        let columns = try document.nodes(forXPath: "//schema/col/mnemonic").compactMap(\.stringValue)
        self.columns = columns
        var values: [String: TraceValue] = [:]
        for case let element as XMLElement in try document.nodes(forXPath: "//row//*[@id]") {
            guard let id = element.attribute(forName: "id")?.stringValue else { continue }
            values[id] = TraceValue(text: element.stringValue ?? "", fmt: element.attribute(forName: "fmt")?.stringValue)
        }
        rows = try document.nodes(forXPath: "//row").map { row in
            var cells: [String: TraceValue] = [:]
            for (column, cell) in zip(columns, (row as? XMLElement)?.children?.compactMap { $0 as? XMLElement } ?? []) {
                guard cell.name != "sentinel" else { continue }
                if let ref = cell.attribute(forName: "ref")?.stringValue {
                    guard let value = values[ref] else {
                        throw DeviceLoopError(.internalError, "xctrace table row refers to missing id \(ref).")
                    }
                    cells[column] = value
                } else {
                    cells[column] = TraceValue(text: cell.stringValue ?? "", fmt: cell.attribute(forName: "fmt")?.stringValue)
                }
            }
            return cells
        }
    }
}

/// The `deviceloop.trace/1` summary written next to a trace.
struct TraceSummary: Codable, Sendable {
    static let hitchesTemplate = "Animation Hitches"
    /// The tables the summary reads.
    static let schemas = ["hitches", "potential-hangs", "displayed-surfaces-interval"]

    var schema = "deviceloop.trace/1"
    var trace: String
    var toc: String
    var template: String?
    var durationSec: Double?
    var endReason: String?
    /// True for templates other than Animation Hitches and when one of `schemas` is missing.
    var partial: Bool
    /// Tables of `schemas` the trace lacks or that did not parse.
    var missing: [String]
    var hitches: [Hitch]?
    var hangs: Intervals?
    var surfaces: Intervals?
    /// Every table schema in the trace, for `xcrun xctrace export --xpath`.
    var tables: [String]

    /// Times are milliseconds from the start of the trace.
    struct Hitch: Codable, Sendable, Equatable {
        var startMs: Double
        var durationMs: Double
        var process: String?
        var issue: String?
    }

    struct Intervals: Codable, Sendable, Equatable {
        var count: Int
        var longestMs: Double?
    }

    /// `tables` holds the exported tables by schema.
    init(toc: TraceTOC, tables: [String: TraceTable], trace: URL, tocFile: URL) {
        func timed(_ schema: String) -> TraceTable? {
            tables[schema].flatMap { Set($0.columns).isSuperset(of: ["start", "duration"]) ? $0 : nil }
        }
        func intervals(_ table: TraceTable) -> Intervals {
            Intervals(count: table.rows.count, longestMs: table.rows.compactMap { $0["duration"]?.milliseconds }.max().map(Self.rounded))
        }
        self.trace = trace.path
        self.toc = tocFile.path
        template = toc.template
        durationSec = toc.durationSec
        endReason = toc.endReason
        hitches = timed("hitches")?.rows.compactMap { row in
            guard let start = row["start"]?.milliseconds, let duration = row["duration"]?.milliseconds else { return nil }
            return Hitch(
                startMs: Self.rounded(start), durationMs: Self.rounded(duration), process: row["process"]?.fmt,
                issue: row["narrative-description"]?.fmt)
        }
        hangs = timed("potential-hangs").map(intervals)
        surfaces = timed("displayed-surfaces-interval").map(intervals)
        missing = Self.schemas.filter { timed($0) == nil }
        partial = toc.template != Self.hitchesTemplate || !missing.isEmpty
        self.tables = toc.schemas
    }

    private static func rounded(_ milliseconds: Double) -> Double {
        (milliseconds * 1000).rounded() / 1000
    }
}

/// Distinct displayed-surface swap times of one display, in seconds from the start of the trace.
struct SurfaceSwaps: Sendable {
    var display: String
    /// Sorted, at least two.
    var times: [Double]

    /// Median interval between swaps.
    var period: Double { VideoAnalyzer.median(zip(times.dropFirst(), times).map { $0 - $1 }) ?? 0 }

    /// Swaps that follow at least `quiet` seconds without a swap.
    func onsets(quiet: Double) -> [Double] {
        zip(times.dropFirst(), times).filter { $0 - $1 >= quiet }.map(\.0)
    }

    /// Intervals between swaps longer than 1.5 periods.
    var gaps: [(start: Double, end: Double)] {
        let period = period
        return zip(times, times.dropFirst()).filter { $1 - $0 > 1.5 * period }.map { (start: $0, end: $1) }
    }
}

extension SurfaceSwaps {
    /// The display with the most distinct swaps in a displayed-surfaces-interval table. Nil with fewer than two swaps.
    init?(_ table: TraceTable) {
        var starts: [String: Set<Double>] = [:]
        for row in table.rows {
            guard let start = row["start"].flatMap({ Double($0.text) }) else { continue }
            starts[row["display-name"]?.fmt ?? "", default: []].insert(start / 1e9)
        }
        guard let busiest = starts.max(by: { $0.value.count < $1.value.count }), busiest.value.count >= 2 else { return nil }
        self.init(display: busiest.key, times: busiest.value.sorted())
    }
}

extension AnimationReport {
    /// Aligns `swaps` to the video and marks each candidate `confirmed`, `notConfirmed`, `inconclusive` or `unavailable`.
    /// `clockOffset` is the trace time at video time zero from the clocks. `hitches` are kept as rows only.
    mutating func matchTrace(_ swaps: SurfaceSwaps?, clockOffset: Double, hitches: [TraceSummary.Hitch]?) {
        let slot = cadence.slotMs / 1000
        let quiet = thresholds.mergeGapMs / 1000
        var offset = clockOffset
        var alignment = TraceAlignment(
            method: "clock", offsetSec: 0, clockOffsetSec: Self.rounded(clockOffset), display: swaps?.display,
            periodMs: swaps.map { VideoAnalyzer.ms($0.period) }, hitches: hitches)
        if let swaps, let onset = segments.first(where: { $0.start >= quiet })?.start,
            let matched = swaps.onsets(quiet: quiet).min(by: { abs($0 - onset - offset) < abs($1 - onset - offset) })
        {
            offset = matched - onset
            let anchors = segments.flatMap { [$0.start, $0.end] } + candidates.items.map(\.at)
            let distances = anchors.map { anchor in swaps.times.map { abs($0 - anchor - offset) }.min() ?? .infinity }
            alignment.method = "onset"
            alignment.residualMs = distances.max().map(VideoAnalyzer.ms)
        }
        alignment.offsetSec = Self.rounded(offset)
        alignment.gaps = swaps?.gaps.map { (start: $0.start - offset, end: $0.end - offset) }
            .filter { gap in segments.contains { $0.start <= gap.start && gap.end <= $0.end } }
            .map { TraceGap(at: Self.rounded($0.start), durationMs: VideoAnalyzer.ms($0.end - $0.start)) }
        for index in candidates.items.indices {
            let candidate = candidates.items[index]
            guard let swaps else {
                candidates.items[index].traceVerdict = "unavailable"
                continue
            }
            let end = candidate.at + offset
            let start = end - Double(candidate.missedSlots + 1) * slot
            guard let residual = alignment.residualMs, residual <= cadence.slotMs, swaps.times[0] <= start,
                end <= swaps.times[swaps.times.count - 1]
            else {
                candidates.items[index].traceVerdict = "inconclusive"
                continue
            }
            let overlapping = swaps.gaps.filter { $0.start < end && $0.end > start }
            if let gap = overlapping.first(where: { min($0.end, end) - max($0.start, start) >= 0.8 * candidate.durationMs / 1000 }) {
                candidates.items[index].traceVerdict = "confirmed"
                candidates.items[index].traceGapMs = VideoAnalyzer.ms(gap.end - gap.start)
            } else {
                candidates.items[index].traceVerdict = overlapping.isEmpty ? "notConfirmed" : "inconclusive"
            }
        }
        trace = alignment
    }

    /// Seconds rounded to 0.1 ms.
    private static func rounded(_ seconds: Double) -> Double { (seconds * 10_000).rounded() / 10_000 }
}
