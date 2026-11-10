//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Synchronization

extension MCPTools {
    static let flowJobs = FlowJobs()

    static let flow = flowTools(jobs: flowJobs, wait: .seconds(45)) { target, arguments, flow, runID, progress in
        try await FlowCommands.run(
            target, flow: flow, app: arguments.string("app"), timeoutMs: arguments.int("timeout_ms"), runID: runID, progress: progress)
    }

    /// flow_validate, flow_run, flow_status, flow_cancel and flow_export. flow_run runs `start` as a job in `jobs`, journaled in the
    /// target's active run until the flow ends. flow_run, flow_status and flow_cancel return the result when the run finishes within
    /// `wait`, otherwise the run ID and the step in progress.
    static func flowTools(
        jobs: FlowJobs, wait: Duration,
        start:
            @escaping @Sendable (Target, MCPArguments, JSONValue, _ runID: String, @escaping FlowEngine.Progress) async throws ->
            CommandResult
    ) -> [MCPTool] {
        let flowSource: [String: JSONValue] = [
            "path": Param.string("Path to a flow JSON file on this Mac."),
            "flow": ["type": "object", "description": "The flow itself, the same JSON as a flow file."],
        ]
        let runIDProperty = ["run_id": Param.string("The run_id that flow_run returned.")]
        let waitSeconds = wait.components.seconds
        let failed: @Sendable (CommandResult) -> Bool = { result in
            result.json["status"]?.string.flatMap(FlowResult.Status.init).map { $0 != .passed } ?? false
        }
        return [
            MCPTool(
                name: "flow_validate",
                title: "Check flow",
                description:
                    "Check a flow (schema deviceloop.flow/1) without a device and list what it needs from the target. Pass `path` or `flow`.",
                properties: flowSource,
                readOnly: true,
                idempotent: true
            ) { arguments in
                try FlowCommands.validate(flowJSON(arguments))
            },
            MCPTool(
                name: "flow_run",
                title: "Run flow",
                description: """
                    Run a flow (schema deviceloop.flow/1) of taps, swipes, typing, asserts and screenshots on a device or simulator. \
                    Pass `path` or `flow`. Steps stop at the first failure, then cleanup runs. Returns the result within \
                    \(waitSeconds) s, or a run_id for flow_status while the flow still runs. A failed flow is an error result with \
                    every step's status. While it runs, other DeviceLoop UI commands and flow runs on the device fail with device_busy.
                    """,
                properties: flowSource.merging([
                    "device": Param.device,
                    "app": Param.string("Bundle ID to use instead of app.bundleID in the flow."),
                    "timeout_ms": Param.integer("Deadline for the whole flow in milliseconds, instead of timeoutMs in the flow."),
                ]) { own, _ in own },
                readOnly: false,
                destructive: true,
                failed: failed
            ) { arguments in
                let flow = try flowJSON(arguments)
                let target = try await arguments.target()
                let runID = FlowCommands.newRunID()
                jobs.start(runID, on: target) { progress in
                    try await arguments.record(target.udid) { try await start(target, arguments, flow, runID, progress) }
                }
                do {
                    return try await jobs.result(runID, waiting: wait)
                } catch is CancellationError {
                    try? jobs.cancel(runID)
                    throw CancellationError()
                }
            },
            MCPTool(
                name: "flow_status",
                title: "Flow status",
                description: "The result of a flow_run run, waiting up to \(waitSeconds) s for it to finish, or the step in progress.",
                properties: runIDProperty,
                readOnly: true,
                failed: failed
            ) { arguments in
                try await jobs.result(arguments.require("run_id"), waiting: wait)
            },
            MCPTool(
                name: "flow_cancel",
                title: "Cancel flow",
                description: """
                    Stop a flow_run run before its next step. The step in progress finishes and cleanup still runs. \
                    Returns the result within \(waitSeconds) s, or the step in progress.
                    """,
                properties: runIDProperty,
                readOnly: false,
                idempotent: true,
                failed: failed
            ) { arguments in
                let runID = try arguments.require("run_id")
                try jobs.cancel(runID)
                return try await jobs.result(runID, waiting: wait)
            },
            MCPTool(
                name: "flow_export",
                title: "Export flow to XCTest",
                description: """
                    Write a flow (schema deviceloop.flow/1) as a new .swift file on this Mac with one XCTestCase class and one UI \
                    test method. Pass `path` or `flow`. Does not replace a file or edit an Xcode project. Lists the fragile steps \
                    (points, drags, sleeps), and fails with every step it cannot export: settle, type with clear and reset reinstall.
                    """,
                properties: flowSource.merging([
                    "output": Param.string("Path of the new .swift file."),
                    "class": Param.string("Test class name. Defaults to the flow name followed by FlowTests."),
                    "app": Param.string("Bundle ID to use instead of app.bundleID in the flow."),
                ]) { own, _ in own },
                required: ["output"],
                readOnly: false
            ) { arguments in
                try FlowCommands.export(
                    flowJSON(arguments), to: MCPArguments.fileURL(arguments.require("output")), className: arguments.string("class"),
                    app: arguments.string("app"))
            },
        ]
    }

    /// The `flow` argument, or the flow file at `path`.
    static func flowJSON(_ arguments: MCPArguments) throws -> JSONValue {
        switch (try arguments.string("path"), arguments.values["flow"]) {
            case (let path?, nil): return try FlowCommands.load(MCPArguments.fileURL(path).path)
            case (nil, let flow?): return flow
            default:
                throw DeviceLoopError(
                    .badArguments, "\(arguments.tool) needs path or flow, not both.",
                    fix: "Pass a flow file as path, or the flow JSON as flow.")
        }
    }
}

/// Flow runs started by flow_run. They last as long as the MCP server process. Their result.json stays on disk.
final class FlowJobs: Sendable {
    private struct Job: Sendable {
        let target: Target
        let task: Task<CommandResult, Error>
        let started: ContinuousClock.Instant
        let state: State
    }

    /// The step in progress and whether the run has finished, written by the run's task.
    private final class State: Sendable {
        let current = Mutex<FlowStepResult?>(nil)
        let finished = Mutex(false)
    }

    private let jobs = Mutex<[String: Job]>([:])

    /// Starts `run` as run `id` on `target` in a task that the caller's cancellation does not reach.
    func start(
        _ id: String, on target: Target, _ run: @escaping @Sendable (@escaping FlowEngine.Progress) async throws -> CommandResult
    ) {
        let state = State()
        let task = Task {
            defer { state.finished.withLock { $0 = true } }
            do {
                return try await run { record in state.current.withLock { $0 = record } }
            } catch {
                throw Task.isCancelled ? CancellationError() : error
            }
        }
        jobs.withLock { $0[id] = Job(target: target, task: task, started: .now, state: state) }
    }

    /// Cancels every run and returns once each has finished its cleanup and result.json.
    func finishAll() async {
        let tasks = jobs.withLock { $0.values.map(\.task) }
        for task in tasks { task.cancel() }
        for task in tasks { _ = try? await task.value }
    }

    /// Stops run `id` before its next step. Its cleanup still runs.
    func cancel(_ id: String) throws {
        try job(id).task.cancel()
    }

    /// The run's result when it finishes within `limit`, otherwise its ID, status and the step in progress.
    func result(_ id: String, waiting limit: Duration) async throws -> CommandResult {
        let job = try job(id)
        let deadline = ContinuousClock.now.advanced(by: limit)
        while !job.state.finished.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard job.state.finished.withLock({ $0 }) else { return running(id, job) }
        do {
            return try await job.task.value
        } catch is CancellationError {
            return CommandResult(
                text: "\(job.target.summary)\nrun \(id) cancelled before the first step",
                json: ["runId": .string(id), "status": "cancelled", "device": .string(job.target.udid)])
        }
    }

    private func running(_ id: String, _ job: Job) -> CommandResult {
        let status = job.task.isCancelled ? "cancelling" : "running"
        let elapsedMs = Int(job.started.duration(to: .now) / .milliseconds(1))
        let current = job.state.current.withLock { $0 }.map { "\($0.phase.rawValue)[\($0.index)] \($0.kind)" }
        let next =
            job.task.isCancelled
            ? "The step in progress finishes, then cleanup runs. Call flow_status with this run_id for the result."
            : "Call flow_status with this run_id for the result, or flow_cancel to stop it."
        return CommandResult(
            text: "\(job.target.summary)\nrun \(id) \(status) for \(elapsedMs / 1000) s\(current.map { ", at \($0)" } ?? "")\n\(next)",
            json: [
                "runId": .string(id), "status": .string(status), "elapsedMs": .number(Double(elapsedMs)),
                "current": current.map(JSONValue.string) ?? .null, "device": .string(job.target.udid),
            ]
        )
    }

    private func job(_ id: String) throws -> Job {
        guard let job = jobs.withLock({ $0[id] }) else {
            throw DeviceLoopError(
                .badArguments, "No flow run \(id) in this MCP server.",
                fix: "Pass the run_id that flow_run returned. Runs last until the MCP server exits. Their result.json stays on disk.")
        }
        return job
    }
}
