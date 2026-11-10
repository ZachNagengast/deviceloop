//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation

/// Renders a runner tree as the compact ui-tree/1 text: one element per line, refs on each, system alerts first.
/// An `other` element with no label, id, value or placeholder gets no line, and its children take its depth.
enum UITree {
    static func render(_ tree: TreeResult, frames: Bool, maxRows: Int?) -> (text: String, truncated: Bool) {
        var lines: [String] = []
        if let system = tree.system, !system.isEmpty {
            lines.append("system:")
            for node in system { append(node, depth: 1, frames: frames, into: &lines) }
            lines.append("app \(tree.app):")
        }
        append(tree.root, depth: tree.system?.isEmpty == false ? 1 : 0, frames: frames, into: &lines)

        let header = "\(tree.app) gen=\(tree.generation) \(tree.nodeCount) nodes"
        if let maxRows, lines.count > maxRows {
            let kept = Array(lines.prefix(maxRows))
            let note = "... \(lines.count - maxRows) more lines, raise --max-rows or scope with --app"
            return (([header] + kept + [note]).joined(separator: "\n"), true)
        }
        return (([header] + lines).joined(separator: "\n"), false)
    }

    private static func append(_ node: TreeNode, depth: Int, frames: Bool, into lines: inout [String]) {
        if node.type == "other", node.label == nil, node.id == nil, node.value == nil, node.placeholder == nil {
            for child in node.children ?? [] { append(child, depth: depth, frames: frames, into: &lines) }
            return
        }
        var parts = ["\(String(repeating: "  ", count: depth))\(node.ref) \(node.type)"]
        if let label = node.label { parts.append("\"\(label)\"") }
        if let id = node.id { parts.append("id=\(id)") }
        if let value = node.value, !value.isEmpty { parts.append("value=\(value)") }
        if let placeholder = node.placeholder { parts.append("placeholder=\(placeholder)") }
        if node.enabled == false { parts.append("disabled") }
        if node.selected == true { parts.append("selected") }
        if frames, node.frame.count == 4 {
            parts.append("[\(int(node.frame[0])),\(int(node.frame[1])),\(int(node.frame[2])),\(int(node.frame[3]))]")
        }
        lines.append(parts.joined(separator: " "))
        for child in node.children ?? [] { append(child, depth: depth + 1, frames: frames, into: &lines) }
    }

    private static func int(_ value: Double) -> Int { Int(value.rounded()) }
}
