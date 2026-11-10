//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Testing

@Suite struct OperationStoreTests {
    @Test func concurrentAdmissionAllowsOnlyOneOperation() async {
        let store = OperationStore<String>()
        let admitted = await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 100 {
                group.addTask {
                    if case .admitted = store.begin(id: UUID().uuidString, fingerprint: "tap", now: 1) { return true }
                    return false
                }
            }
            var count = 0
            for await accepted in group where accepted { count += 1 }
            return count
        }
        #expect(admitted == 1)
        #expect(store.current(now: 2)?.state == .running)
    }

    @Test func reentrantAdmissionFailsWithoutQueuing() throws {
        let store = OperationStore<String>()
        let first = try admit(store, id: "first")
        guard case .busy = store.begin(id: "second", fingerprint: "tap", now: 1) else {
            Issue.record("Reentrant input must return busy")
            return
        }
        #expect(store.lookup(id: "second", now: 1) == nil)
        #expect(store.current(now: 1)?.id == first.id)
    }

    @Test func duplicateRunningRequestCannotExecuteTwice() throws {
        let store = OperationStore<String>()
        _ = try admit(store)
        guard case .inProgress = store.begin(id: "op", fingerprint: "tap", now: 2) else {
            Issue.record("The same running request must stay in progress")
            return
        }
        #expect(store.current(now: 2)?.admittedAt == 1)
    }

    @Test func reusedIdWithDifferentFingerprintConflicts() throws {
        let store = OperationStore<String>()
        let token = try admit(store)
        guard case .conflict = store.begin(id: "op", fingerprint: "different tap", now: 2) else {
            Issue.record("Conflicting running request was not rejected")
            return
        }
        store.finish(token: token, response: "done", now: 3)
        guard case .conflict = store.begin(id: "op", fingerprint: "different tap", now: 4) else {
            Issue.record("Conflicting completed request was not rejected")
            return
        }
    }

    @Test func completedRequestReplaysWhileAnotherOperationRuns() throws {
        let store = OperationStore<String>()
        let first = try admit(store)
        store.finish(token: first, response: "original response", now: 2)
        _ = try admit(store, id: "second", now: 3)
        guard case .replay(let response) = store.begin(id: "op", fingerprint: "tap", now: 4) else {
            Issue.record("A completed duplicate must replay its original response")
            return
        }
        #expect(response == "original response")
        #expect(store.current(now: 4)?.id == "second")
        #expect(store.lookup(id: "op", now: 4)?.completedAt == 2)
    }

    @Test func expiredTerminalReceiptDoesNotRemoveRunningOperation() throws {
        let store = OperationStore<String>(retention: 10)
        let finished = try admit(store)
        store.finish(token: finished, response: "done", now: 2)
        let active = try admit(store, id: "active", now: 3)
        #expect(store.lookup(id: "op", now: 11.9) != nil)
        #expect(store.lookup(id: "op", now: 12) == nil)
        #expect(store.lookup(id: "active", now: 1000)?.state == .running)
        #expect(store.current(now: 1000)?.id == active.id)
    }

    @Test func terminalCapacityEvictsOldestCompletedReceipts() throws {
        let store = OperationStore<String>()
        for index in 0 ..< 129 {
            let token = try admit(store, id: String(index))
            store.finish(token: token, response: String(index), now: 2)
        }
        #expect(store.lookup(id: "0", now: 3) == nil)
        for index in 1 ..< 129 { #expect(store.lookup(id: String(index), now: 3)?.response == String(index)) }
    }

    @Test func staleCompletionCannotReleaseAnotherAdmission() throws {
        let store = OperationStore<String>(retention: 1)
        let original = try admit(store)
        store.finish(token: original, response: "first", now: 2)
        let replacement = try admit(store, now: 3)
        let accepted = store.finish(token: original, response: "late", now: 4)
        #expect(!accepted)
        #expect(store.current(now: 4)?.id == replacement.id)
        #expect(store.lookup(id: "op", now: 4)?.state == .running)
    }

    @Test func anotherEpochCannotCompleteThisStoresOperation() throws {
        let first = OperationStore<String>()
        let second = OperationStore<String>()
        let foreign = try admit(first)
        _ = try admit(second)
        #expect(first.epoch != second.epoch)
        let accepted = second.finish(token: foreign, response: "wrong runner", now: 2)
        #expect(!accepted)
        #expect(second.current(now: 2)?.state == .running)
    }

    @Test func clockRegressionCannotResurrectExpiredReceipts() throws {
        let store = OperationStore<String>(retention: 10)
        let token = try admit(store, now: 10)
        store.finish(token: token, response: "done", now: 11)
        #expect(store.lookup(id: "op", now: 21) == nil)
        #expect(store.lookup(id: "op", now: 1) == nil)
        _ = try admit(store, id: "next", now: 2)
        #expect(store.current(now: 3)?.admittedAt == 21)
    }

    @Test func invalidConfigurationRetainsFiniteBounds() throws {
        let store = OperationStore<String>(maxCompleted: 0, retention: .infinity)
        let first = try admit(store)
        store.finish(token: first, response: "first", now: 2)
        let second = try admit(store, id: "second", now: 3)
        store.finish(token: second, response: "second", now: 4)
        #expect(store.lookup(id: "op", now: 4) == nil)
        #expect(store.lookup(id: "second", now: 4)?.response == "second")
        #expect(store.lookup(id: "second", now: 604) == nil)
    }

    @Test func payloadBudgetEvictsOldestResponses() throws {
        let store = OperationStore<String>(maxCompletedCost: 10)
        let first = try admit(store)
        store.finish(token: first, response: "first", now: 2, cost: 6)
        let second = try admit(store, id: "second", now: 3)
        store.finish(token: second, response: "second", now: 4, cost: 6)
        #expect(store.lookup(id: "op", now: 4) == nil)
        #expect(store.lookup(id: "second", now: 4)?.response == "second")
    }

    @Test func oversizedResponseReleasesAdmissionWithoutRetainingPayload() throws {
        let store = OperationStore<String>(maxCompletedCost: 10)
        let first = try admit(store)
        let accepted = store.finish(token: first, response: "oversized", now: 2, cost: Int.max)
        #expect(accepted)
        #expect(store.current(now: 2) == nil)
        #expect(store.lookup(id: "op", now: 2) == nil)
        _ = try admit(store, id: "next", now: 3)
    }

    private func admit(_ store: OperationStore<String>, id: String = "op", now: Double = 1) throws -> OperationToken {
        guard case .admitted(let token) = store.begin(id: id, fingerprint: "tap", now: now) else {
            throw UnexpectedAdmission()
        }
        return token
    }

    private struct UnexpectedAdmission: Error {}
}
