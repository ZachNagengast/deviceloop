//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation

extension Param {
    static let app = string("Bundle ID of the app to act on. Defaults to the app in front.")
    static let element = string(
        "`120,640` (points), `@<ref>` (ref from ui_tree), `id=login` (accessibility identifier), `label~=Wi` (label contains) or an exact label."
    )
    static let query: [String: JSONValue] = [
        "label": string("Exact accessibility label."),
        "label_contains": string("Label contains this text, case-insensitive."),
        "id": string("Accessibility identifier."),
        "type": string("Element type, for example button or textField."),
    ]
}

extension MCPTool {
    /// A UI action tool that parses its step before it resolves the target. Calls are journaled in the target's active run.
    static func step(
        name: String,
        title: String,
        description: String,
        properties: [String: JSONValue],
        required: [String],
        parse: @escaping @Sendable (MCPArguments) throws -> UIStep
    ) -> MCPTool {
        MCPTool(
            name: name,
            title: title,
            description: description,
            properties: properties.merging(["device": Param.device]) { own, _ in own },
            required: required,
            readOnly: false,
            destructive: true
        ) { arguments in
            let step = try parse(arguments)
            let target = try await arguments.target()
            return try await arguments.record(target.udid) {
                try await UICommands.perform(step, on: target, app: arguments.string("app"))
            }
        }
    }
}

extension MCPTools {
    static let waitConditions = ["exists", "gone", "hittable", "enabled", "stable"]

    static let ui: [MCPTool] = [
        .device(
            name: "ui_tree",
            title: "Read UI tree",
            description: """
                List the accessibility elements on screen, one per line with a ref. Pass `@<ref>` to ui_tap, ui_type or ui_swipe. \
                System alerts come first. The first ui tool call starts the UI runner, which can take a minute.
                """,
            properties: [
                "app": Param.app,
                "frames": Param.boolean("Include each element's frame in points."),
                "max_rows": Param.integer("Stop after this many lines.", default: 200),
                "screenshot": Param.boolean("Also return a screenshot at point size."),
            ],
            readOnly: false,
            transform: withoutNodeLists
        ) { target, arguments in
            try await UICommands.tree(
                target,
                app: arguments.string("app"),
                frames: arguments.bool("frames") ?? false,
                maxRows: arguments.int("max_rows") ?? 200,
                screenshot: arguments.bool("screenshot") ?? false
            )
        },
        .step(
            name: "ui_tap",
            title: "Tap",
            description: "Tap, double tap or long press a point, a ref from ui_tree or an element.",
            properties: [
                "element": Param.element,
                "count": Param.integer("1 for a tap, 2 for a double tap.", default: 1),
                "hold_ms": Param.integer("Hold this many milliseconds for a long press."),
                "app": Param.app,
            ],
            required: ["element"]
        ) { arguments in
            .tap(
                try arguments.requireElementTarget("element"), count: try arguments.int("count") ?? 1,
                holdMs: try arguments.int("hold_ms"))
        },
        .step(
            name: "ui_type",
            title: "Type text",
            description: """
                Type text into the focused field, or tap `into` first. \
                With `into`, the result reports textVerified, whether the field then holds the typed text. A secure field is not verified.
                """,
            properties: [
                "text": Param.string("Text to type."),
                "into": Param.element,
                "clear": Param.boolean("Clear the field first."),
                "app": Param.app,
            ],
            required: ["text"]
        ) { arguments in
            .type(
                try arguments.require("text"), into: try arguments.elementTarget("into"),
                clear: try arguments.bool("clear") ?? false)
        },
        .step(
            name: "ui_swipe",
            title: "Swipe",
            description: "Swipe up, down, left or right on the app or on one element.",
            properties: [
                "direction": Param.string("Swipe direction.", oneOf: UIStep.swipeDirections),
                "on": Param.string("Element to swipe on, same forms as ui_tap. Defaults to the whole app."),
                "velocity": Param.number("Pixels per second, greater than 0."),
                "app": Param.app,
            ],
            required: ["direction"]
        ) { arguments in
            let direction = try arguments.require("direction")
            guard UIStep.swipeDirections.contains(direction) else {
                throw DeviceLoopError(.badArguments, "ui_swipe direction must be up, down, left or right, got \(direction).")
            }
            return .swipe(
                direction: direction, on: try arguments.elementTarget("on"), velocity: try arguments.number("velocity"))
        },
        .step(
            name: "ui_drag",
            title: "Drag",
            description: "Press at one point, drag in a straight line to another and release.",
            properties: [
                "from": Param.string("Start point in screen points, x,y."),
                "to": Param.string("End point in screen points, x,y."),
                "velocity": Param.number("Pixels per second, greater than 0."),
                "hold_ms": Param.integer("Hold at the end before lifting, in milliseconds."),
                "app": Param.app,
            ],
            required: ["from", "to"]
        ) { arguments in
            let from = try arguments.require("from")
            let to = try arguments.require("to")
            guard let start = UIStep.parsePoint(from), let end = UIStep.parsePoint(to) else {
                throw DeviceLoopError(
                    .badArguments, "ui_drag from and to must be x,y points, got \(from) and \(to).", fix: "For example: 200,700 and 200,200"
                )
            }
            return .drag(from: start, to: end, velocity: try arguments.number("velocity"), holdMs: try arguments.int("hold_ms"))
        },
        .step(
            name: "ui_press",
            title: "Press button",
            description:
                "Press a hardware button. A target without that button fails with unsupported_on_target and lists the ones it has. Volume buttons only on devices.",
            properties: ["button": Param.string("Button to press.", oneOf: UIStep.buttons)],
            required: ["button"]
        ) { arguments in
            let button = try arguments.require("button")
            guard UIStep.buttons.contains(button) else {
                throw DeviceLoopError(
                    .badArguments, "ui_press button must be one of \(UIStep.buttons.joined(separator: ", ")), got \(button).")
            }
            return .press(button: button)
        },
        .device(
            name: "ui_find",
            title: "Find elements",
            description: "Find elements by label, identifier or type and list each one's type, label, id, value and frame.",
            properties: Param.query.merging([
                "all": Param.boolean("Return every match instead of the first."),
                "app": Param.app,
            ]) { own, _ in own },
            readOnly: false
        ) { target, arguments in
            try await UICommands.find(
                target, app: arguments.string("app"), query: query(arguments) ?? ElementQuery(), all: arguments.bool("all") ?? false)
        },
        .device(
            name: "ui_wait",
            title: "Wait for element",
            description: "Wait until an element exists, is gone, hittable or enabled, or until the screen is stable.",
            properties: Param.query.merging([
                "until": Param.string("Condition to wait for. `stable` takes no element.", oneOf: waitConditions),
                "timeout_ms": Param.integer("Give up after this many milliseconds.", default: 10_000),
                "app": Param.app,
            ]) { own, _ in own },
            readOnly: false
        ) { target, arguments in
            let until = try arguments.string("until") ?? "exists"
            guard waitConditions.contains(until) else {
                throw DeviceLoopError(.badArguments, "ui_wait until must be exists, gone, hittable, enabled or stable, got \(until).")
            }
            return try await UICommands.wait(
                target, app: arguments.string("app"), query: query(arguments), until: until,
                timeoutMs: arguments.int("timeout_ms") ?? 10_000)
        },
        .device(
            name: "ui_alert",
            title: "System alert",
            description: "Read the current system alert, or answer it by tapping one of its buttons.",
            properties: ["answer": Param.string("`accept`, `dismiss` or a button label. Omit to read the alert.")],
            readOnly: false,
            destructive: true
        ) { target, arguments in
            let answer = try arguments.string("answer").map(MCPArguments.decodingEntities)
            let action = ["accept", "dismiss"].contains(answer ?? "") ? answer : nil
            return try await UICommands.alert(target, button: action == nil ? answer : nil, action: action)
        },
        .device(
            name: "ui_audit",
            title: "Accessibility audit",
            description: """
                Run XCTest's accessibility audit on the screen in front and list the issues, each with its element. \
                Types: contrast, elementDetection, hitRegion, sufficientElementDescription, dynamicType, textClipped, trait.
                """,
            properties: [
                "app": Param.app,
                "types": Param.strings("Audit types to run. Defaults to every type."),
                "suppressions": Param.string(
                    "Path to a JSON array of rules for known issues, each with a type, an id or label, and a reason."),
                "screenshot": Param.boolean("Also save a screenshot with the report."),
            ],
            readOnly: false
        ) { target, arguments in
            let rules = try arguments.string("suppressions").map { try AuditSuppression.load(from: MCPArguments.fileURL($0)) } ?? []
            return try await AuditCommands.audit(
                target, app: arguments.string("app"), types: arguments.strings("types"), suppressions: rules,
                screenshot: arguments.bool("screenshot") ?? false)
        },
        .device(
            name: "runner_status",
            title: "Runner status",
            description: "Report whether the UI runner is running on a target, its uptime, whether it is busy, and its host app.",
            readOnly: true
        ) { target, _ in
            try await RunnerCommands.status(target)
        },
        .device(
            name: "runner_stop",
            title: "Stop runner",
            description: "Stop the UI runner on a target. The next ui tool call starts it again.",
            readOnly: false,
            idempotent: true
        ) { target, _ in
            try await RunnerCommands.stop(target)
        },
    ]

    /// `result` without the `root` and `system` node lists in its JSON.
    static func withoutNodeLists(_ result: CommandResult) -> CommandResult {
        var result = result
        result.json = .object((result.json.object ?? [:]).filter { !["root", "system"].contains($0.key) })
        return result
    }

    /// The query from `label`, `label_contains`, `id` and `type`, or nil when none is given.
    static func query(_ arguments: MCPArguments) throws -> ElementQuery? {
        let query = ElementQuery(
            type: try arguments.string("type"),
            id: try arguments.string("id"),
            label: try arguments.string("label").map(MCPArguments.decodingEntities),
            labelContains: try arguments.string("label_contains").map(MCPArguments.decodingEntities)
        )
        return query == ElementQuery() ? nil : query
    }
}
