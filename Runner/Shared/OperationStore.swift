//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// Identifies the exact admission that is allowed to complete an operation.
public struct OperationToken: Sendable, Equatable {
    public let id: String
    public let epoch: String
    fileprivate let nonce: UUID
}

/// Admission never waits or queues work behind an active UI operation.
public enum OperationAdmission<Response: Sendable>: Sendable {
    case admitted(OperationToken)
    case replay(Response)
    case inProgress
    case conflict
    case busy
}

/// An in-memory receipt. It is gone after expiry, eviction or a runner restart.
public struct OperationReceipt<Response: Sendable>: Sendable {
    public enum State: Sendable {
        case running
        case completed
    }

    public let id: String
    public let epoch: String
    public let state: State
    public let admittedAt: Double
    public let completedAt: Double?
    public let response: Response?
}

/// Admits one UI operation and handles duplicates while their terminal receipts remain retained.
/// Callers supply validated IDs, request fingerprints and monotonic uptime in seconds.
public final class OperationStore<Response: Sendable>: @unchecked Sendable {
    public let epoch = UUID().uuidString.lowercased()

    private struct Entry {
        let token: OperationToken
        let fingerprint: String
        let admittedAt: Double
        var completedAt: Double?
        var response: Response?
        var cost = 0
    }

    private let lock = NSLock()
    private let maxCompleted: Int
    private let retention: TimeInterval
    private let maxCompletedCost: Int
    private var active: OperationToken?
    private var entries: [String: Entry] = [:]
    private var completedOrder: [String] = []
    private var latestTime: Double = 0
    private var completedCost = 0

    /// Terminal responses expire after retention seconds. Active work is never evicted.
    /// Capacity is clamped to 1...128. Invalid retention uses the 600-second default.
    public init(maxCompleted: Int = 128, retention: TimeInterval = 600, maxCompletedCost: Int = 16 * 1024 * 1024) {
        self.maxCompleted = min(128, max(1, maxCompleted))
        self.retention = retention.isFinite && retention > 0 ? min(600, retention) : 600
        self.maxCompletedCost = max(0, maxCompletedCost)
    }

    /// Returns a cached response or an admission token without invoking caller code under the lock.
    /// A missing ID is treated as new.
    public func begin(id: String, fingerprint: String, now: Double) -> OperationAdmission<Response> {
        lock.withLock {
            let time = maintain(now: now)
            if let entry = entries[id] {
                guard entry.fingerprint == fingerprint else { return .conflict }
                if let response = entry.response { return .replay(response) }
                return .inProgress
            }
            guard active == nil else { return .busy }
            let token = OperationToken(id: id, epoch: epoch, nonce: UUID())
            active = token
            entries[id] = Entry(token: token, fingerprint: fingerprint, admittedAt: time)
            return .admitted(token)
        }
    }

    /// Stores the terminal response, including cancellation before dispatch, then releases admission.
    /// Returns false for duplicate, stale or foreign completion tokens without changing active work.
    /// Supply response bytes as cost to bound payload memory. Oversized responses are not retained.
    @discardableResult
    public func finish(token: OperationToken, response: Response, now: Double, cost: Int = 0) -> Bool {
        lock.withLock {
            let time = maintain(now: now)
            guard active == token, var entry = entries[token.id], entry.token == token else { return false }
            active = nil
            entry.cost = max(0, cost)
            guard entry.cost <= maxCompletedCost else {
                entries.removeValue(forKey: token.id)
                return true
            }
            while completedCost > maxCompletedCost - entry.cost {
                evictFirst()
            }
            entry.response = response
            entry.completedAt = time
            entries[token.id] = entry
            completedCost += entry.cost
            completedOrder.append(token.id)
            while completedOrder.count > maxCompleted {
                evictFirst()
            }
            return true
        }
    }

    /// Returns the current receipt, or nil when this process has no retained evidence for the ID.
    public func lookup(id: String, now: Double) -> OperationReceipt<Response>? {
        lock.withLock {
            _ = maintain(now: now)
            guard let entry = entries[id] else { return nil }
            return receipt(entry)
        }
    }

    /// The active operation remains visible to health checks even during blocked UI work.
    public func current(now: Double) -> OperationReceipt<Response>? {
        lock.withLock {
            _ = maintain(now: now)
            guard let active, let entry = entries[active.id] else { return nil }
            return receipt(entry)
        }
    }

    private func receipt(_ entry: Entry) -> OperationReceipt<Response> {
        OperationReceipt(
            id: entry.token.id,
            epoch: epoch,
            state: entry.completedAt == nil ? .running : .completed,
            admittedAt: entry.admittedAt,
            completedAt: entry.completedAt,
            response: entry.response
        )
    }

    /// Evicts expired receipts and returns the latest time seen, so a clock regression cannot extend retention.
    /// The caller holds the lock.
    private func maintain(now: Double) -> Double {
        precondition(now.isFinite && now >= 0, "Use finite monotonic uptime")
        latestTime = max(latestTime, now)
        while let first = completedOrder.first, let completedAt = entries[first]?.completedAt,
            latestTime - completedAt >= retention
        {
            evictFirst()
        }
        return latestTime
    }

    private func evictFirst() {
        let id = completedOrder.removeFirst()
        if let removed = entries.removeValue(forKey: id) { completedCost -= removed.cost }
    }
}
