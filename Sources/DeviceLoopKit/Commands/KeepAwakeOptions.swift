//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation

/// Validated point, interval and duration of keep-awake taps.
public struct KeepAwakeOptions: Sendable {
    public let point: WirePoint
    public let intervalMs: Int
    public let durationMs: Int?

    public init(point: WirePoint, intervalMs: Int, durationMs: Int?) throws {
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0 else {
            throw DeviceLoopError.usage("--at must contain finite, nonnegative coordinates in points")
        }
        guard (1_000 ... 3_600_000).contains(intervalMs) else {
            throw DeviceLoopError.usage("Keep-awake interval must be between 1 and 3600 seconds")
        }
        if let durationMs, !(1_000 ... 86_400_000).contains(durationMs) {
            throw DeviceLoopError.usage("Keep-awake duration must be between 1 and 86400 seconds")
        }
        self.point = point
        self.intervalMs = intervalMs
        self.durationMs = durationMs
    }

    /// `seconds` in milliseconds. Throws a usage error naming `option` unless it is 1 to `maximumSeconds`.
    public static func milliseconds(seconds: Int, maximumSeconds: Int, option: String) throws -> Int {
        guard seconds > 0, seconds <= maximumSeconds, seconds <= Int.max / 1000 else {
            throw DeviceLoopError.usage("\(option) must be between 1 and \(maximumSeconds) seconds")
        }
        return seconds * 1000
    }

    /// Throws unless `point` is at least 64 points inside every edge of a `width` by `height` screen. The owner still
    /// picks a point that is inert in the app.
    func validateScreen(width: Double, height: Double) throws {
        let margin = 64.0
        guard width.isFinite, height.isFinite, width > margin * 2, height > margin * 2 else {
            throw DeviceLoopError.usage("Could not determine usable screen bounds for keep-awake taps")
        }
        guard point.x >= margin, point.y >= margin, point.x < width - margin, point.y < height - margin else {
            throw DeviceLoopError.usage("Choose an inert app point at least 64 points from every screen edge")
        }
    }
}

enum KeepAwakeLoop {
    /// Taps every `intervalMs` until `durationMs` passes or `interrupt` is raised, and returns the number of taps.
    /// Cancellation or a failed tap throws without a retry.
    static func run(options: KeepAwakeOptions, interrupt: InterruptFlag, tap: @Sendable () async throws -> Void) async throws -> Int {
        let clock = ContinuousClock()
        let deadline = options.durationMs.map { clock.now.advanced(by: .milliseconds($0)) }
        var taps = 0
        while !interrupt.isRaised {
            try Task.checkCancellation()
            if let deadline, clock.now >= deadline { break }
            try await tap()
            taps += 1
            try Task.checkCancellation()
            let next = clock.now.advanced(by: .milliseconds(options.intervalMs))
            _ = await interrupt.sleep(seconds: clock.now.duration(to: deadline.map { min(next, $0) } ?? next) / .seconds(1))
        }
        return taps
    }
}
