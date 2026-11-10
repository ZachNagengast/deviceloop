//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct TraceTablesTests {
    /// The device in `hitches-toc.xml`, an Animation Hitches trace of a test app recorded on 10/22/26.
    private let device = Target(
        udid: "00008130-000000000000F00D", identifier: "00000000-0000-0000-0000-00000000F00D", name: "iPhone", kind: .device,
        deviceType: "iPhone", platform: "iOS", model: "iPhone 15 Pro Max", productType: "iPhone16,2", osVersion: "27.0",
        connectionState: "connected", bootState: "booted")
    private let trace = URL(filePath: "/tmp/run.trace")

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try #require(Bundle.module.url(forResource: "Resources/xctrace/\(name)", withExtension: "xml")))
    }

    private func summary(_ toc: String, tables schemas: [String]) throws -> TraceSummary {
        var tables: [String: TraceTable] = [:]
        for schema in schemas { tables[schema] = try TraceTable(xml: fixture(schema)) }
        return TraceSummary(toc: try TraceTOC(xml: fixture(toc)), tables: tables, trace: trace, tocFile: URL(filePath: "/tmp/run.toc.xml"))
    }

    @Test func ownershipPassesForTheRecordedDeviceAndProcess() throws {
        try TraceCommands.checkOwner(TraceTOC(xml: fixture("hitches-toc")), target: device, pid: 37027, names: ["Sample"], trace: trace)
    }

    @Test func ownershipFailsForAnotherDevice() throws {
        var other = device
        other.udid = "00008130-000000000000BEEF"
        let toc = try TraceTOC(xml: fixture("hitches-toc"))
        let error = #expect(throws: DeviceLoopError.self) {
            try TraceCommands.checkOwner(toc, target: other, pid: 37027, names: ["Sample"], trace: trace)
        }
        #expect(error?.code == .deviceError)
        #expect(error?.message.contains("on 00008130-000000000000F00D, not Sample (pid 37027) on 00008130-000000000000BEEF") == true)
    }

    @Test func ownershipFailsForAnotherProcess() throws {
        let toc = try TraceTOC(xml: fixture("hitches-toc"))
        #expect(throws: DeviceLoopError.self) {
            try TraceCommands.checkOwner(toc, target: device, pid: 37028, names: ["Sample"], trace: trace)
        }
        #expect(throws: DeviceLoopError.self) {
            try TraceCommands.checkOwner(toc, target: device, pid: 37027, names: ["Settings", "Preferences"], trace: trace)
        }
    }

    @Test func zeroHitchRowsParseToAnEmptyList() throws {
        let summary = try summary("hitches-toc", tables: ["hitches"])
        #expect(summary.hitches == [])
    }

    @Test func refCellsTakeTheValueOfTheElementWithTheirID() throws {
        let rows = try TraceTable(xml: fixture("displayed-surfaces-interval")).rows
        #expect(rows[1]["display-name"]?.fmt == "Built-In Display 1")
        #expect(rows.last?["duration"] == TraceValue(text: "20838042", fmt: "20.84 ms"))
        #expect(rows.last?["event-label"]?.fmt == "Surface 123")
        #expect(rows[0]["cpu-to-display-latency"] == nil)
        let hangs = try TraceTable(xml: fixture("potential-hangs")).rows
        #expect(hangs[1]["process"]?.fmt == "Sample (32817)")
    }

    /// `hitches-settings.xml` is the hitches table of an Animation Hitches trace of Settings recorded on 10/22/26.
    @Test func hitchRowsGiveStartDurationProcessAndIssue() throws {
        let tables = ["hitches": try TraceTable(xml: fixture("hitches-settings"))]
        let summary = TraceSummary(toc: try TraceTOC(xml: fixture("hitches-toc")), tables: tables, trace: trace, tocFile: trace)
        let hitches = try #require(summary.hitches)
        try #require(hitches.count == 4)
        #expect(hitches[0] == TraceSummary.Hitch(startMs: 6303.459, durationMs: 350.077, process: "Preferences (36855)"))
        #expect(
            hitches[2]
                == TraceSummary.Hitch(
                    startMs: 7203.66, durationMs: 16.67, process: "Preferences (36855)", issue: "Potentially expensive app update(s)"))
    }

    @Test func hitchesTraceWithItsTablesGivesAFullSummary() throws {
        let summary = try summary("hitches-toc", tables: TraceSummary.schemas)
        #expect(!summary.partial)
        #expect(summary.template == "Animation Hitches")
        #expect(summary.endReason == "Time limit reached")
        #expect(summary.surfaces == TraceSummary.Intervals(count: 105, longestMs: 1000.224))
    }

    /// `potential-hangs.xml` is from a simulator Time Profiler trace of a test app with 400 ms and 700 ms main thread stalls.
    @Test func potentialHangsGiveCountAndLongest() throws {
        let summary = try summary("hitches-toc", tables: ["potential-hangs"])
        #expect(summary.hangs == TraceSummary.Intervals(count: 2, longestMs: 702.451))
    }

    @Test func otherTemplateGivesAPartialSummaryWithTheTableList() throws {
        let summary = try summary("time-profiler-toc", tables: [])
        #expect(summary.partial)
        #expect(summary.template == "Time Profiler")
        #expect(summary.missing == TraceSummary.schemas)
        #expect(summary.tables.contains("time-profile"))
        #expect(summary.tables.count == Set(summary.tables).count)
    }

    /// `sample-stall-capture.json` is the Oct 22nd report of a `stall=100` move recorded during the `hitches-toc.xml` trace,
    /// converted to schema `deviceloop.animation/2` without its paths.
    private func stallReport() throws -> AnimationReport {
        let url = try #require(Bundle.module.url(forResource: "Resources/xctrace/sample-stall-capture", withExtension: "json"))
        return try JSONDecoder().decode(AnimationReport.self, from: Data(contentsOf: url))
    }

    /// Trace seconds at video time zero from the capture handle time, 23:36:24.753, which precedes the first frame.
    private func handleOffset() throws -> Double {
        let handle = try #require(ISO8601DateFormatter().date(from: "2026-10-22T23:36:24-07:00")).addingTimeInterval(0.753)
        return try #require(try TraceTOC(xml: fixture("hitches-toc")).clockOffset(wall: handle, host: 0, videoStartHost: 0))
    }

    private func stallSwaps() throws -> SurfaceSwaps {
        try #require(SurfaceSwaps(TraceTable(xml: fixture("displayed-surfaces-interval"))))
    }

    @Test func clockOffsetCountsFromTheTOCStartDate() throws {
        let toc = try TraceTOC(xml: fixture("hitches-toc"))
        let wall = try #require(toc.startDate).addingTimeInterval(5)
        let offset = try #require(toc.clockOffset(wall: wall, host: 100, videoStartHost: 101.5))
        #expect(abs(offset - 6.5) < 1e-6)
    }

    @Test func swapsAreDistinctStartTimesOfTheBusiestDisplay() throws {
        let xml = """
            <trace-query-result><node><schema name="displayed-surfaces-interval">
            <col><mnemonic>start</mnemonic></col><col><mnemonic>display-name</mnemonic></col></schema>
            <row><start-time id="1">0</start-time><display-name id="2" fmt="A">A</display-name></row>
            <row><start-time ref="1"/><display-name ref="2"/></row>
            <row><start-time id="3">16670000</start-time><display-name ref="2"/></row>
            <row><start-time ref="3"/><display-name id="4" fmt="B">B</display-name></row>
            </node></trace-query-result>
            """
        let swaps = try #require(SurfaceSwaps(TraceTable(xml: Data(xml.utf8))))
        #expect(swaps.display == "A")
        #expect(swaps.times == [0, 0.01667])
    }

    @Test func recordedStallIsConfirmedByTheDisplayedSurfaceGap() throws {
        var report = try stallReport()
        report.matchTrace(try stallSwaps(), clockOffset: try handleOffset(), hitches: [])
        let trace = try #require(report.trace)
        #expect(trace.method == "onset")
        #expect(trace.offsetSec == 2.6807)
        #expect(trace.clockOffsetSec == 1.203)
        #expect(try #require(trace.residualMs) < report.cadence.slotMs)
        #expect(trace.periodMs == 16.7)
        let candidate = try #require(report.candidates.items.first)
        #expect(candidate.at == 1.533)
        #expect(candidate.traceVerdict == "confirmed")
        #expect(candidate.traceGapMs == 116.7)
    }

    @Test func recordedStallListsOneDisplayedSurfaceGapInMotion() throws {
        var report = try stallReport()
        report.matchTrace(try stallSwaps(), clockOffset: try handleOffset(), hitches: [])
        let gaps = try #require(report.trace?.gaps)
        #expect(gaps.map(\.durationMs) == [116.7])
        #expect(report.lines.contains { $0.contains(", 1 gap in motion, ") })
    }

    @Test func continuousSwapsThroughTheHoleAreNotConfirmed() throws {
        var swaps = try stallSwaps()
        let gap = try #require(swaps.gaps.first { $0.end - $0.start > 0.1 && $0.end - $0.start < 0.2 })
        swaps.times = (swaps.times + stride(from: gap.start + swaps.period, to: gap.end - 0.008, by: swaps.period)).sorted()
        var report = try stallReport()
        report.matchTrace(swaps, clockOffset: try handleOffset(), hitches: [])
        #expect(report.trace?.method == "onset")
        #expect(report.candidates.items.first?.traceVerdict == "notConfirmed")
    }

    /// 4.5 s puts the video onset nearer the trace onset at 5.664 s than the matching one at 3.764 s.
    @Test func clockOffsetNearAnotherOnsetIsInconclusive() throws {
        var report = try stallReport()
        report.matchTrace(try stallSwaps(), clockOffset: 4.5, hitches: [])
        #expect(try #require(report.trace?.residualMs) > report.cadence.slotMs)
        #expect(report.candidates.items.first?.traceVerdict == "inconclusive")
    }

    /// Without the swaps before 3.7 s and after 4.6 s, no swap follows a still screen.
    @Test func unmatchedOnsetIsInconclusiveAtTheRightOffset() throws {
        var swaps = try stallSwaps()
        swaps.times.removeAll { $0 < 3.7 || $0 > 4.6 }
        var report = try stallReport()
        report.matchTrace(swaps, clockOffset: 2.6807, hitches: [])
        #expect(report.trace?.method == "clock")
        #expect(report.candidates.items.first?.traceVerdict == "inconclusive")
    }

    @Test func missingDisplayedSurfacesLeaveCandidatesUnavailable() throws {
        var report = try stallReport()
        report.matchTrace(nil, clockOffset: try handleOffset(), hitches: nil)
        #expect(report.trace?.method == "clock")
        #expect(report.candidates.items.first?.traceVerdict == "unavailable")
    }

    @Test func reportLinesShowTheAlignmentAndVerdict() throws {
        var report = try stallReport()
        report.matchTrace(try stallSwaps(), clockOffset: try handleOffset(), hitches: [])
        let lines = report.lines
        #expect(
            lines.contains {
                $0.hasPrefix("trace alignment onset, offset 2.6807s (clock 1.203s), residual ") && $0.hasSuffix(", 0 hitch rows")
            })
        #expect(lines.contains { $0.contains("1.533s missed 6 slots") && $0.hasSuffix("trace confirmed 116.7ms gap") })
    }
}
