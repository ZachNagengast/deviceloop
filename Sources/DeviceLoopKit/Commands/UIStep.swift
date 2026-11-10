//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation

/// One UI action: a tap, swipe, drag, typed text, button press, launch, URL open or sleep.
public enum UIStep: Sendable, Equatable {
    case tap(ElementTarget, count: Int = 1, holdMs: Int? = nil)
    case swipe(direction: String, on: ElementTarget? = nil, velocity: Double? = nil)
    case drag(from: WirePoint, to: WirePoint, velocity: Double? = nil, holdMs: Int? = nil)
    case type(String, into: ElementTarget? = nil, clear: Bool = false)
    case press(button: String)
    case launch(bundleID: String, arguments: [String] = [], environment: [String: String] = [:])
    case openURL(String)
    case sleep(ms: Int)

    /// Parses the step grammar shared by the CLI and MCP:
    /// `tap 120,640`, `tap @e5`, `tap "Wi-Fi"`, `tap id=login`, `hold @e5 800`, `swipe up`, `swipe left @e3`,
    /// `drag 200,700 200,200`, `type "hello"`, `press home`, `launch com.apple.Preferences`, `open https://...`, `sleep 500`.
    public static func parse(_ text: String) throws -> UIStep {
        let words = tokenize(text)
        guard let verb = words.first?.lowercased() else {
            throw DeviceLoopError(.badArguments, "Empty step.", fix: "Try: tap \"Settings\"")
        }
        let rest = Array(words.dropFirst())
        switch verb {
            case "tap", "doubletap", "hold":
                guard let first = rest.first else { throw DeviceLoopError.usage("\(verb) needs a target, for example: tap \"Wi-Fi\"") }
                let target = try parseTarget(first)
                if verb == "hold" {
                    guard let holdMs = rest.count > 1 ? Int(rest[1]) : 800 else {
                        throw DeviceLoopError.usage("hold needs milliseconds, for example: hold @e5 800")
                    }
                    return .tap(target, holdMs: holdMs)
                }
                return .tap(target, count: verb == "doubletap" ? 2 : 1)
            case "swipe":
                guard let direction = rest.first?.lowercased(), ["up", "down", "left", "right"].contains(direction) else {
                    throw DeviceLoopError.usage("swipe needs a direction: up, down, left or right")
                }
                return .swipe(direction: direction, on: try rest.dropFirst().first.map(parseTarget))
            case "drag":
                guard rest.count >= 2, let from = parsePoint(rest[0]), let to = parsePoint(rest[1]) else {
                    throw DeviceLoopError.usage("drag needs two points, for example: drag 200,700 200,200")
                }
                return .drag(from: from, to: to)
            case "type":
                guard let text = rest.first else { throw DeviceLoopError.usage("type needs text, for example: type \"hello\"") }
                return .type(text, into: try rest.dropFirst().first.map(parseTarget))
            case "press":
                guard let button = rest.first else {
                    throw DeviceLoopError.usage("press needs a button: home, volumeUp, volumeDown, action or camera")
                }
                return .press(button: button)
            case "launch":
                guard let bundle = rest.first else { throw DeviceLoopError.usage("launch needs a bundle ID") }
                return .launch(bundleID: bundle)
            case "open":
                guard let url = rest.first else { throw DeviceLoopError.usage("open needs a URL") }
                return .openURL(url)
            case "sleep", "wait":
                guard let ms = rest.first.flatMap({ Int($0) }) else { throw DeviceLoopError.usage("sleep needs milliseconds") }
                return .sleep(ms: ms)
            default:
                throw DeviceLoopError.usage(
                    "Unknown step \"\(verb)\". Use tap, doubletap, hold, swipe, drag, type, press, launch, open or sleep.")
        }
    }

    /// Throws bad_arguments for a tap count other than 1 or 2, a hold outside 1-10000 ms,
    /// a velocity that is not a finite number greater than 0, or a point that is not finite.
    public func validate() throws {
        var points: [WirePoint?] = []
        var targets: [ElementTarget?] = []
        var holdMs: Int?
        var velocity: Double?
        switch self {
            case .tap(let target, let count, let hold):
                guard count == 1 || count == 2 else { throw DeviceLoopError.usage("Tap count must be 1 or 2, not \(count).") }
                points = [target.point]
                targets = [target]
                holdMs = hold
            case .swipe(_, let on, let speed):
                points = [on?.point]
                targets = [on]
                velocity = speed
            case .drag(let from, let to, let speed, let hold):
                points = [from, to]
                velocity = speed
                holdMs = hold
            case .type(_, let into, _):
                points = [into?.point]
                targets = [into]
            default:
                break
        }
        for target in targets.compactMap({ $0 }) { try UICommands.checkType(target.query) }
        if let holdMs, !(1 ... 10_000).contains(holdMs) {
            throw DeviceLoopError.usage("Hold must be 1-10000 ms, not \(holdMs).")
        }
        if let velocity, !(velocity.isFinite && velocity > 0) {
            throw DeviceLoopError.usage("Velocity must be a number of pixels per second greater than 0, not \(velocity).")
        }
        if points.compactMap({ $0 }).contains(where: { !$0.x.isFinite || !$0.y.isFinite }) {
            throw DeviceLoopError.usage("Points must be finite numbers, for example 120,640.")
        }
    }

    /// `120,640` point, `@e5` ref or a ref as `ui tree` prints it, `id=login`, `label~=Wi`, or anything else as an exact
    /// label.
    public static func parseTarget(_ word: String) throws -> ElementTarget {
        if let point = parsePoint(word) { return ElementTarget(point: point) }
        if word.hasPrefix("@") { return ElementTarget(ref: String(word.dropFirst())) }
        if word.wholeMatch(of: /e[0-9a-f]{8}\.[0-9]+\.[0-9]+/) != nil { return ElementTarget(ref: word) }
        if word.hasPrefix("id=") { return ElementTarget(query: ElementQuery(id: String(word.dropFirst(3)))) }
        if word.hasPrefix("label~=") { return ElementTarget(query: ElementQuery(labelContains: String(word.dropFirst(7)))) }
        return ElementTarget(query: ElementQuery(label: word))
    }

    /// `120,640` as a point, or nil.
    public static func parsePoint(_ word: String) -> WirePoint? {
        let parts = word.split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return WirePoint(x: x, y: y)
    }

    /// The text a `type` step types.
    public var typedText: String? {
        if case .type(let text, _, _) = self { return text }
        return nil
    }

    /// Splits on spaces, keeping double-quoted phrases together.
    static func tokenize(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
            } else if character == " " && !quoted {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
