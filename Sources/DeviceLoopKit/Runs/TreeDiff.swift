//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation

/// The structural differences between two UI trees. Elements with an id match by type and id, the others by type and label.
public struct TreeDiff: Codable, Sendable, Equatable {
    public struct Element: Codable, Sendable, Equatable {
        public var type: String
        public var id: String?
        public var label: String?
        public var frame: WireFrame
    }

    /// One property of a matched element that differs.
    public struct Change: Codable, Sendable, Equatable {
        public enum Property: String, Codable, Sendable {
            case label, value, frame, enabled
        }

        /// The baseline element.
        public var element: Element
        public var property: Property
        public var baseline: JSONValue
        public var candidate: JSONValue
        /// Candidate frame minus baseline frame, for `frame`.
        public var delta: [Double]?
    }

    /// Elements that share a type and id, or a type and label without an id, and occur more than once on a side, so they are
    /// not paired.
    public struct Ambiguous: Codable, Sendable, Equatable {
        public var type: String
        public var id: String?
        public var label: String?
        public var baseline: Int
        public var candidate: Int
    }

    /// Frame moves and resizes up to this many points are not reported.
    public static let frameTolerance = 2.0

    public var added: [Element] = []
    public var removed: [Element] = []
    public var changed: [Change] = []
    public var ambiguous: [Ambiguous] = []

    /// Elements were added, removed or changed, or an ambiguous group has a different count on each side.
    public var differs: Bool {
        !added.isEmpty || !removed.isEmpty || !changed.isEmpty || ambiguous.contains { $0.baseline != $0.candidate }
    }

    /// Compares every node of both trees, system nodes included. Nodes with an id in `ignoring`, and the nodes inside
    /// them, are left out.
    public init(_ baseline: TreeResult, _ candidate: TreeResult, ignoring ignoredIDs: Set<String> = []) {
        struct Key: Hashable {
            var type: String
            var id: String?
            var label: String?
        }
        var keys: [Key] = []
        var groups: [Key: [[TreeNode]]] = [:]
        for (side, tree) in [baseline, candidate].enumerated() {
            for node in Self.nodes(tree, ignoring: ignoredIDs) {
                let key = Key(type: node.type, id: node.id, label: node.id == nil ? node.label : nil)
                if groups[key] == nil {
                    keys.append(key)
                    groups[key] = [[], []]
                }
                groups[key]?[side].append(node)
            }
        }
        for key in keys {
            guard let pair = groups[key] else { continue }
            switch (pair[0].count, pair[1].count) {
                case (_, 0): removed += pair[0].map(Element.init)
                case (0, _): added += pair[1].map(Element.init)
                case (1, 1): changed += Self.changes(pair[0][0], pair[1][0])
                case (let baselineCount, let candidateCount):
                    ambiguous.append(
                        Ambiguous(type: key.type, id: key.id, label: key.label, baseline: baselineCount, candidate: candidateCount))
            }
        }
    }

    /// One line per removed, added and changed element, and one line listing the ambiguous groups.
    public var lines: [String] {
        var lines = removed.map { "removed \(Self.describe($0)) [\(Self.points($0.frame))]" }
        lines += added.map { "added \(Self.describe($0)) [\(Self.points($0.frame))]" }
        lines += changed.map { change in
            var line = "\(change.property.rawValue) of \(Self.describe(change.element)): "
            line += "\(Self.text(change.baseline)) to \(Self.text(change.candidate))"
            if let delta = change.delta { line += ", delta \(Self.points(delta))" }
            return line
        }
        if !ambiguous.isEmpty {
            let groups = ambiguous.map { group in
                let element = Element(type: group.type, id: group.id, label: group.label, frame: [])
                return "\(Self.describe(element)) \(group.baseline) vs \(group.candidate)"
            }
            lines.append("ambiguous, not compared: \(groups.joined(separator: ", "))")
        }
        return lines
    }

    /// Every node of `tree` in depth-first order, system nodes first, without the ignored ids and what they contain.
    static func nodes(_ tree: TreeResult, ignoring ignoredIDs: Set<String>) -> [TreeNode] {
        var nodes: [TreeNode] = []
        func walk(_ node: TreeNode) {
            if let id = node.id, ignoredIDs.contains(id) { return }
            nodes.append(node)
            node.children?.forEach(walk)
        }
        tree.system?.forEach(walk)
        walk(tree.root)
        return nodes
    }

    static func changes(_ base: TreeNode, _ other: TreeNode) -> [Change] {
        let element = Element(base)
        var changes: [Change] = []
        if base.label != other.label {
            changes.append(Change(element: element, property: .label, baseline: json(base.label), candidate: json(other.label)))
        }
        if base.value != other.value {
            changes.append(Change(element: element, property: .value, baseline: json(base.value), candidate: json(other.value)))
        }
        let delta = zip(other.frame, base.frame).map { $0 - $1 }
        if base.frame.count != other.frame.count || delta.contains(where: { abs($0) > frameTolerance }) {
            changes.append(
                Change(
                    element: element, property: .frame, baseline: .array(base.frame.map(JSONValue.number)),
                    candidate: .array(other.frame.map(JSONValue.number)), delta: delta))
        }
        if (base.enabled ?? true) != (other.enabled ?? true) {
            changes.append(
                Change(element: element, property: .enabled, baseline: .bool(base.enabled ?? true), candidate: .bool(other.enabled ?? true))
            )
        }
        return changes
    }

    static func json(_ text: String?) -> JSONValue {
        text.map(JSONValue.string) ?? .null
    }

    /// `button "Increment" id=fixture.counter.increment`, in the order `ui tree` prints them.
    static func describe(_ element: Element) -> String {
        element.type + (element.label.map { " \"\($0)\"" } ?? "") + (element.id.map { " id=\($0)" } ?? "")
    }

    /// `[124.7,188,65.3,20.3]` for a frame, JSON for the other values.
    static func text(_ value: JSONValue) -> String {
        if let numbers = value.array?.compactMap(\.number) { return "[\(points(numbers))]" }
        return String(decoding: (try? value.data()) ?? Data(), as: UTF8.self)
    }

    /// `124.7,188` with each value rounded to 0.1 pt.
    static func points(_ values: [Double]) -> String {
        values.map { ParityText.number(($0 * 10).rounded() / 10) }.joined(separator: ",")
    }
}

extension TreeDiff.Element {
    init(_ node: TreeNode) {
        self.init(type: node.type, id: node.id, label: node.label, frame: node.frame)
    }
}
