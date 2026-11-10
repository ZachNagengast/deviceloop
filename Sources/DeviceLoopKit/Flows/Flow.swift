//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation

/// A saved flow file, schema `deviceloop.flow/1`.
public struct Flow: Sendable, Equatable {
    public static let schema = "deviceloop.flow/1"

    public enum Reset: String, Sendable {
        case none, relaunch, reinstall
    }

    public struct App: Sendable, Equatable {
        public var bundleID: String
        public var arguments: [String]
        public var environment: [String: String]
        /// Required CFBundleShortVersionString, when set.
        public var version: String?
        /// Required CFBundleVersion, when set.
        public var build: String?
    }

    public var name: String
    public var app: App
    public var reset: Reset
    /// The .app or .ipa installed by `reset: reinstall`.
    public var appPath: String?
    public var requires: [String]
    /// Deadline for the whole flow, 1 ms to 30 minutes.
    public var timeoutMs: Int
    public var setup: [FlowStep]
    public var steps: [FlowStep]
    public var cleanup: [FlowStep]

    /// Validates a decoded flow file. Errors start with the failing path, for example `steps[3].tapp`.
    public init(_ json: JSONValue) throws {
        guard json.object != nil else { throw FlowFields.invalid("flow", "must be a JSON object.") }
        guard let schema = json["schema"] else {
            throw FlowFields.invalid("schema", "is missing.", fix: "Add \"schema\": \"\(Self.schema)\".")
        }
        guard schema.string == Self.schema else {
            throw FlowFields.invalid("schema", "must be \(Self.schema).", fix: "Set \"schema\": \"\(Self.schema)\".")
        }
        let root = try FlowFields(
            json, at: "", allowed: ["schema", "name", "app", "reset", "appPath", "requires", "timeoutMs", "setup", "steps", "cleanup"])
        let appFields = try root.require("app", root.fields("app", allowed: ["bundleID", "arguments", "environment", "version", "build"]))
        name = try root.require("name", root.string("name"))
        app = App(
            bundleID: try appFields.require("bundleID", appFields.bundleID("bundleID")),
            arguments: try appFields.strings("arguments") ?? [],
            environment: try appFields.environment("environment") ?? [:],
            version: try appFields.string("version"),
            build: try appFields.string("build")
        )
        let resetName = try root.string("reset") ?? Reset.none.rawValue
        guard let reset = Reset(rawValue: resetName) else { throw FlowFields.invalid("reset", "must be none, relaunch or reinstall.") }
        self.reset = reset
        appPath = try root.string("appPath")
        if reset == .reinstall, appPath == nil {
            throw FlowFields.invalid("appPath", "is missing.", fix: "reset reinstall needs the path of the .app or .ipa to install.")
        }
        if reset != .reinstall, appPath != nil {
            throw FlowFields.invalid("appPath", "is used only with reset reinstall.")
        }
        if let appPath, !["app", "ipa"].contains(URL(filePath: appPath).pathExtension.lowercased()) {
            throw FlowFields.invalid("appPath", "must be an .app bundle or an .ipa file.")
        }
        requires = try root.strings("requires") ?? []
        if let index = requires.firstIndex(where: { !Self.requirementNames.contains($0) }) {
            throw FlowFields.invalid(
                "requires[\(index)]", "\(requires[index]) is not a requirement DeviceLoop checks.",
                fix: "Use \(Self.requirementNames.joined(separator: ", ")).")
        }
        timeoutMs = try root.int("timeoutMs", in: 1 ... 1_800_000) ?? 300_000
        setup = try root.steps("setup", app: app)
        steps = try root.steps("steps", app: app)
        guard !steps.isEmpty else { throw FlowFields.invalid("steps", "needs at least one step.") }
        cleanup = try root.steps("cleanup", app: app)
    }

    /// Names `requires` accepts, in the order `requirements` lists them.
    public static let requirementNames = ["ui runner", "home button", "action button", "install", "uninstall"]

    /// The runner, the buttons that press steps use, install and uninstall for reset reinstall, and `requires`.
    public var requirements: [String] {
        let buttons = (setup + steps + cleanup).compactMap { step -> String? in
            guard case .ui(.press(let button)) = step.action else { return nil }
            return "\(button) button"
        }
        let needed = Set(["ui runner"] + buttons + (reset == .reinstall ? ["install", "uninstall"] : []) + requires)
        return Self.requirementNames.filter(needed.contains)
    }
}

/// One flow step and the longest it may take.
public struct FlowStep: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case ui(UIStep)
        case assert(ElementQuery, FlowAssertion)
        /// Waits until the accessibility tree stays unchanged for `quietMs`.
        case settle(quietMs: Int)
        case screenshot(name: String?)
        /// Taps the system alert button with this exact label.
        case alert(button: String)
    }

    public var action: Action
    /// 1 to 120000 ms.
    public var timeoutMs: Int

    public init(_ action: Action, timeoutMs: Int) {
        self.action = action
        self.timeoutMs = timeoutMs
    }

    static let targetKeys: Set<String> = ["id", "label", "labelContains", "type", "x", "y"]

    /// Fields each step kind accepts besides `timeoutMs`.
    static let kinds: [String: Set<String>] = [
        "tap": targetKeys,
        "doubletap": targetKeys,
        "hold": targetKeys.union(["ms"]),
        "swipe": ["direction", "on", "velocity"],
        "drag": ["from", "to", "velocity", "holdMs"],
        "type": ["text", "into", "clear"],
        "press": ["button"],
        "launch": ["bundleID", "arguments", "environment"],
        "open": ["url"],
        "sleep": ["ms"],
        "assert": ["element", "is", "label", "value"],
        "settle": ["quietMs"],
        "screenshot": ["name"],
        "alert": ["button"],
    ]

    /// Step kinds that other commands own and flow v1 does not run.
    static let laterKinds: Set<String> = ["siri", "location", "appearance", "orientation", "audit", "checkpoint"]

    init(_ json: JSONValue, at path: String, app: Flow.App) throws {
        guard let object = json.object, object.count == 1, let kind = object.keys.first, let body = object[kind] else {
            throw FlowFields.invalid(path, "must be an object with one step kind, for example {\"tap\": {\"id\": \"login\"}}.")
        }
        let kindPath = "\(path).\(kind)"
        if Self.laterKinds.contains(kind) {
            throw FlowFields.invalid(kindPath, "\(kind) is not in flow v1.", fix: "Remove the step and run it outside the flow.")
        }
        guard let allowed = Self.kinds[kind] else {
            throw FlowFields.invalid(kindPath, "unknown step kind.", fix: "Use \(Self.kinds.keys.sorted().joined(separator: ", ")).")
        }
        let fields = try FlowFields(body, at: kindPath, allowed: allowed.union(["timeoutMs"]))
        timeoutMs = try fields.int("timeoutMs", in: 1 ... 120_000) ?? 30_000
        switch kind {
            case "tap", "doubletap":
                action = .ui(.tap(try fields.target(), count: kind == "doubletap" ? 2 : 1))
            case "hold":
                action = .ui(.tap(try fields.target(), holdMs: try fields.int("ms", in: 1 ... 10_000) ?? 800))
            case "swipe":
                let direction = try fields.require("direction", fields.string("direction"))
                guard ["up", "down", "left", "right"].contains(direction) else {
                    throw FlowFields.invalid(fields.child("direction"), "must be up, down, left or right.")
                }
                let on = try fields.fields("on", allowed: Self.targetKeys)?.target()
                action = .ui(.swipe(direction: direction, on: on, velocity: try fields.double("velocity", in: 1 ... 10_000)))
            case "drag":
                let from = try fields.require("from", fields.fields("from", allowed: ["x", "y"])).point()
                let to = try fields.require("to", fields.fields("to", allowed: ["x", "y"])).point()
                let velocity = try fields.double("velocity", in: 1 ... 10_000)
                action = .ui(.drag(from: from, to: to, velocity: velocity, holdMs: try fields.int("holdMs", in: 1 ... 10_000)))
            case "type":
                let text = try fields.require("text", fields.string("text", allowEmpty: true))
                let into = try fields.fields("into", allowed: Self.targetKeys)?.target()
                action = .ui(.type(text, into: into, clear: try fields.bool("clear") ?? false))
            case "press":
                let button = try fields.require("button", fields.string("button"))
                guard ["home", "action"].contains(button) else {
                    throw FlowFields.invalid(fields.child("button"), "must be home or action.")
                }
                action = .ui(.press(button: button))
            case "launch":
                let bundleID = try fields.bundleID("bundleID")
                let isFlowApp = bundleID == nil
                action = .ui(
                    .launch(
                        bundleID: bundleID ?? app.bundleID,
                        arguments: try fields.strings("arguments") ?? (isFlowApp ? app.arguments : []),
                        environment: try fields.environment("environment") ?? (isFlowApp ? app.environment : [:])
                    ))
            case "open":
                let url = try fields.require("url", fields.string("url"))
                guard URL(string: url)?.scheme != nil else {
                    throw FlowFields.invalid(fields.child("url"), "must be a URL with a scheme, for example https://example.com.")
                }
                action = .ui(.openURL(url))
            case "sleep":
                action = .ui(.sleep(ms: try fields.require("ms", fields.int("ms", in: 1 ... 10_000))))
            case "assert":
                let element = try fields.require("element", fields.fields("element", allowed: ["id", "label", "labelContains", "type"]))
                action = .assert(try element.query(), try fields.assertion())
            case "settle":
                action = .settle(quietMs: try fields.int("quietMs", in: 1 ... 10_000) ?? 300)
            case "screenshot":
                let name = try fields.string("name")
                if let name, name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]{0,63}/) == nil {
                    throw FlowFields.invalid(
                        fields.child("name"),
                        "must be 1 to 64 letters, digits, dots, dashes or underscores, starting with a letter or digit.")
                }
                action = .screenshot(name: name)
            default:
                action = .alert(button: try fields.require("button", fields.string("button")))
        }
    }
}

/// What an `assert` step checks about its one matching element.
public enum FlowAssertion: Sendable, Equatable {
    case exists, gone, hittable, enabled
    /// Exact accessibility label.
    case label(String)
    /// Exact accessibility value.
    case value(String)
}

/// One JSON object of a flow file, with its path for error messages.
struct FlowFields {
    let path: String
    let values: [String: JSONValue]

    /// Rejects keys outside `allowed`, and in element targets names `ref`, `index` and `predicate` as selectors that do not replay.
    init(_ json: JSONValue, at path: String, allowed: Set<String>) throws {
        guard let values = json.object else { throw Self.invalid(path, "must be an object.") }
        self.path = path
        self.values = values
        for key in values.keys.sorted() where !allowed.contains(key) {
            if allowed.contains("id"), ["ref", "index", "predicate"].contains(key) {
                throw Self.invalid(
                    child(key), "\(key) depends on one snapshot and does not replay.",
                    fix: "Select the element with id, label or labelContains, and type if needed.")
            }
            throw Self.invalid(child(key), "unknown field.", fix: "Use \(allowed.sorted().joined(separator: ", ")).")
        }
    }

    static func invalid(_ path: String, _ problem: String, fix: String? = nil) -> DeviceLoopError {
        DeviceLoopError(.badArguments, "\(path): \(problem)", fix: fix)
    }

    func child(_ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    func require<Value>(_ key: String, _ value: Value?) throws -> Value {
        guard let value else { throw Self.invalid(child(key), "is missing.") }
        return value
    }

    func string(_ key: String, allowEmpty: Bool = false) throws -> String? {
        guard let value = values[key] else { return nil }
        guard let string = value.string, allowEmpty || !string.isEmpty else {
            throw Self.invalid(child(key), allowEmpty ? "must be a string." : "must be a non-empty string.")
        }
        return string
    }

    func bundleID(_ key: String) throws -> String? {
        guard let bundleID = try string(key) else { return nil }
        do {
            try Validate.bundleID(bundleID)
        } catch {
            throw Self.invalid(child(key), "\(bundleID) is not a bundle ID.")
        }
        return bundleID
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        guard let bool = value.bool else { throw Self.invalid(child(key), "must be true or false.") }
        return bool
    }

    func int(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let value = values[key] else { return nil }
        guard let number = value.number, number.rounded() == number, number >= Double(range.lowerBound), number <= Double(range.upperBound)
        else {
            throw Self.invalid(child(key), "must be an integer from \(range.lowerBound) to \(range.upperBound).")
        }
        return Int(number)
    }

    func double(_ key: String, in range: ClosedRange<Double>) throws -> Double? {
        guard let value = values[key] else { return nil }
        guard let number = value.number, range.contains(number) else {
            throw Self.invalid(child(key), "must be a number from \(Int(range.lowerBound)) to \(Int(range.upperBound)).")
        }
        return number
    }

    func strings(_ key: String) throws -> [String]? {
        guard let value = values[key] else { return nil }
        let strings = value.array?.compactMap(\.string)
        guard let strings, strings.count == value.array?.count else { throw Self.invalid(child(key), "must be an array of strings.") }
        return strings
    }

    func environment(_ key: String) throws -> [String: String]? {
        guard let value = values[key] else { return nil }
        let environment = value.object?.compactMapValues(\.string)
        guard let environment, environment.count == value.object?.count else {
            throw Self.invalid(child(key), "must be an object with string values.")
        }
        return environment
    }

    func fields(_ key: String, allowed: Set<String>) throws -> FlowFields? {
        guard let value = values[key] else { return nil }
        return try FlowFields(value, at: child(key), allowed: allowed)
    }

    func steps(_ key: String, app: Flow.App) throws -> [FlowStep] {
        guard let value = values[key] else { return [] }
        guard let items = value.array else { throw Self.invalid(child(key), "must be an array of steps.") }
        return try items.enumerated().map { try FlowStep($1, at: "\(child(key))[\($0)]", app: app) }
    }

    /// `x` and `y`, or an element query.
    func target() throws -> ElementTarget {
        guard values["x"] != nil || values["y"] != nil else { return ElementTarget(query: try query()) }
        if let other = values.keys.sorted().first(where: { $0 != "x" && $0 != "y" && FlowStep.targetKeys.contains($0) }) {
            throw Self.invalid(child(other), "a point target takes only x and y.")
        }
        return ElementTarget(point: try point())
    }

    func point() throws -> WirePoint {
        WirePoint(x: try require("x", double("x", in: 0 ... 10_000)), y: try require("y", double("y", in: 0 ... 10_000)))
    }

    /// Exactly one of `id`, `label` and `labelContains`, with an optional `type` from `FlowExport.elementTypes`.
    func query() throws -> ElementQuery {
        let selectors = ["id", "label", "labelContains"].filter { values[$0] != nil }
        guard selectors.count == 1 else {
            throw Self.invalid(
                path, selectors.isEmpty ? "needs id, label or labelContains." : "takes one of \(selectors.joined(separator: " and ")).")
        }
        let query = ElementQuery(
            type: try string("type"), id: try string("id"), label: try string("label"), labelContains: try string("labelContains"))
        do {
            try UICommands.checkType(query)
        } catch let error as DeviceLoopError {
            throw Self.invalid(child("type"), error.message, fix: error.fix)
        }
        return query
    }

    /// Exactly one of `is`, `label` and `value`.
    func assertion() throws -> FlowAssertion {
        let conditions = ["is", "label", "value"].filter { values[$0] != nil }
        guard conditions.count == 1 else {
            throw Self.invalid(
                path, conditions.isEmpty ? "needs is, label or value." : "takes one of \(conditions.joined(separator: " and ")).")
        }
        if let label = try string("label", allowEmpty: true) { return .label(label) }
        if let value = try string("value", allowEmpty: true) { return .value(value) }
        switch try string("is") {
            case "exists": return .exists
            case "gone": return .gone
            case "hittable": return .hittable
            case "enabled": return .enabled
            default: throw Self.invalid(child("is"), "must be exists, gone, hittable or enabled.")
        }
    }
}
