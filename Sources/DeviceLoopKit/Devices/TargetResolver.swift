//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// Picks the target a command runs on from a selector: a UDID, a name or a unique part of it, `booted`, `usb` or `device`.
public enum TargetResolver {
    /// Resolves `selector` (or `$DEVICELOOP_DEVICE`) against the current target list.
    /// With no selector, picks the only ready iPhone or iPad (connected device or booted simulator).
    public static func resolve(_ selector: String?) async throws -> Target {
        try await resolve(selector, list: Devicectl.listTargets)
    }

    /// Lists and resolves again for up to `connecting` while the match is a connecting device, or while nothing matches and
    /// a device is connecting. Within 20 s of the end of a USB capture it also waits for a match that is disconnected or
    /// not on USB, and for a selector that matches nothing. A wired device can drop and reconnect, or list on the local
    /// network, for a few seconds after USB screen capture stops.
    static func resolve(
        _ selector: String?, list: () async throws -> [Target], connecting: Duration = .seconds(10),
        lastCaptureEnded: Double? = Recorder.lastCaptureEnded()
    ) async throws -> Target {
        let selector = selector ?? ProcessInfo.processInfo.environment["DEVICELOOP_DEVICE"]
        let afterCapture = lastCaptureEnded.map { Date().timeIntervalSince1970 - $0 < 20 } ?? false
        let deadline = ContinuousClock.now.advanced(by: connecting)
        while true {
            let targets = try await list()
            do {
                let target = try resolve(selector, in: targets)
                let settling =
                    target.connectionState == "connecting"
                    || afterCapture && !target.isSimulator
                        && (target.connectionState == "disconnected" || target.isReady && target.transport != "wired")
                if !settling || ContinuousClock.now >= deadline { return target }
            } catch let error as DeviceLoopError where error.code == .deviceNotFound {
                let connectingDevice = targets.contains { $0.isDrivable && $0.connectionState == "connecting" }
                if !(afterCapture || connectingDevice) || ContinuousClock.now >= deadline { throw error }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    public static func resolve(_ selector: String?, in targets: [Target]) throws -> Target {
        let drivable = targets.filter(\.isDrivable)
        let selector = selector?.trimmingCharacters(in: .whitespaces)

        let matches: [Target]
        switch selector.map(folded) {
            case nil, "":
                matches = drivable.filter(\.isReady)
            case "booted":
                matches = drivable.filter { $0.isSimulator && $0.isReady }
            case "usb":
                matches = drivable.filter { !$0.isSimulator && $0.isReady && $0.transport == "wired" }
            case "device":
                matches = drivable.filter { !$0.isSimulator && $0.isReady }
            case let lowered?:
                let exact = drivable.filter {
                    $0.udid.lowercased() == lowered || $0.identifier.lowercased() == lowered || folded($0.name) == lowered
                }
                let partial = drivable.filter { folded($0.name).contains(lowered) || $0.udid.lowercased().hasPrefix(lowered) }
                matches = exact.isEmpty ? partial : exact
        }

        // Prefer ready targets when a name matches both a running and a stopped one.
        let ready = matches.filter(\.isReady)
        let candidates = ready.isEmpty ? matches : ready

        if candidates.count == 1 { return candidates[0] }

        let listing = (candidates.isEmpty ? drivable.filter(\.isReady) : candidates)
            .map { "\($0.name) [\($0.udid)]" }
        if candidates.isEmpty {
            let message =
                selector.map { "No iPhone, iPad or simulator matches \"\($0)\"." }
                ?? "No connected iPhone or iPad and no booted simulator."
            throw DeviceLoopError(
                .deviceNotFound,
                message,
                fix: selector == nil
                    ? "Connect and unlock a device, or boot a simulator (xcrun simctl boot <udid>)."
                    : "Run `deviceloop devices` and pass a name or UDID with --device.",
                alternatives: listing
            )
        }
        throw DeviceLoopError(
            .deviceAmbiguous,
            "\(candidates.count) targets match\(selector.map { " \"\($0)\"" } ?? ""). Pick one with --device.",
            fix: "Pass --device with a UDID or a unique part of the name, or set DEVICELOOP_DEVICE.",
            alternatives: listing
        )
    }

    /// Lowercased, with curly apostrophes and no-break spaces from device names made ASCII.
    static func folded(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
