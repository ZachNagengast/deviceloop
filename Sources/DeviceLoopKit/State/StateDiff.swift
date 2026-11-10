//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// Field-by-field comparison of two `DeviceState` captures of one target.
public struct StateDiff: Codable, Sendable {
    public var udid: String
    public var beforeCapturedAt: String
    public var afterCapturedAt: String
    /// Both captures observed osBuild and the builds differ.
    public var osBuildChanged: Bool
    public var fields: [String: Change]

    public struct Change: Codable, Sendable {
        public enum Status: String, Codable, Sendable {
            case unchanged
            case changed
            /// At least one side was not observed.
            case unknown
        }

        public var status: Status
        /// Nil unless observed.
        public var before: JSONValue?
        /// Nil unless observed.
        public var after: JSONValue?
        /// Why the field could not be compared.
        public var reason: String?
        public var source: String
        /// When the after side was read.
        public var observedAt: String?
    }
}

extension StateDiff {
    /// Compares every field in either capture. A field is unknown unless both sides observed it.
    static func compare(_ before: DeviceState, _ after: DeviceState) throws -> StateDiff {
        guard before.udid == after.udid else {
            throw DeviceLoopError(
                .badArguments,
                "The captures are of different targets, \(before.udid) and \(after.udid).",
                fix: "Compare two captures of the same device or simulator."
            )
        }
        func observed(_ field: StateField?) -> JSONValue? {
            field?.availability == .observed ? field?.value : nil
        }
        func notObserved(_ field: StateField?, _ side: String) -> String? {
            guard observed(field) == nil else { return nil }
            guard let field else { return "\(side): not in the capture" }
            return "\(side): \(field.availability.rawValue), \(field.reason ?? "no reason recorded")"
        }
        var fields: [String: Change] = [:]
        for name in Set(before.fields.keys).union(after.fields.keys) {
            let old = before.fields[name]
            let new = after.fields[name]
            let status: Change.Status =
                switch (observed(old), observed(new)) {
                    case (let oldValue?, let newValue?): oldValue == newValue ? .unchanged : .changed
                    default: .unknown
                }
            fields[name] = Change(
                status: status,
                before: observed(old),
                after: observed(new),
                reason: status == .unknown ? notObserved(new, "after") ?? notObserved(old, "before") : nil,
                source: new?.source ?? old?.source ?? "none",
                observedAt: observed(new) == nil ? nil : new?.observedAt
            )
        }
        return StateDiff(
            udid: after.udid,
            beforeCapturedAt: before.capturedAt,
            afterCapturedAt: after.capturedAt,
            osBuildChanged: fields["osBuild"]?.status == .changed,
            fields: fields
        )
    }
}
