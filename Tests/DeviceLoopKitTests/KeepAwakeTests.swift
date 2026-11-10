//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct KeepAwakeTests {
    @Test func rejectsNonfiniteAndNegativePoints() {
        for point in [WirePoint(x: .nan, y: 200), WirePoint(x: 200, y: .infinity), WirePoint(x: -1, y: 200)] {
            #expect(throws: DeviceLoopError.self) {
                try KeepAwakeOptions(point: point, intervalMs: 25_000, durationMs: nil)
            }
        }
    }

    @Test func rejectsUnboundedAndNonpositiveTiming() {
        for interval in [Int.min, 0, 999, 3_600_001, Int.max] {
            #expect(throws: DeviceLoopError.self) {
                try KeepAwakeOptions(point: WirePoint(x: 200, y: 200), intervalMs: interval, durationMs: nil)
            }
        }
        for duration in [Int.min, 0, 999, 86_400_001, Int.max] {
            #expect(throws: DeviceLoopError.self) {
                try KeepAwakeOptions(point: WirePoint(x: 200, y: 200), intervalMs: 25_000, durationMs: duration)
            }
        }
    }

    @Test func secondsConversionCannotOverflow() throws {
        #expect(throws: DeviceLoopError.self) {
            try KeepAwakeOptions.milliseconds(seconds: Int.max, maximumSeconds: Int.max, option: "--for")
        }
        let converted = try KeepAwakeOptions.milliseconds(seconds: 25, maximumSeconds: 3600, option: "--interval")
        #expect(converted == 25_000)
    }

    @Test func rejectsEveryScreenEdge() throws {
        for point in [WirePoint(x: 2, y: 200), WirePoint(x: 200, y: 2), WirePoint(x: 399, y: 200), WirePoint(x: 200, y: 799)] {
            let options = try KeepAwakeOptions(point: point, intervalMs: 25_000, durationMs: nil)
            #expect(throws: DeviceLoopError.self) { try options.validateScreen(width: 400, height: 800) }
        }
        let interior = try KeepAwakeOptions(point: WirePoint(x: 200, y: 200), intervalMs: 25_000, durationMs: nil)
        try interior.validateScreen(width: 400, height: 800)
        #expect(throws: DeviceLoopError.self) { try interior.validateScreen(width: .nan, height: 800) }
    }

    @Test func unknownInputOutcomeIsNotRetriedOrReportedAsSuccess() async throws {
        let options = try KeepAwakeOptions(point: WirePoint(x: 200, y: 200), intervalMs: 25_000, durationMs: nil)
        let attempts = Attempts()
        let interrupt = InterruptFlag()
        defer { interrupt.remove() }
        do {
            _ = try await KeepAwakeLoop.run(options: options, interrupt: interrupt) {
                await attempts.record()
                throw DeviceLoopError(.actionOutcomeUnknown, "Response lost")
            }
            Issue.record("An uncertain input must fail keep-awake")
        } catch let error as DeviceLoopError {
            #expect(error.code == .actionOutcomeUnknown)
        }
        #expect(await attempts.count == 1)
    }

    @Test func cancellationDuringSleepStopsBeforeAnotherTap() async throws {
        let options = try KeepAwakeOptions(point: WirePoint(x: 200, y: 200), intervalMs: 25_000, durationMs: nil)
        let attempts = Attempts()
        let interrupt = InterruptFlag()
        defer { interrupt.remove() }
        let worker = Task { try await KeepAwakeLoop.run(options: options, interrupt: interrupt) { await attempts.record() } }
        for _ in 0 ..< 100 {
            if await attempts.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        worker.cancel()
        do {
            _ = try await worker.value
            Issue.record("Cancellation must not return a successful keep-awake result")
        } catch is CancellationError {}
        #expect(await attempts.count == 1)
    }

    @Test func deadlineStopsBeforeTheNextInterval() async throws {
        let options = try KeepAwakeOptions(point: WirePoint(x: 200, y: 200), intervalMs: 25_000, durationMs: 1_000)
        let attempts = Attempts()
        let interrupt = InterruptFlag()
        defer { interrupt.remove() }
        let start = ContinuousClock.now
        let count = try await KeepAwakeLoop.run(options: options, interrupt: interrupt) { await attempts.record() }
        #expect(count == 1)
        #expect(await attempts.count == 1)
        #expect(start.duration(to: .now) < .seconds(5))
    }

    @Test func interruptStopsBeforeTheNextTapAndReturnsTheTaps() async throws {
        let options = try KeepAwakeOptions(point: WirePoint(x: 200, y: 200), intervalMs: 25_000, durationMs: nil)
        let attempts = Attempts()
        let interrupt = InterruptFlag()
        defer { interrupt.remove() }
        let start = ContinuousClock.now
        let count = try await KeepAwakeLoop.run(options: options, interrupt: interrupt) {
            await attempts.record()
            interrupt.raise()
        }
        #expect(count == 1)
        #expect(await attempts.count == 1)
        #expect(start.duration(to: .now) < .seconds(5))
    }

    private actor Attempts {
        var count = 0
        func record() { count += 1 }
    }
}
