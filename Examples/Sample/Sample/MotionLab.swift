//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import QuartzCore
import SwiftUI

/// Moves the Motion card with a random timing curve and logs each move to Documents/trials.jsonl and stdout.
/// `deviceloop-sample://move?style=linear&stall=100` also blocks the main thread for 100 ms at 40 percent of the move.
/// `driver=frames` moves linearly and recomputes the position on the main thread every frame.
/// `to=0.2,0.8` ends the move at fractions of the area the card can occupy, and `duration=2000` sets its length in ms.
/// `deviceloop-sample://static` changes nothing and logs the time.
/// `deviceloop-sample://marker?interval=500&count=10` fills the screen with the label color on display-link frames
/// `interval` ms apart, for 100 ms or half the interval, and logs each flash with the frame's target time.
@MainActor @Observable
final class MotionLab {
    struct FrameMove {
        let from: CGPoint
        let to: CGPoint
        let start: Date
        let duration: Double
    }

    static let side: CGFloat = 88
    static let defaultDurationMs = 800.0
    static let trialsURL = URL.documentsDirectory.appending(path: "trials.jsonl")

    /// Card center as a fraction of the area it can occupy, so it stays on screen when the window resizes.
    var spot = CGPoint(x: 0.5, y: 0.5)
    private(set) var frameMove: FrameMove?
    private(set) var flashing = false
    private var area = CGRect.zero
    private var isMoving = false
    private var markerRunning = false
    private var pendingMove: URL?
    private var trial = (try? String(contentsOf: trialsURL, encoding: .utf8))?.split(separator: "\n").count ?? 0

    /// Runs a `deviceloop-sample://` link and returns true for a move, which needs the Motion tab. A move that arrives
    /// before `MotionView` reports its area waits for it, and another move meanwhile is ignored.
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "deviceloop-sample" else { return false }
        switch url.host() {
            case "move":
                if area.width >= Self.side, area.height >= Self.side {
                    run(url)
                } else if pendingMove == nil {
                    pendingMove = url
                } else {
                    FileHandle.standardError.write(Data("sample: ignored \(url), a move is waiting for the Motion tab\n".utf8))
                }
                return true
            case "static", "marker":
                run(url)
                return false
            default:
                return false
        }
    }

    /// Records the area the card moves in, in window points, and runs a move that arrived before it was known.
    func layout(_ frame: CGRect) {
        area = frame
        if let url = pendingMove, frame.width >= Self.side, frame.height >= Self.side {
            pendingMove = nil
            run(url)
        }
    }

    /// The card center for `spot` in an area of `size`.
    func center(of spot: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: Self.side / 2 + spot.x * (size.width - Self.side), y: Self.side / 2 + spot.y * (size.height - Self.side))
    }

    func framePosition(at date: Date) -> CGPoint? {
        guard let frameMove else { return nil }
        let progress = min(1, max(0, date.timeIntervalSince(frameMove.start) / frameMove.duration))
        return CGPoint(
            x: frameMove.from.x + (frameMove.to.x - frameMove.from.x) * progress,
            y: frameMove.from.y + (frameMove.to.y - frameMove.from.y) * progress)
    }

    func moveToRandomSpot() {
        move(style: nil, target: Self.randomSpot())
    }

    private func run(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host() {
            case "move":
                guard let target = Self.value(items, "to", default: Self.randomSpot(), Self.fraction),
                    let durationMs = Self.value(items, "duration", default: Self.defaultDurationMs, Self.positive)
                else { return ignore(url) }
                let styleName = items.first { $0.name == "style" }?.value
                let stallMs = items.first { $0.name == "stall" }?.value.flatMap { Int($0) }
                let framesDriven = items.first { $0.name == "driver" }?.value == "frames"
                move(
                    style: styleName.flatMap(MoveStyle.init(rawValue:)), target: target, duration: durationMs / 1000, stallMs: stallMs,
                    framesDriven: framesDriven)
            case "static":
                trial += 1
                record(String(format: "{\"trial\": %d, \"route\": \"static\", \"startedAt\": %.3f}", trial, Date().timeIntervalSince1970))
            case "marker":
                guard !markerRunning else { return }
                guard let intervalMs = Self.value(items, "interval", default: 500, Self.positive),
                    let count = Self.value(items, "count", default: 10, { Int($0).flatMap { $0 > 0 ? $0 : nil } })
                else { return ignore(url) }
                startMarker(intervalMs: intervalMs, count: count)
            default:
                return
        }
    }

    private func move(
        style: MoveStyle?, target: CGPoint, duration: Double = MotionLab.defaultDurationMs / 1000, stallMs: Int? = nil,
        framesDriven: Bool = false
    ) {
        guard !isMoving, area.width >= Self.side, area.height >= Self.side else { return }
        let style = style ?? MoveStyle.allCases.randomElement()!
        let from = center(of: spot, in: area.size)
        let to = center(of: target, in: area.size)
        trial += 1
        isMoving = true
        let startedAt = Date().timeIntervalSince1970
        if framesDriven {
            frameMove = FrameMove(from: spot, to: target, start: Date(), duration: duration)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                self.spot = target
                self.frameMove = nil
                self.isMoving = false
            }
        } else {
            withAnimation(style.animation(duration: duration), completionCriteria: .removed) {
                spot = target
            } completion: {
                self.isMoving = false
            }
        }
        if let stallMs {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * 0.4) {
                Thread.sleep(forTimeInterval: Double(stallMs) / 1000)
            }
        }
        let loggedStyle = framesDriven ? "linear" : style.rawValue
        // from and to are card centers in window points.
        record(
            String(
                format:
                    "{\"trial\": %d, \"style\": \"%@\", \"duration\": %.3f, \"from\": [%.1f, %.1f], \"to\": [%.1f, %.1f], \"startedAt\": %.3f, \"stallMs\": %d, \"driver\": \"%@\"}",
                trial, loggedStyle, duration, area.minX + from.x, area.minY + from.y, area.minX + to.x, area.minY + to.y, startedAt,
                stallMs ?? 0,
                framesDriven ? "frames" : "swiftui"
            )
        )
    }

    private func startMarker(intervalMs: Double, count: Int) {
        trial += 1
        markerRunning = true
        let trial = trial
        let wallClockOffset = Date().timeIntervalSince1970 - CACurrentMediaTime()
        MarkerClock(interval: intervalMs / 1000, count: count) { flash, lit, targetTime in
            self.flashing = lit
            if lit {
                // at is the target display time of the first flash frame in device wall-clock seconds.
                self.record(
                    String(
                        format: "{\"trial\": %d, \"route\": \"marker\", \"flash\": %d, \"intervalMs\": %.1f, \"at\": %.4f}", trial, flash,
                        intervalMs, targetTime + wallClockOffset))
            } else if flash == count {
                self.markerRunning = false
            }
        }.start()
    }

    private func ignore(_ url: URL) {
        FileHandle.standardError.write(Data("sample: ignored \(url), to takes x,y from 0 to 1 and numbers must be positive\n".utf8))
    }

    private func record(_ line: String) {
        let lineData = Data((line + "\n").utf8)
        FileHandle.standardOutput.write(lineData)
        do {
            if let handle = try? FileHandle(forWritingTo: Self.trialsURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: lineData)
            } else {
                try lineData.write(to: Self.trialsURL)
            }
        } catch {
            FileHandle.standardError.write(Data("trials.jsonl: \(error)\n".utf8))
        }
    }

    /// The query item `name` parsed by `parse`, `fallback` when it is absent, or nil when it does not parse.
    private static func value<T>(_ items: [URLQueryItem], _ name: String, default fallback: T, _ parse: (String) -> T?) -> T? {
        guard let text = items.first(where: { $0.name == name })?.value else { return fallback }
        return parse(text)
    }

    private static func randomSpot() -> CGPoint {
        CGPoint(x: Double.random(in: 0 ... 1), y: Double.random(in: 0 ... 1))
    }

    private static func positive(_ text: String) -> Double? {
        Double(text).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// `x,y` with both values from 0 to 1.
    private static func fraction(_ text: String) -> CGPoint? {
        let values = text.split(separator: ",").map { Double($0) ?? .nan }
        guard values.count == 2, values.allSatisfy({ (0 ... 1).contains($0) }) else { return nil }
        return CGPoint(x: values[0], y: values[1])
    }
}

enum MoveStyle: String, CaseIterable {
    case linear, easeIn, easeOut, easeInOut, smooth, bouncy

    func animation(duration: Double) -> Animation {
        switch self {
            case .linear: .linear(duration: duration)
            case .easeIn: .easeIn(duration: duration)
            case .easeOut: .easeOut(duration: duration)
            case .easeInOut: .easeInOut(duration: duration)
            case .smooth: .spring(duration: duration, bounce: 0)
            case .bouncy: .spring(duration: duration, bounce: 0.5)
        }
    }
}

/// Calls `flash` with the flash number, true and the frame's target time on the display-link frame nearest each of
/// `count` times `interval` seconds apart, then with false 100 ms or half the interval later.
@MainActor
final class MarkerClock: NSObject {
    private let interval: Double
    private let count: Int
    private let flash: @MainActor (Int, Bool, CFTimeInterval) -> Void
    private var nextOn: CFTimeInterval?
    private var offAt: CFTimeInterval?
    private var flashes = 0

    init(interval: Double, count: Int, flash: @escaping @MainActor (Int, Bool, CFTimeInterval) -> Void) {
        self.interval = interval
        self.count = count
        self.flash = flash
    }

    /// Adds a display link that retains the clock until the last flash ends.
    func start() {
        CADisplayLink(target: self, selector: #selector(tick)).add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let halfFrame = (link.targetTimestamp - link.timestamp) / 2
        guard let next = nextOn else {
            nextOn = link.targetTimestamp + interval
            return
        }
        if let off = offAt {
            guard link.targetTimestamp + halfFrame >= off else { return }
            offAt = nil
            flash(flashes, false, link.targetTimestamp)
            if flashes == count { link.invalidate() }
        } else if link.targetTimestamp + halfFrame >= next {
            flashes += 1
            offAt = next + min(0.1, interval / 2)
            nextOn = next + interval
            flash(flashes, true, link.targetTimestamp)
        }
    }
}
