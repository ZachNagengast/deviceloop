//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Testing

/// Runs the live suites one after another, since they launch and terminate apps on the same simulator.
struct SharedSimulator: SuiteTrait, TestScoping {
    private static let turns = Turns()

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        await Self.turns.take()
        do {
            try await function()
        } catch {
            await Self.turns.give()
            throw error
        }
        await Self.turns.give()
    }

    private actor Turns {
        private var taken = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func take() async {
            guard taken else {
                taken = true
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }

        func give() {
            if waiting.isEmpty {
                taken = false
            } else {
                waiting.removeFirst().resume()
            }
        }
    }
}

extension Trait where Self == SharedSimulator {
    static var sharedSimulator: Self { Self() }
}
