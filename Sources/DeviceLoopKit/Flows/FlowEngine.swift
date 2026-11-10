//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// Runs a flow's setup, steps and cleanup in order through an injected executor.
public enum FlowEngine {
    /// Performs one step and throws when it does not pass. Setup and flow steps arrive with `timeoutMs` cut to the time left in the flow.
    public typealias Executor = @Sendable (FlowStep) async throws -> Void
    /// Receives each step's record, with `startMs` set, as the step is dispatched.
    public typealias Progress = @Sendable (FlowStepResult) -> Void

    /// Stops setup and steps at the first step that does not pass, then runs every cleanup step.
    public static func run(_ flow: Flow, progress: @escaping Progress = { _ in }, execute: @escaping Executor) async -> FlowResult {
        await run(
            flow.name, timeoutMs: flow.timeoutMs, setup: flow.setup, steps: flow.steps, cleanup: flow.cleanup, progress: progress,
            execute: execute)
    }

    /// Runs steps that did not come from a flow file. A nil `timeoutMs` sets no deadline for the whole run.
    static func run(
        _ name: String, timeoutMs: Int?, setup: [FlowStep], steps: [FlowStep], cleanup: [FlowStep],
        progress: @escaping Progress = { _ in }, execute: @escaping Executor
    ) async -> FlowResult {
        let start = ContinuousClock.now
        let deadline = timeoutMs.map { start.advanced(by: .milliseconds($0)) }
        var result = FlowResult(name: name, status: .passed)
        let setupAndSteps = setup.enumerated().map { (FlowStepResult.Phase.setup, $0, $1) } + steps.enumerated().map { (.steps, $0, $1) }
        for (phase, index, step) in setupAndSteps {
            var record = FlowStepResult(phase: phase, index: index, kind: step.kind, status: .skipped)
            if result.status == .passed {
                let remainingMs = deadline.map { Int(ContinuousClock.now.duration(to: $0) / .milliseconds(1)) } ?? step.timeoutMs
                if Task.isCancelled {
                    record.status = .notStarted
                    result.status = .cancelled
                } else if let timeoutMs, remainingMs < 1 {
                    record.status = .notStarted
                    record.error = DeviceLoopError(
                        .timeout, "The flow deadline of \(timeoutMs) ms passed before this step.",
                        fix: "Raise timeoutMs in the flow file.")
                    result.status = .failed
                } else {
                    var bounded = step
                    bounded.timeoutMs = min(step.timeoutMs, remainingMs)
                    record = await dispatch(bounded, record, since: start, progress: progress, execute: execute)
                    if record.status != .passed { result.status = .failed }
                }
            }
            result.steps.append(record)
        }
        for (index, step) in cleanup.enumerated() {
            let record = FlowStepResult(phase: .cleanup, index: index, kind: step.kind, status: .skipped)
            result.cleanup.append(await dispatch(step, record, since: start, progress: progress, execute: execute))
        }
        if result.status == .passed, result.cleanup.contains(where: { $0.status != .passed }) {
            result.status = .cleanupFailed
        }
        return result
    }

    /// Runs `body` in a task that SIGINT or SIGTERM cancels instead of ending the process. Throws CancellationError
    /// when `body` throws after a signal.
    public static func cancellingOnInterrupt<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await cancellingOnInterrupt(interrupt: InterruptFlag(), body)
    }

    static func cancellingOnInterrupt<T: Sendable>(
        interrupt: InterruptFlag, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        defer { interrupt.remove() }
        let task = Task { try await body() }
        let watcher = Task {
            _ = await interrupt.sleep(seconds: nil)
            if interrupt.isRaised { task.cancel() }
        }
        defer { watcher.cancel() }
        do {
            return try await task.value
        } catch {
            throw interrupt.isRaised ? CancellationError() : error
        }
    }

    /// Runs one step in an unstructured task, which does not inherit the flow's cancellation.
    private static func dispatch(
        _ step: FlowStep, _ record: FlowStepResult, since start: ContinuousClock.Instant, progress: Progress,
        execute: @escaping Executor
    ) async -> FlowStepResult {
        var record = record
        record.startMs = Int(start.duration(to: .now) / .milliseconds(1))
        progress(record)
        do {
            try await Task { try await execute(step) }.value
            record.status = .passed
        } catch let error as DeviceLoopError {
            record.status = error.code == .actionOutcomeUnknown ? .unknown : .failed
            record.error = error
        } catch {
            record.status = .failed
            record.error = DeviceLoopError(.internalError, "\(error)")
        }
        record.endMs = Int(start.duration(to: .now) / .milliseconds(1))
        return record
    }
}

/// The outcome of one flow run, schema `deviceloop.flow-result/1`.
public struct FlowResult: Encodable, Sendable {
    public enum Status: String, Encodable, Sendable {
        case passed, failed, cancelled
        /// Setup and steps passed and a cleanup step did not.
        case cleanupFailed = "cleanup_failed"

        /// CLI exit status: 0 when passed, 130 when cancelled, otherwise 1.
        public var exitCode: Int32 {
            switch self {
                case .passed: return 0
                case .cancelled: return 130
                case .failed, .cleanupFailed: return 1
            }
        }
    }

    /// What the run reset before setup: nothing, the app process, or the app and its data.
    public enum Isolation: String, Encodable, Sendable {
        case none, processRestart, reinstalled
    }

    /// The flow app as installed when setup started.
    public struct App: Encodable, Sendable, Equatable {
        public var bundleID: String
        public var version: String?
        public var build: String?
    }

    public var schema = "deviceloop.flow-result/1"
    public var name: String
    public var status: Status
    public var app: App?
    public var isolation: Isolation?
    /// State the reset leaves in place.
    public var notReset: [String]?
    /// Setup steps, then flow steps.
    public var steps: [FlowStepResult] = []
    public var cleanup: [FlowStepResult] = []
    /// Files saved by screenshot steps, relative to the run directory, in the order taken.
    public var screenshots: [String] = []
    /// The screenshot taken when the first step failed, relative to the run directory.
    public var failureScreenshot: String?
}

/// One step of a flow run. Times are monotonic milliseconds since the run started.
public struct FlowStepResult: Encodable, Sendable {
    public enum Phase: String, Encodable, Sendable {
        case setup, steps, cleanup
    }

    public enum Status: String, Encodable, Sendable {
        case passed, failed, unknown, skipped, notStarted
    }

    public var phase: Phase
    /// Position in the flow file's `setup`, `steps` or `cleanup` array.
    public var index: Int
    public var kind: String
    public var status: Status
    /// The step's error, with the runner receipt when the runner may have admitted the request.
    public var error: DeviceLoopError?
    public var startMs: Int?
    public var endMs: Int?
}

extension FlowStep {
    /// The step kind as written in a flow file.
    var kind: String {
        switch action {
            case .ui(.tap(_, let count, let holdMs)): return holdMs != nil ? "hold" : count == 2 ? "doubletap" : "tap"
            case .ui(.swipe): return "swipe"
            case .ui(.drag): return "drag"
            case .ui(.type): return "type"
            case .ui(.press): return "press"
            case .ui(.launch): return "launch"
            case .ui(.openURL): return "open"
            case .ui(.sleep): return "sleep"
            case .assert: return "assert"
            case .settle: return "settle"
            case .screenshot: return "screenshot"
            case .alert: return "alert"
        }
    }
}
