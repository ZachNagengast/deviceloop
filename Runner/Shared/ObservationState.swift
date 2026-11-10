//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// Stores references that belong to one app observation in one runner process.
public struct ObservationReferences<Value> {
    /// Eight hex digits keep refs short, and one from an earlier runner process still fails to resolve.
    private let epoch = String(UUID().uuidString.lowercased().prefix(8))
    public private(set) var generation = 0
    private var app: String?
    /// The device orientation the current observation was taken in.
    public private(set) var orientation: String?
    private var values: [String: Value] = [:]

    public init() {}

    /// Starts a new observation in `orientation`, discarding every reference from the previous one.
    public mutating func begin(app: String, orientation: String) {
        generation += 1
        self.app = app
        self.orientation = orientation
        values.removeAll(keepingCapacity: true)
    }

    /// Adds a value and returns an opaque reference unique to this observation.
    public mutating func insert(_ value: Value) -> String {
        precondition(app != nil, "Begin an observation before adding references")
        let ref = "e\(epoch).\(generation).\(values.count)"
        values[ref] = value
        return ref
    }

    /// Resolves a reference only within the app observation that issued it, while the device keeps its orientation.
    public func value(for ref: String, app: String, orientation: String) -> Value? {
        guard self.app == app, self.orientation == orientation else { return nil }
        return values[ref]
    }

    /// Discards cached targets after input or another change to the observed state.
    public mutating func invalidate() {
        app = nil
        orientation = nil
        values.removeAll(keepingCapacity: true)
    }
}

/// Measures a quiet interval using successful consecutive samples and monotonic time.
public struct ObservationStability {
    private let quietDuration: TimeInterval
    private var lastHash: Int?
    private var stableSince: TimeInterval?

    public init(quietDuration: TimeInterval) {
        self.quietDuration = quietDuration
    }

    /// A missing sample breaks the quiet interval and can never establish stability.
    public mutating func observe(hash: Int?, at time: TimeInterval) -> Bool {
        guard let hash else {
            lastHash = nil
            stableSince = nil
            return false
        }
        guard lastHash == hash, let stableSince else {
            lastHash = hash
            stableSince = time
            return false
        }
        return time - stableSince >= quietDuration
    }
}
