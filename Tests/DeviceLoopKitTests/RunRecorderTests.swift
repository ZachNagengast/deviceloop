//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct RunRecorderTests {
    /// Runs `body` with a run active on a new UDID, then removes the run and the pointer.
    private func recording(_ body: (String, RunStore) async throws -> Void) async throws {
        let udid = "unit-test-\(UUID().uuidString)"
        let run = try RunStore.create(owned: false)
        defer {
            try? FileManager.default.removeItem(at: run.directory)
            try? FileManager.default.removeItem(at: RunRecorder.pointer(udid))
        }
        try RunRecorder.activate(run, on: udid)
        try await body(udid, run)
    }

    @Test func recordWritesAStartedAndFinishedPairForEachOutcome() async throws {
        try await recording { udid, run in
            let result = try await RunRecorder.record(udid, command: "screenshot", args: []) { CommandResult(text: "shot") }
            #expect(result.text == "shot\nrun \(run.id) event 1")
            await #expect(throws: DeviceLoopError.self) {
                try await RunRecorder.record(udid, command: "ui tap", args: ["id=missing"]) {
                    throw DeviceLoopError(.elementNotFound, "No element matches id=missing.")
                }
            }
            await #expect(throws: CancellationError.self) {
                try await RunRecorder.record(udid, command: "ui wait", args: []) { throw CancellationError() }
            }
            let events = try run.events().events
            #expect(events.map(\.kind) == ["started", "finished", "started", "finished", "started", "finished"])
            #expect(events.compactMap(\.started) == [1, 3, 5])
            #expect(events.compactMap(\.outcome) == [.ok, .error, .cancelled])
            #expect(events[3].error?.code == .elementNotFound)
        }
    }

    @Test func recordJournalsAReturnedFlowResultByItsStatus() async throws {
        try await recording { udid, run in
            let mismatch = DeviceLoopError(.textMismatch, #"The field holds "hunter" after typing "hunter2"."#)
            let unreachable = DeviceLoopError(.runnerUnreachable, "The runner did not answer.")
            let screenshot = FlowStepResult(phase: .cleanup, index: 0, kind: "screenshot", status: .failed, error: unreachable)
            let flows = [
                FlowResult(name: "login", status: .passed, steps: [UIDoTests.record(0, .passed)]),
                FlowResult(
                    name: "login", status: .failed,
                    steps: [UIDoTests.record(0, .passed), UIDoTests.record(1, .failed, error: mismatch), UIDoTests.record(2, .skipped)]),
                FlowResult(name: "ui do", status: .cleanupFailed, steps: [UIDoTests.record(0, .passed)], cleanup: [screenshot]),
                FlowResult(name: "ui do", status: .cancelled, steps: [UIDoTests.record(0, .passed), UIDoTests.record(1, .notStarted)]),
            ]
            for flow in flows {
                _ = try await RunRecorder.record(udid, command: "flow run", args: ["login.json"], hiding: ["hunter2"]) {
                    CommandResult(text: flow.name, json: try JSONValue(encoding: flow))
                }
            }
            let finished = try run.events().events.filter { $0.kind == "finished" }
            #expect(finished.map(\.outcome) == [.ok, .error, .error, .cancelled])
            #expect(finished.map(\.error?.code) == [nil, .textMismatch, .runnerUnreachable, nil])
            #expect(finished[1].error?.message == #"The field holds "hunter" after typing "[hidden]"."#)
            #expect(try await run.finalize().outcome == .failed)
        }
    }

    @Test func recordJournalsAResultItsCommandReportsAsFailedAsAnError() async throws {
        try await recording { udid, run in
            let job = CommandResult(text: "tests failed", json: ["status": "failed"])
            let result = try await RunRecorder.record(udid, command: "test run", args: [], failed: { $0.json["status"] == "failed" }) {
                job
            }
            #expect(result.json == job.json)
            let finished = try #require(try run.events().events.last)
            #expect(finished.outcome == .error)
            #expect(finished.error == nil)
            #expect(try await run.finalize().outcome == .failed)
        }
    }

    @Test func recordJournalsTypedTextAsHidden() async throws {
        try await recording { udid, run in
            await #expect(throws: DeviceLoopError.self) {
                try await RunRecorder.record(udid, command: "ui do", args: [#"type "hunter2""#], hiding: [#"type "hunter2""#, "hunter2"]) {
                    throw DeviceLoopError(.textMismatch, #"The field holds "hunter" after typing "hunter2"."#)
                }
            }
            _ = try await RunRecorder.record(udid, command: "ui type", args: ["hunter2"], hiding: ["hunter2"]) {
                CommandResult(text: #"typed "hunter2""#, json: ["readBack": "hunter2"])
            }
            let journal = try String(contentsOf: run.directory.appending(path: "events.jsonl"), encoding: .utf8)
            let results = try String(contentsOf: run.directory.appending(path: "results/3.json"), encoding: .utf8)
            #expect(!journal.contains("hunter2"))
            #expect(!results.contains("hunter2"))
            #expect(try run.events().events[1].error?.message == #"The field holds "hunter" after typing "[hidden]"."#)
        }
    }

    @Test func typedReturnHidesNoEscapedLineBreaks() {
        #expect(RunRecorder.forms(hiding: ["\n", "a\n", ""]) == ["a\\n", "a\n", "\n"])
    }

    @Test func recordHidesTypedTextAsUITextPrintsIt() async throws {
        try await recording { udid, run in
            let typed = "hunter\\2\n"
            await #expect(throws: DeviceLoopError.self) {
                try await RunRecorder.record(udid, command: "ui type", args: ["[hidden]"], hiding: [typed]) {
                    throw DeviceLoopError(.textMismatch, "The field holds \"\(UITree.escaped(typed))\" after typing.")
                }
            }
            let events = try run.events().events
            #expect(events[1].error?.message == #"The field holds "[hidden]" after typing."#)
        }
    }

    @Test func hidingShortTypedTextKeepsTheErrorCode() async throws {
        try await recording { udid, run in
            await #expect(throws: DeviceLoopError.self) {
                try await RunRecorder.record(udid, command: "ui type", args: ["e"], hiding: ["e"]) {
                    throw DeviceLoopError(.elementNotFound, "No element matches id=name.")
                }
            }
            let error = try #require(try run.events().events.last?.error)
            #expect(error.code == .elementNotFound)
            #expect(error.message == "No [hidden]l[hidden]m[hidden]nt match[hidden]s id=nam[hidden].")
        }
    }

    @Test func recordWithoutSavingResultWritesNoResultsFile() async throws {
        try await recording { udid, run in
            let result = try await RunRecorder.record(udid, command: "pasteboard", args: ["paste"], savingResult: false) {
                CommandResult(text: "one-time code 314159", json: ["text": "one-time code 314159"])
            }
            #expect(result.text == "one-time code 314159\nrun \(run.id) event 1")
            #expect(try run.events().events.last?.outcome == .ok)
            #expect(!FileManager.default.fileExists(atPath: run.directory.appending(path: "results/1.json").path))
        }
    }

    @Test func recordCopiesResultFilesFromOutsideTheRun() async throws {
        try await recording { udid, run in
            let outside = FileManager.default.temporaryDirectory.appending(path: "deviceloop-shot-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: outside) }
            try Data("png".utf8).write(to: outside)
            _ = try await RunRecorder.record(udid, command: "screenshot", args: ["-o", .string(outside.path)]) {
                let inside = try Paths.newArtifact("contact", extension: "png")
                try Data("sheet".utf8).write(to: inside)
                return CommandResult(text: "shot", json: ["path": .string(outside.path)], files: [outside, inside])
            }
            let finished = try #require(try run.events().events.last)
            #expect(finished.artifacts.count == 2)
            #expect(finished.artifacts[0] == "artifacts/1-\(outside.lastPathComponent)")
            #expect(finished.artifacts[1].hasPrefix("artifacts/contact-"))
            for path in finished.artifacts {
                #expect(FileManager.default.fileExists(atPath: run.directory.appending(path: path).path))
            }
            let saved = try JSONValue(data: Data(contentsOf: run.directory.appending(path: "results/1.json")))
            #expect(saved["path"] == .string(outside.path))
        }
    }

    @Test func deviceToolSavesTheResultBeforeItsTransform() async throws {
        try await recording { udid, run in
            let target = Target(
                udid: udid, identifier: udid, name: "Test Simulator", kind: .simulator, deviceType: "iPhone", platform: "iOS",
                model: "iPhone 17 Pro", productType: "iPhone18,1", osVersion: "27.1", connectionState: "connected", bootState: "booted")
            let root = TreeNode(ref: "e0", type: "application", label: "Fixture", frame: [0, 0, 430, 932])
            let tree = TreeResult(app: "com.example.app", generation: 1, nodeCount: 1, root: root)
            let tool = MCPTool.device(
                name: "ui_tree", title: "Read UI tree", description: "", readOnly: false, transform: MCPTools.withoutNodeLists
            ) { target, _ in
                CommandResult(text: target.summary, json: try JSONValue(encoding: tree))
            }
            let result = try await tool.run(MCPArguments(tool: "ui_tree", values: [:], resolve: { _ in target }))
            #expect(result.json["root"] == nil)
            let saved = try Data(contentsOf: run.directory.appending(path: "results/1.json"))
            #expect(try JSONDecoder().decode(TreeResult.self, from: saved) == tree)
        }
    }

    @Test func stopFinalizesAFailedRunAndEndsRecording() async throws {
        let target = Target(
            udid: "unit-test-\(UUID().uuidString)", identifier: "unit-test", name: "Test Simulator", kind: .simulator, deviceType: "iPhone",
            platform: "iOS", model: "iPhone 17 Pro", productType: "iPhone18,1", osVersion: "27.1", connectionState: "connected",
            bootState: "booted")
        let run = try RunStore.create(owned: false)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        try RunRecorder.activate(run, on: target.udid)
        _ = try? await RunRecorder.record(target.udid, command: "ui tap", args: ["id=missing"]) {
            throw DeviceLoopError(.elementNotFound, "No element matches id=missing.")
        }
        let report = try await RunCommands.stop(target)
        #expect(report.text.contains("\n1 ui tap id=missing: error element_not_found\n"))
        #expect(try run.manifest().outcome == .failed)
        #expect(RunRecorder.active(target.udid) == nil)
        #expect(!FileManager.default.fileExists(atPath: RunRecorder.pointer(target.udid).path))
    }
}
