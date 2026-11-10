//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Synchronization

/// A `test run` job this server started, and its result once it finishes.
final class ServerTestJob: Sendable {
    let job: TestJob
    let outcome = Mutex<Result<CommandResult, any Error>?>(nil)

    init(job: TestJob) {
        self.job = job
    }
}

extension MCPTools {
    /// Jobs this server process started, by job name.
    static let testJobs = Mutex<[String: ServerTestJob]>([:])

    static let testTools: [MCPTool] = [
        MCPTool(
            name: "test_run",
            title: "Run tests",
            description: """
                Run the XCTest and Swift Testing tests of a project, workspace or prebuilt .xctestrun with xcodebuild on a \
                device or simulator. Waits up to wait_seconds and returns the summary with failures and metrics, or the \
                running job for test_status and test_cancel. A failed or cancelled job is an error result. Cancelling the \
                call cancels the job. Fails with device_busy while the UI runner or another test job uses the target.
                """,
            properties: [
                "project": Param.string("Path to the .xcodeproj."),
                "workspace": Param.string("Path to the .xcworkspace."),
                "xctestrun": Param.string("Path to a .xctestrun from xcodebuild build-for-testing, instead of a project or workspace."),
                "scheme": Param.string("Scheme to test, with project or workspace."),
                "test_plan": Param.string("Test plan of the scheme."),
                "only_testing": Param.strings("Run only these test identifiers, for example Target/Class/test()."),
                "skip_testing": Param.strings("Skip these test identifiers."),
                "configuration": Param.string("Build configuration, for example Debug."),
                "stop_runner": Param.boolean("Stop a running UI runner on the target first."),
                "wait_seconds": Param.integer("Seconds to wait for the job to finish before returning it as running.", default: 45),
                "device": Param.device,
            ],
            readOnly: false,
            failed: failedJob
        ) { arguments in
            let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, try arguments.int("wait_seconds") ?? 45)))
            try checkTestSource(arguments)
            let target = try await arguments.target()
            return try await arguments.record(target.udid) {
                let job = try await TestCommands.start(
                    target,
                    project: arguments.string("project").map { MCPArguments.fileURL($0).path },
                    workspace: arguments.string("workspace").map { MCPArguments.fileURL($0).path },
                    xctestrun: arguments.string("xctestrun").map { MCPArguments.fileURL($0).path },
                    scheme: arguments.string("scheme"), testPlan: arguments.string("test_plan"),
                    onlyTesting: arguments.strings("only_testing") ?? [], skipTesting: arguments.strings("skip_testing") ?? [],
                    configuration: arguments.string("configuration"), stopRunner: arguments.bool("stop_runner") ?? false
                )
                return try await follow(track(job), until: deadline)
            }
        },
        MCPTool(
            name: "test_status",
            title: "Test job status",
            description: """
                Wait up to wait_seconds for a test_run job and return its summary, or that it is still running. A finished \
                job started elsewhere is read from its summary.json.
                """,
            properties: [
                "job": Param.string("Job from test_run, for example test-20261108-131927-412-3f9a2c."),
                "wait_seconds": Param.integer("Seconds to wait for the job to finish.", default: 45),
            ],
            required: ["job"],
            readOnly: true,
            failed: failedJob
        ) { arguments in
            let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, try arguments.int("wait_seconds") ?? 45)))
            let name = try arguments.require("job")
            guard let entry = testJobs.withLock({ $0[name] }) else { return try TestCommands.saved(job: name) }
            return try await report(entry, until: deadline)
        },
        MCPTool(
            name: "test_cancel",
            title: "Cancel test job",
            description: """
                Cancel a test_run job of this server: xcodebuild gets SIGINT and up to 60 s to finish the result bundle. \
                Returns at once. test_status then reports the job as cancelled.
                """,
            properties: ["job": Param.string("Job from test_run.")],
            required: ["job"],
            readOnly: false,
            idempotent: true,
            failed: failedJob
        ) { arguments in
            let name = try arguments.require("job")
            guard let entry = testJobs.withLock({ $0[name] }) else {
                throw DeviceLoopError(
                    .badArguments, "Test job \(name) was not started by this server.",
                    fix: "Cancel it where it was started. The device_busy error for its device names the xcodebuild pid.")
            }
            entry.job.interrupt.raise()
            return try await report(entry, until: .now)
        },
    ]

    /// Checks project, workspace, xctestrun and scheme before the target is resolved.
    static func checkTestSource(_ arguments: MCPArguments) throws {
        let sources = ["project", "workspace", "xctestrun"].filter { arguments.values[$0] != nil }
        guard sources.count == 1 else {
            throw DeviceLoopError(
                .badArguments, "test_run needs exactly one of project, workspace or xctestrun.",
                fix: "For example: {\"project\": \"App.xcodeproj\", \"scheme\": \"App\"}")
        }
        if sources == ["xctestrun"] {
            if let other = ["scheme", "test_plan", "configuration"].first(where: { arguments.values[$0] != nil }) {
                throw DeviceLoopError(
                    .badArguments, "test_run \(other) does not apply to xctestrun.",
                    fix: "Leave out scheme, test_plan and configuration, or pass project or workspace in place of xctestrun.")
            }
        } else if arguments.values["scheme"] == nil {
            throw DeviceLoopError(
                .badArguments, "test_run needs scheme with \(sources[0]).", fix: "Pass the scheme that holds the tests.")
        }
    }

    /// Waits until every job this server started has finished and written its summary.json.
    static func waitForTestJobs() async throws {
        for entry in testJobs.withLock({ Array($0.values) }) {
            while entry.outcome.withLock({ $0 }) == nil { try await Task.sleep(for: .milliseconds(200)) }
        }
    }

    /// Registers the job and finishes it in the background.
    static func track(_ job: TestJob) -> ServerTestJob {
        let entry = ServerTestJob(job: job)
        testJobs.withLock { $0[job.name] = entry }
        Task.detached {
            do {
                let result = try await TestCommands.finish(job, timeout: .seconds(3600))
                entry.outcome.withLock { $0 = .success(result) }
            } catch {
                entry.outcome.withLock { $0 = .failure(error) }
            }
        }
        return entry
    }

    /// Whether the job's tests or build failed, or it was cancelled, as `test run` exits non-zero for.
    static func failedJob(_ result: CommandResult) -> Bool {
        ["failed", "cancelled"].contains(result.json["status"]?.string ?? "")
    }

    /// Like `report`, and interrupts the job when the call is cancelled.
    static func follow(_ entry: ServerTestJob, until deadline: ContinuousClock.Instant) async throws -> CommandResult {
        do {
            return try await report(entry, until: deadline)
        } catch is CancellationError {
            entry.job.interrupt.raise()
            throw CancellationError()
        }
    }

    /// The job's result once it finishes by `deadline`, otherwise that it is running or cancelling.
    static func report(_ entry: ServerTestJob, until deadline: ContinuousClock.Instant) async throws -> CommandResult {
        while entry.outcome.withLock({ $0 }) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        if let outcome = entry.outcome.withLock({ $0 }) { return try outcome.get() }
        let job = entry.job
        let status = job.interrupt.isRaised ? "cancelling" : "running"
        return CommandResult(
            text: "\(job.target.summary)\nTest job \(job.name) is \(status).\n\(job.directory.path)",
            json: [
                "job": .string(job.name), "status": .string(status), "device": .string(job.target.udid),
                "directory": .string(job.directory.path),
            ]
        )
    }
}
