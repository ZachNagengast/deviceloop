//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Synchronization
import Testing

@testable import DeviceLoopKit

@Suite struct MCPServerTests {
    final class Outbox: Sendable {
        let lines = Mutex<[String]>([])
    }

    /// Feeds `lines` through a session as stdin and returns every message it wrote to stdout.
    func exchange(
        _ lines: [String], tools: [MCPTool] = MCPTools.all, resolve: @escaping MCPArguments.Resolve = TargetResolver.resolve
    ) async throws -> [JSONValue] {
        let (input, continuation) = AsyncStream<UInt8>.makeStream()
        for byte in (lines.joined(separator: "\n") + "\n").utf8 { continuation.yield(byte) }
        continuation.finish()
        let outbox = Outbox()
        let session = MCPSession(tools: tools, serverVersion: "test", resolve: resolve) { line in
            outbox.lines.withLock { $0.append(line) }
        }
        try await session.run(input)
        return try outbox.lines.withLock { $0 }.map { try JSONValue(data: Data($0.utf8)) }
    }

    func request(_ id: Int, _ method: String, _ params: JSONValue = [:]) throws -> String {
        let message: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params]
        return String(decoding: try message.data(), as: UTF8.self)
    }

    func call(_ id: Int, _ tool: String, _ arguments: JSONValue = [:]) throws -> String {
        try request(id, "tools/call", ["name": .string(tool), "arguments": arguments])
    }

    /// A simulator target with a new UDID.
    static func simulator(platform: String = "iOS") -> Target {
        Target(
            udid: "unit-test-\(UUID().uuidString)", identifier: "unit-test", name: "Test Simulator", kind: .simulator, deviceType: "iPhone",
            platform: platform, model: "iPhone 17 Pro", productType: "iPhone18,1", osVersion: "27.1", connectionState: "connected",
            bootState: "booted")
    }

    /// Runs `body` with a run active on `target`, then removes the run and the pointer.
    func recording(on target: Target, _ body: (RunStore) async throws -> Void) async throws {
        let run = try RunStore.create(owned: false)
        defer {
            try? FileManager.default.removeItem(at: run.directory)
            try? FileManager.default.removeItem(at: RunRecorder.pointer(target.udid))
        }
        try RunRecorder.activate(run, on: target.udid)
        try await body(run)
    }

    /// The text of events.jsonl and results/1.json in `run`.
    func journalAndFirstResult(_ run: RunStore) throws -> String {
        try String(contentsOf: run.directory.appending(path: "events.jsonl"), encoding: .utf8)
            + String(contentsOf: run.directory.appending(path: "results/1.json"), encoding: .utf8)
    }

    @Test func initializeAnswersWithTheRequestedSupportedVersion() async throws {
        let replies = try await exchange([request(1, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:]])])
        #expect(replies.count == 1)
        #expect(replies[0].value(at: "result.protocolVersion") == "2025-06-18")
        #expect(replies[0].value(at: "result.serverInfo.name") == "deviceloop")
        #expect(replies[0].value(at: "result.capabilities.tools") != nil)
    }

    @Test func initializeAnswersLatestVersionForAnUnknownOne() async throws {
        let replies = try await exchange([request(1, "initialize", ["protocolVersion": "2024-11-05"])])
        #expect(replies[0].value(at: "result.protocolVersion") == "2025-11-25")
    }

    @Test func notificationsGetNoResponse() async throws {
        let replies = try await exchange([#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, request(2, "ping")])
        #expect(replies == [["jsonrpc": "2.0", "id": 2, "result": [:]]])
    }

    @Test func toolsListNamesEveryToolInOrder() async throws {
        let replies = try await exchange([request(1, "tools/list")])
        let names = replies[0].value(at: "result.tools")?.array?.compactMap { $0["name"]?.string }
        #expect(
            names == [
                "device_list", "device_info", "device_doctor", "device_view", "screen_capture", "app_list", "app_install",
                "app_uninstall", "app_launch", "app_terminate", "url_open", "device_set", "pasteboard", "crash_list", "crash_pull",
                "video_record", "video_capture", "video_inspect",
                "device_lock", "system_control", "device_siri", "device_operation", "device_state", "state_scope",
                "state_restore", "device_prepare", "test_run", "test_status", "test_cancel", "app_logs",
                "app_files", "trace_record",
                "ui_tree", "ui_tap", "ui_type", "ui_swipe", "ui_drag", "ui_press", "ui_find", "ui_wait", "ui_alert", "ui_audit",
                "runner_status", "runner_stop",
                "flow_validate", "flow_run", "flow_status", "flow_cancel", "flow_export",
                "run",
            ]
        )
    }

    @Test func traceRecordRequiresAppAndBoundsTheDuration() async throws {
        let replies = try await exchange([request(1, "tools/list")])
        let tool = replies[0].value(at: "result.tools")?.array?.first { $0["name"]?.string == "trace_record" }
        #expect(tool?.value(at: "inputSchema.required") == ["app"])
        #expect(tool?.value(at: "inputSchema.properties.duration_ms.minimum") == 1)
        #expect(tool?.value(at: "inputSchema.properties.duration_ms.maximum") == 60000)
    }

    @Test func destructiveToolsAreMarked() async throws {
        let replies = try await exchange([request(1, "tools/list")])
        let tools = replies[0].value(at: "result.tools")?.array ?? []
        let destructive = Set(tools.filter { $0.value(at: "annotations.destructiveHint") == true }.compactMap { $0["name"]?.string })
        #expect(
            destructive == [
                "app_uninstall", "device_set", "pasteboard", "device_lock", "system_control", "device_siri", "state_restore", "app_files",
                "flow_run", "ui_tap", "ui_type", "ui_swipe", "ui_drag", "ui_press", "ui_alert", "video_capture",
            ])
    }

    @Test func observationToolsAreReadOnly() async throws {
        let replies = try await exchange([request(1, "tools/list")])
        let tools = replies[0].value(at: "result.tools")?.array ?? []
        let readOnly = Set(tools.filter { $0.value(at: "annotations.readOnlyHint") == true }.compactMap { $0["name"]?.string })
        #expect(
            readOnly == [
                "device_list", "device_info", "device_doctor", "screen_capture", "app_list", "crash_list", "video_inspect",
                "device_operation", "runner_status", "test_status", "flow_validate", "flow_status",
            ])
    }

    @Test func idempotentToolsAreMarked() async throws {
        let replies = try await exchange([request(1, "tools/list")])
        let tools = replies[0].value(at: "result.tools")?.array ?? []
        let idempotent = Set(tools.filter { $0.value(at: "annotations.idempotentHint") == true }.compactMap { $0["name"]?.string })
        #expect(
            idempotent == [
                "device_view", "app_install", "app_uninstall", "app_terminate", "device_set", "pasteboard", "crash_pull", "runner_stop",
                "test_cancel", "flow_validate", "flow_cancel",
            ])
    }

    @Test func stateScopeStatusReportsATargetWithNoScope() async throws {
        let target = Self.simulator()
        let replies = try await exchange([call(1, "state_scope", ["action": "status"])]) { _ in target }
        #expect(replies[0].value(at: "result.isError") == false)
        #expect(replies[0].value(at: "result.structuredContent.open") == false)
    }

    @Test func uiTreeBoundsRowsByDefault() async throws {
        let replies = try await exchange([request(1, "tools/list")])
        let tool = replies[0].value(at: "result.tools")?.array?.first { $0["name"]?.string == "ui_tree" }
        #expect(tool?.value(at: "inputSchema.properties.max_rows.default") == 200)
    }

    @Test func uiSwipeRejectsAnUnknownDirectionBeforeResolvingADevice() async throws {
        let replies = try await exchange([call(1, "ui_swipe", ["direction": "sideways"])])
        let text = replies[0].value(at: "result.content")?[0]?["text"]?.string ?? ""
        #expect(text.hasPrefix("ERROR bad_arguments: ui_swipe direction must be up, down, left or right, got sideways."))
    }

    @Test func uiDragRejectsPointsThatAreNotXY() async throws {
        let replies = try await exchange([call(1, "ui_drag", ["from": "200,700", "to": "top"])])
        let text = replies[0].value(at: "result.content")?[0]?["text"]?.string ?? ""
        #expect(text.hasPrefix("ERROR bad_arguments: ui_drag from and to must be x,y points"))
    }

    @Test func uiPressRejectsAButtonTheRunnerDoesNotPress() async throws {
        let replies = try await exchange([call(1, "ui_press", ["button": "back"])])
        let text = replies[0].value(at: "result.content")?[0]?["text"]?.string ?? ""
        #expect(text.hasPrefix("ERROR bad_arguments: ui_press button must be one of home, volumeUp, volumeDown, action, camera, got back."))
    }

    @Test func uiTapRejectsANonIntegerCount() async throws {
        let replies = try await exchange([call(1, "ui_tap", ["element": "@e5", "count": "twice"])])
        let text = replies[0].value(at: "result.content")?[0]?["text"]?.string ?? ""
        #expect(text.hasPrefix("ERROR bad_arguments: ui_tap argument count must be an integer."))
    }

    @Test func systemControlAcceptsEveryAdvertisedSetting() async throws {
        let replies = try await exchange([request(1, "tools/list")])
        let tool = replies[0].value(at: "result.tools")?.array?.first { $0["name"]?.string == "system_control" }
        let settings = tool?.value(at: "inputSchema.properties.setting.enum")?.array?.compactMap(\.string) ?? []
        #expect(settings.count == 7)
        for setting in settings {
            let value = ["brightness", "volume"].contains(setting) ? "50" : "on"
            #expect(throws: Never.self) { try SiriCommands.Control(setting: setting, value: value) }
        }
    }

    @Test func appListTakesARunningFlag() async throws {
        let replies = try await exchange([request(1, "tools/list")])
        let tool = replies[0].value(at: "result.tools")?.array?.first { $0["name"]?.string == "app_list" }
        #expect(tool?.value(at: "inputSchema.properties.running.type") == "boolean")
    }

    @Test func screenCaptureTakesNoOutputPath() async throws {
        let replies = try await exchange([call(1, "screen_capture", ["output": "/tmp/shot.png"])])
        let text = replies[0].value(at: "result.content")?[0]?["text"]?.string ?? ""
        #expect(text.hasPrefix("ERROR bad_arguments: screen_capture has no argument output."))
    }

    @Test func deviceSetReportsPartialFailure() async throws {
        let target = Self.simulator()
        let result = try await MCPTools.combine(
            [
                ("appearance", { CommandResult(text: "\(target.summary)\nAppearance set to dark", json: ["userInterfaceStyle": "dark"]) }),
                ("orientation", { throw DeviceLoopError(.badArguments, "Unknown orientation sideways.") }),
            ],
            on: target
        )
        let lines = result.text.split(separator: "\n").map(String.init)
        #expect(lines.prefix(3) == ["ERROR partial: orientation failed, the rest applied", target.summary, "Appearance set to dark"])
        #expect(result.json["ok"] == false)
        #expect(result.json["failed"] == ["orientation"])
        #expect(result.json.value(at: "appearance.userInterfaceStyle") == "dark")
        let deviceSet = try #require(MCPTools.all.first { $0.name == "device_set" })
        #expect(deviceSet.failed(result))
    }

    @Test func deviceSetRejectsALocationThatIsNotLatLon() async throws {
        let deviceSet = try #require(MCPTools.all.first { $0.name == "device_set" })
        for location in ["37.3,abc,-122", "1,,2", "91,0"] {
            let reply = await deviceSet.call(["location": .string(location)], resolve: { _ in Self.simulator() }, log: Self.discardedLog)
            #expect(reply.value(at: "structuredContent.error.code") == "bad_arguments")
        }
    }

    @Test func deviceSetLocationTakesLatLonOrClear() throws {
        let set = try MCPTools.parseLocation("37.3349, -122.0090")
        #expect([set.latitude, set.longitude] == [37.3349, -122.009])
        for clear in ["clear", "CLEAR"] {
            let cleared = try MCPTools.parseLocation(clear)
            #expect([cleared.latitude, cleared.longitude] == [nil, nil])
        }
    }

    @Test func missingRequiredArgumentIsAToolError() async throws {
        let replies = try await exchange([call(1, "app_uninstall")])
        #expect(replies[0].value(at: "result.isError") == true)
        let text = replies[0].value(at: "result.content")?[0]?["text"]?.string ?? ""
        #expect(text.hasPrefix("ERROR bad_arguments: app_uninstall needs bundle_id."))
        #expect(replies[0].value(at: "result.structuredContent.error.code") == "bad_arguments")
    }

    @Test func appLogsStartRejectsArgumentsOfTheOtherCaptureKind() async throws {
        let replies = try await exchange([
            call(1, "app_logs", ["action": "start", "system": true, "bundle_id": "com.example.app"]),
            call(2, "app_logs", ["action": "start", "predicate": "process == \"App\"", "bundle_id": "com.example.app"]),
            call(3, "app_logs", ["action": "start", "system": true, "arguments": ["--deviceloop-log", "M1"]]),
        ])
        #expect(
            replies.map { $0.value(at: "result.structuredContent.error.code") } == ["bad_arguments", "bad_arguments", "bad_arguments"])
    }

    @Test func unknownArgumentIsAToolError() async throws {
        let replies = try await exchange([call(1, "app_uninstall", ["bundleId": "com.example.app"])])
        let text = replies[0].value(at: "result.content")?[0]?["text"]?.string ?? ""
        #expect(text.hasPrefix("ERROR bad_arguments: app_uninstall has no argument bundleId."))
    }

    @Test func unknownToolIsInvalidParams() async throws {
        let replies = try await exchange([call(1, "ui_scroll")])
        #expect(replies[0].value(at: "error.code") == -32602)
    }

    @Test func unknownMethodIsMethodNotFound() async throws {
        let replies = try await exchange([request(1, "resources/list")])
        #expect(replies[0].value(at: "error.code") == -32601)
    }

    @Test func malformedLineIsParseError() async throws {
        let replies = try await exchange(["{not json"])
        #expect(replies[0]["id"] == .null)
        #expect(replies[0].value(at: "error.code") == -32700)
    }

    @Test func commandResultBecomesTextImageAndStructuredContent() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let tool = MCPTool(name: "probe", title: "Probe", description: "", properties: [:], readOnly: true) { _ in
            CommandResult(
                text: "iPhone (simulator, iOS 27.1)\nok", json: ["ok": true], images: [ImageAttachment(data: png, mimeType: "image/png")])
        }
        let replies = try await exchange([call(1, "probe")], tools: [tool])
        let result = try #require(replies.first?["result"])
        #expect(
            result["content"] == [
                ["type": "text", "text": "iPhone (simulator, iOS 27.1)\nok"],
                ["type": "image", "data": .string(png.base64EncodedString()), "mimeType": "image/png"],
            ])
        #expect(result["structuredContent"] == ["ok": true])
        #expect(result["isError"] == false)
    }

    func logFile() -> URL {
        Paths.home.appending(path: "mcp-log-tests/\(UUID().uuidString)/mcp.jsonl")
    }

    /// The activity log for calls whose log lines no test reads.
    static let discardedLog = URL(filePath: "/dev/null")

    func logLines(_ file: URL) throws -> [JSONValue] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { try JSONValue(data: Data($0.utf8)) }
    }

    @Test func activityLogWritesOneLinePerCall() async throws {
        let file = logFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let tool = MCPTool(name: "probe", title: "Probe", description: "", properties: ["note": Param.string("")], readOnly: true) { _ in
            CommandResult(text: "ok")
        }
        _ = await tool.call(["note": "first"], log: file)
        _ = await tool.call(["missing": true], log: file)
        let lines = try logLines(file)
        #expect(lines.count == 2)
        #expect(lines.map { $0["tool"] } == ["probe", "probe"])
        #expect(lines.map { $0["result"] } == ["ok", "bad_arguments"])
        #expect(lines[0].value(at: "arguments.note") == "first")
        #expect(lines[0]["durationMs"]?.number != nil)
    }

    @Test func activityLogKeepsOnlyTheLengthOfSiriText() async throws {
        let file = logFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let siri = try #require(MCPTools.all.first { $0.name == "device_siri" })
        _ = await siri.call(["text": "call mom", "device": 7], log: file)
        let lines = try logLines(file)
        #expect(lines.first?.value(at: "arguments.text") == 8)
        #expect(try !String(contentsOf: file, encoding: .utf8).contains("call mom"))
    }

    @Test func activityLogKeepsOnlyTheLengthOfTypedCaptureSteps() async throws {
        let file = logFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let capture = try #require(MCPTools.all.first { $0.name == "video_capture" })
        _ = await capture.call(["step": "type \"hunter2\" id=password", "device": 7], log: file)
        #expect(try logLines(file).first?.value(at: "arguments.step") == "type, 7 characters")
        #expect(try !String(contentsOf: file, encoding: .utf8).contains("hunter2"))
    }

    @Test func activityLogKeepsOnlyTheKeysOfLaunchEnvironment() async throws {
        let file = logFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let launch = try #require(MCPTools.all.first { $0.name == "app_launch" })
        _ = await launch.call(["bundle_id": "com.example.app", "env": [["key": "API_TOKEN", "value": "s3cret"]], "device": 7], log: file)
        #expect(try logLines(file).first?.value(at: "arguments.env") == ["API_TOKEN"])
        #expect(try !String(contentsOf: file, encoding: .utf8).contains("s3cret"))
    }

    let secretFlow: JSONValue = [
        "schema": "deviceloop.flow/1", "name": "secret",
        "app": ["bundleID": "com.example.app", "environment": ["API_TOKEN": "s3cret"]],
        "steps": [["type": ["text": "hunter2"]]],
    ]

    @Test func activityLogKeepsOnlyTheLengthOfTypedTextAndTheKeysOfEnvironmentInAFlow() async throws {
        let file = logFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let validate = try #require(MCPTools.all.first { $0.name == "flow_validate" })
        _ = await validate.call(["flow": secretFlow], log: file)
        let flow = try logLines(file).first?.value(at: "arguments.flow")
        #expect(flow?["steps"]?[0]?.value(at: "type.text") == 7)
        #expect(flow?.value(at: "app.environment") == ["API_TOKEN"])
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(!contents.contains("hunter2"))
        #expect(!contents.contains("s3cret"))
    }

    @Test func activityLogMarksCancelledCalls() async throws {
        let file = logFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let tool = MCPTool(name: "slow", title: "Slow", description: "", properties: [:], readOnly: true) { _ in
            try await Task.sleep(for: .seconds(30))
            return CommandResult(text: "done")
        }
        let running = Task { await tool.call([:], log: file) }
        running.cancel()
        _ = await running.value
        #expect(try logLines(file).first?["result"] == "cancelled")
    }

    @Test func activityLogNamesTheDeviceAnExplicitSelectorResolved() async throws {
        let file = logFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let tool = MCPTool(name: "probe", title: "Probe", description: "", properties: [:], readOnly: true) { arguments in
            CommandResult(text: try await arguments.target("iPhone").summary)
        }
        _ = await tool.call([:], resolve: { _ in Self.simulator() }, log: file)
        #expect(try logLines(file).first?["deviceName"] == "Test Simulator")
    }

    @Test func deviceDoctorResolvesTheNamedDeviceWithTheServerResolver() async throws {
        let file = logFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let doctor = try #require(MCPTools.all.first { $0.name == "device_doctor" })
        let selectors = Outbox()
        let resolve: MCPArguments.Resolve = { selector in
            selectors.lines.withLock { $0.append(selector ?? "") }
            throw DeviceLoopError(.deviceNotFound, "No device matches \(selector ?? "").")
        }
        _ = await doctor.call(["device": "iPhone"], resolve: resolve, log: file)
        #expect(selectors.lines.withLock { $0 } == ["iPhone"])
        #expect(try logLines(file).first?["result"] == "device_not_found")
    }

    @Test func activityLogRotatesToOneOldFileAtTheCap() async throws {
        let file = logFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Paths.ensureDirectory(file.deletingLastPathComponent())
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        try FileHandle(forWritingTo: file).truncate(atOffset: UInt64(MCPActivityLog.maxBytes))
        MCPActivityLog.append(tool: "probe", arguments: [:], deviceName: nil, status: "ok", started: Date(), to: file)
        #expect(try logLines(file).count == 1)
        let rotated = try FileManager.default.attributesOfItem(atPath: file.appendingPathExtension("1").path)
        #expect(rotated[.size] as? Int == MCPActivityLog.maxBytes)
    }

    func text(_ reply: JSONValue?) -> String {
        reply?.value(at: "result.content")?[0]?["text"]?.string ?? ""
    }

    /// A tracked job whose xcodebuild is `/bin/sleep <seconds>`, with its directory and session removed afterwards.
    func withSleepJob(seconds: String = "30", _ body: (ServerTestJob) async throws -> Void) async throws {
        let directory = try Paths.ensureDirectory(Paths.home.appending(path: "mcp-tests/test-\(UUID().uuidString)"))
        let target = Self.simulator()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: Paths.session(for: target.udid))
        }
        let interrupt = InterruptFlag()
        let pid = try Shell.spawnDetached(["/bin/sleep", seconds], log: directory.appending(path: "xcodebuild.log"))
        let entry = MCPTools.track(
            TestJob(target: target, directory: directory, arguments: ["/bin/sleep", seconds], pid: pid, startTime: 0, interrupt: interrupt))
        try await body(entry)
        interrupt.raise()
        _ = try? await MCPTools.report(entry, until: .now.advanced(by: .seconds(20)))
    }

    @Test func testRunTakesTypedArgumentsWithoutXcodebuildPassthrough() async throws {
        let replies = try await exchange([request(1, "tools/list")])
        let tool = replies[0].value(at: "result.tools")?.array?.first { $0["name"]?.string == "test_run" }
        let properties = Set(tool?.value(at: "inputSchema.properties")?.object?.keys.map { $0 } ?? [])
        #expect(
            properties == [
                "project", "workspace", "xctestrun", "scheme", "test_plan", "only_testing", "skip_testing", "configuration",
                "stop_runner", "wait_seconds", "device",
            ])
        #expect(tool?.value(at: "inputSchema.properties.wait_seconds.default") == 45)
    }

    @Test func testStatusAndCancelNeedAJob() async throws {
        let replies = try await exchange([call(1, "test_status"), call(2, "test_cancel")])
        let errors = Set(replies.map { text($0).split(separator: "\n").first.map(String.init) ?? "" })
        #expect(errors == ["ERROR bad_arguments: test_status needs job.", "ERROR bad_arguments: test_cancel needs job."])
    }

    @Test(arguments: [["project": "App.xcodeproj", "xctestrun": "App.xctestrun"], ["scheme": "App"]] as [JSONValue])
    func testRunNeedsExactlyOneOfProjectWorkspaceOrXctestrun(arguments: JSONValue) async throws {
        let replies = try await exchange([call(1, "test_run", arguments)])
        #expect(text(replies.first).hasPrefix("ERROR bad_arguments: test_run needs exactly one of project, workspace or xctestrun."))
    }

    @Test func testRunNeedsASchemeWithAProject() async throws {
        let replies = try await exchange([call(1, "test_run", ["project": "App.xcodeproj"])])
        #expect(text(replies.first).hasPrefix("ERROR bad_arguments: test_run needs scheme with project."))
    }

    @Test func testRunTakesNoSchemeWithAnXctestrun() async throws {
        let replies = try await exchange([call(1, "test_run", ["xctestrun": "App.xctestrun", "scheme": "App"])])
        #expect(text(replies.first).hasPrefix("ERROR bad_arguments: test_run scheme does not apply to xctestrun."))
    }

    @Test func testCancelRefusesAJobFromElsewhere() async throws {
        let job = "test-20261108-131927-412-3f9a2c"
        let replies = try await exchange([call(1, "test_cancel", ["job": .string(job)])])
        #expect(text(replies.first).hasPrefix("ERROR bad_arguments: Test job \(job) was not started by this server."))
    }

    @Test func testStatusReportsARunningJob() async throws {
        try await withSleepJob { entry in
            let replies = try await exchange([call(1, "test_status", ["job": .string(entry.job.name), "wait_seconds": 0])])
            #expect(replies.first?.value(at: "result.structuredContent.status") == "running")
            #expect(replies.first?.value(at: "result.structuredContent.job") == .string(entry.job.name))
        }
    }

    @Test func testCancelInterruptsTheJobAndStatusReportsCancelled() async throws {
        try await withSleepJob { entry in
            let name = JSONValue.string(entry.job.name)
            let cancel = try await exchange([call(1, "test_cancel", ["job": name])])
            #expect(cancel.first?.value(at: "result.structuredContent.status") == "cancelling")
            let status = try await exchange([call(2, "test_status", ["job": name, "wait_seconds": 20])])
            #expect(status.first?.value(at: "result.structuredContent.status") == "cancelled")
            #expect(status.first?.value(at: "result.structuredContent.cancelReason") == "interrupt")
            #expect(status.first?.value(at: "result.structuredContent.signal") == .number(Double(SIGINT)))
        }
    }

    @Test func waitForTestJobsReturnsOnceEachJobWroteItsSummary() async throws {
        try await withSleepJob(seconds: "1") { entry in
            try await MCPTools.waitForTestJobs()
            #expect(FileManager.default.fileExists(atPath: entry.job.summary.path))
        }
    }

    @Test func testStatusReadsTheSummaryOfAJobFromElsewhere() async throws {
        let directory = try Paths.ensureDirectory(Paths.artifacts.appending(path: "test-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = TestRun(
            job: directory.lastPathComponent, device: "UDID", status: "failed", arguments: ["xcrun", "xcodebuild"], exitStatus: 65,
            startTime: 1, endTime: 2, directory: directory.path, bundle: directory.appending(path: "result.xcresult").path,
            log: directory.appending(path: "xcodebuild.log").path, xcodebuildErrors: [], result: try await recordedReport("failure"))
        try JSONEncoder().encode(run).write(to: directory.appending(path: "summary.json"))
        let replies = try await exchange([call(1, "test_status", ["job": .string(directory.lastPathComponent)])])
        let lines = text(replies.first).split(separator: "\n")
        #expect(lines.first == "UDID")
        #expect(lines.contains { $0.hasPrefix("FAIL SuiteFixtureTests/DeliberateFailure/testMismatch(): ") })
        #expect(replies.first?.value(at: "result.structuredContent.status") == "failed")
    }

    /// Holds a fake step until `open` is called.
    final class Gate: Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() { (stream, continuation) = AsyncStream.makeStream() }

        func open() { continuation.finish() }

        func wait() async {
            for await _ in stream {}
        }
    }

    let fakeFlow: JSONValue = [
        "schema": "deviceloop.flow/1", "name": "fake", "app": ["bundleID": "com.example.app"],
        "steps": [["sleep": ["ms": 1]], ["sleep": ["ms": 2]]],
        "cleanup": [["press": ["button": "home"]]],
    ]

    /// Flow tools whose runs go through FlowEngine with `execute` instead of a device. `onCancel` runs when a run is cancelled.
    func flowTools(onCancel: @escaping @Sendable () -> Void = {}, execute: @escaping FlowEngine.Executor) -> [String: MCPTool] {
        let tools = MCPTools.flowTools(jobs: FlowJobs(), wait: .seconds(10)) { _, _, json, _, progress in
            let flow = try Flow(json)
            let result = await withTaskCancellationHandler {
                await FlowEngine.run(flow, progress: progress, execute: execute)
            } onCancel: {
                onCancel()
            }
            return try CommandResult(text: "flow \(flow.name) \(result.status.rawValue)", payload: result)
        }
        return Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }

    func statuses(_ reply: JSONValue, _ phase: String) -> [String] {
        reply.value(at: "structuredContent.\(phase)")?.array?.compactMap { $0["status"]?.string } ?? []
    }

    @Test func flowRunReturnsTheRunIDAndCurrentStepWhenTheFlowOutlastsTheWait() async throws {
        let gate = Gate()
        defer { gate.open() }
        let tools = flowTools { _ in await gate.wait() }
        let target = Self.simulator()
        let reply = await tools["flow_run"]!.call(["flow": fakeFlow], resolve: { _ in target }, log: Self.discardedLog)
        #expect(reply["isError"] == false)
        #expect(reply.value(at: "content")?[0]?["text"]?.string?.hasPrefix("\(target.summary)\nrun flow-") == true)
        #expect(reply.value(at: "structuredContent.device") == .string(target.udid))
        #expect(reply.value(at: "structuredContent.status") == "running")
        #expect(reply.value(at: "structuredContent.current") == "steps[0] sleep")
        #expect(reply.value(at: "structuredContent.runId")?.string?.hasPrefix("flow-") == true)
    }

    @Test func flowStatusReturnsTheFinalResult() async throws {
        let gate = Gate()
        let tools = flowTools { _ in await gate.wait() }
        let started = await tools["flow_run"]!.call(["flow": fakeFlow], resolve: { _ in Self.simulator() }, log: Self.discardedLog)
        let runID = try #require(started.value(at: "structuredContent.runId"))
        gate.open()
        let reply = await tools["flow_status"]!.call(["run_id": runID], log: Self.discardedLog)
        #expect(reply["isError"] == false)
        #expect(reply.value(at: "structuredContent.schema") == "deviceloop.flow-result/1")
        #expect(reply.value(at: "structuredContent.status") == "passed")
        #expect(statuses(reply, "steps") == ["passed", "passed"])
    }

    @Test func flowCancelStopsBeforeTheNextStepAndRunsCleanup() async throws {
        let gate = Gate()
        let dispatched = Mutex<[String]>([])
        let tools = flowTools(
            onCancel: { gate.open() },
            execute: { step in
                dispatched.withLock { $0.append(step.kind) }
                if step.kind == "sleep" { await gate.wait() }
            })
        let started = await tools["flow_run"]!.call(["flow": fakeFlow], resolve: { _ in Self.simulator() }, log: Self.discardedLog)
        #expect(started.value(at: "structuredContent.status") == "running")
        let runID = try #require(started.value(at: "structuredContent.runId"))
        let reply = await tools["flow_cancel"]!.call(["run_id": runID], log: Self.discardedLog)
        #expect(reply["isError"] == true)
        #expect(reply.value(at: "structuredContent.status") == "cancelled")
        #expect(statuses(reply, "steps") == ["passed", "notStarted"])
        #expect(statuses(reply, "cleanup") == ["passed"])
        #expect(dispatched.withLock { $0 } == ["sleep", "press"])
    }

    @Test func failedFlowIsAnErrorResultWithEveryStepStatus() async throws {
        let tools = flowTools { step in
            if step.kind == "sleep" { throw DeviceLoopError(.elementNotFound, "No element matches id=login.") }
        }
        let reply = await tools["flow_run"]!.call(["flow": fakeFlow], resolve: { _ in Self.simulator() }, log: Self.discardedLog)
        #expect(reply["isError"] == true)
        #expect(reply.value(at: "structuredContent.status") == "failed")
        #expect(statuses(reply, "steps") == ["failed", "skipped"])
        #expect(statuses(reply, "cleanup") == ["passed"])
        #expect(reply.value(at: "structuredContent.steps")?[0]?.value(at: "error.code") == "element_not_found")
    }

    @Test func flowRunTakesATimeoutForTheWholeFlow() async throws {
        let replies = try await exchange([request(1, "tools/list")])
        let tool = replies[0].value(at: "result.tools")?.array?.first { $0["name"]?.string == "flow_run" }
        #expect(tool?.value(at: "inputSchema.properties.timeout_ms.type") == "integer")
    }

    @Test func finishAllCancelsARunAndReturnsAfterItFinishes() async throws {
        let jobs = FlowJobs()
        let cancelled = Mutex(false)
        jobs.start("flow-finish", on: Self.simulator()) { _ in
            try? await Task.sleep(for: .seconds(30))
            cancelled.withLock { $0 = Task.isCancelled }
            return CommandResult(text: "cancelled")
        }
        await jobs.finishAll()
        #expect(cancelled.withLock { $0 })
    }

    @Test func flowValidateChecksAnInlineFlow() async throws {
        let replies = try await exchange([call(1, "flow_validate", ["flow": fakeFlow])])
        #expect(replies[0].value(at: "result.isError") == false)
        #expect(replies[0].value(at: "result.structuredContent.steps") == 2)
        #expect(replies[0].value(at: "result.structuredContent.requirements") == ["ui runner", "home button"])
    }

    @Test func flowExportWritesANewSwiftFile() async throws {
        let folder = try Paths.ensureDirectory(
            FileManager.default.temporaryDirectory.appending(path: "deviceloop-export-\(UUID().uuidString)", directoryHint: .isDirectory))
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "FakeFlowTests.swift")
        let replies = try await exchange([call(1, "flow_export", ["flow": fakeFlow, "output": .string(file.path)])])
        #expect(replies[0].value(at: "result.isError") == false)
        #expect(replies[0].value(at: "result.structuredContent.class") == "FakeFlowTests")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("final class FakeFlowTests: XCTestCase {"))
    }

    @Test func flowStatusOfAnUnknownRunIsAToolError() async throws {
        let replies = try await exchange([call(1, "flow_status", ["run_id": "flow-missing"])])
        let text = replies[0].value(at: "result.content")?[0]?["text"]?.string ?? ""
        #expect(text.hasPrefix("ERROR bad_arguments: No flow run flow-missing in this MCP server."))
    }

    @Test func runRecordsToolCallsBetweenStartAndStop() async throws {
        let target = Self.simulator()
        defer { try? FileManager.default.removeItem(at: Paths.session(for: target.udid)) }
        let screenCapture = MCPTool.device(name: "screen_capture", title: "Screenshot", description: "", readOnly: true) { target, _ in
            let path = try Paths.newArtifact("screenshot", extension: "png")
            try Data("png".utf8).write(to: path)
            return CommandResult(text: "\(target.summary)\nsaved \(path.path)", json: ["path": .string(path.path)], files: [path])
        }
        let tools = MCPTools.runs + [screenCapture]
        let started = try await exchange([call(1, "run", ["action": "start", "name": "smoke"])], tools: tools) { _ in target }
        let id = try #require(started[0].value(at: "result.structuredContent.id")?.string)
        let run = try RunStore.named(id)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        let shot = try await exchange([call(2, "screen_capture")], tools: tools) { _ in target }
        #expect(shot[0].value(at: "result.content")?[0]?["text"]?.string?.hasSuffix("\nrun \(id) event 1") == true)
        let stopped = try await exchange([call(3, "run", ["action": "stop"])], tools: tools) { _ in target }
        let report = stopped[0].value(at: "result.content")?[0]?["text"]?.string ?? ""
        #expect(report.contains("run \(id) \"smoke\" finished, passed, 1 command\n1 screen_capture: ok artifacts/screenshot-"))
        #expect(stopped[0].value(at: "result.structuredContent.manifest.provenance.deviceloop") == "test")
        #expect(try run.manifest().files?.map(\.path).contains("results/1.json") == true)
    }

    @Test func runJournalsTheTextArgumentAsHidden() async throws {
        let target = Self.simulator()
        let run = try RunStore.create(owned: false)
        defer {
            try? FileManager.default.removeItem(at: run.directory)
            try? FileManager.default.removeItem(at: RunRecorder.pointer(target.udid))
        }
        try RunRecorder.activate(run, on: target.udid)
        let siri = MCPTool.device(
            name: "device_siri", title: "Ask Siri", description: "", properties: ["text": Param.string("")], readOnly: false
        ) { target, arguments in
            let phrase = try arguments.require("text")
            return CommandResult(text: "\(target.summary)\naccepted Siri request: \(phrase)", json: ["phrase": .string(phrase)])
        }
        _ = try await exchange([call(1, "device_siri", ["text": "call Alex"])], tools: [siri]) { _ in target }
        let journal = try String(contentsOf: run.directory.appending(path: "events.jsonl"), encoding: .utf8)
        let results = try String(contentsOf: run.directory.appending(path: "results/1.json"), encoding: .utf8)
        #expect(!journal.contains("call Alex"))
        #expect(!results.contains("call Alex"))
        #expect(try run.events().events.first?.args["text"] == "[hidden]")
    }

    @Test func runJournalsATypeStepAsHidden() async throws {
        let target = Self.simulator()
        try await recording(on: target) { run in
            let capture = MCPTool.device(
                name: "video_capture", title: "Capture animation", description: "", properties: ["step": Param.string("")], readOnly: false
            ) { target, arguments in
                let step = try arguments.require("step")
                return CommandResult(text: "\(target.summary)\nran \(step)", json: ["step": .string(step)])
            }
            _ = try await exchange([call(1, "video_capture", ["step": "type secret"])], tools: [capture]) { _ in target }
            #expect(try !journalAndFirstResult(run).contains("secret"))
            #expect(try run.events().events.first?.args["step"] == "[hidden]")
        }
    }

    @Test func uiTypeIsJournaledWithItsTextHidden() async throws {
        let target = Self.simulator(platform: "tvOS")
        try await recording(on: target) { run in
            let replies = try await exchange([call(1, "ui_type", ["text": "hunter2"])], tools: MCPTools.ui) { _ in target }
            #expect(replies[0].value(at: "result.structuredContent.error.code") == "unsupported_on_target")
            let events = try run.events().events
            #expect(events.map(\.kind) == ["started", "finished"])
            #expect(events.first?.args["text"] == "[hidden]")
        }
    }

    @Test func flowRunIsJournaledWithTypedTextAndEnvironmentHidden() async throws {
        let target = Self.simulator()
        try await recording(on: target) { run in
            let reply = await flowTools { _ in }["flow_run"]!.call(["flow": secretFlow], resolve: { _ in target }, log: Self.discardedLog)
            #expect(reply.value(at: "structuredContent.status") == "passed")
            #expect(try run.events().events.map(\.command) == ["flow_run", "flow_run"])
            let journal = try journalAndFirstResult(run)
            #expect(!journal.contains("hunter2"))
            #expect(!journal.contains("s3cret"))
        }
    }

    @Test func flowRunThatOutlastsTheWaitIsJournaledWithItsResultWhenItEnds() async throws {
        let target = Self.simulator()
        let gate = Gate()
        defer { gate.open() }
        try await recording(on: target) { run in
            let tools = flowTools { _ in await gate.wait() }
            let started = await tools["flow_run"]!.call(["flow": fakeFlow], resolve: { _ in target }, log: Self.discardedLog)
            #expect(started.value(at: "structuredContent.status") == "running")
            #expect(try run.events().events.map(\.kind) == ["started"])
            gate.open()
            let runID = try #require(started.value(at: "structuredContent.runId"))
            _ = await tools["flow_status"]!.call(["run_id": runID], log: Self.discardedLog)
            #expect(try run.events().events.map(\.kind) == ["started", "finished"])
            let result = try JSONValue(data: Data(contentsOf: run.directory.appending(path: "results/1.json")))
            #expect(result["status"] == "passed")
        }
    }

    @Test func flowRunJournalKeepsStringsThatContainAnEnvironmentValue() async throws {
        let target = Self.simulator()
        try await recording(on: target) { run in
            let flow: JSONValue = [
                "schema": "deviceloop.flow/1", "name": "flag", "app": ["bundleID": "com.example.app", "environment": ["FLAG": "1"]],
                "steps": [["sleep": ["ms": 1]]],
            ]
            _ = await flowTools { _ in }["flow_run"]!.call(["flow": flow], resolve: { _ in target }, log: Self.discardedLog)
            let started = try #require(run.events().events.first)
            #expect(started.args.value(at: "flow.schema") == "deviceloop.flow/1")
        }
    }

    @Test func cancelledCallGetsNoResponse() async throws {
        let tool = MCPTool(name: "slow", title: "Slow", description: "", properties: [:], readOnly: true) { _ in
            try await Task.sleep(for: .seconds(30))
            return CommandResult(text: "done")
        }
        let cancel = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7,"reason":"test"}}"#
        let replies = try await exchange([call(7, "slow"), cancel, request(8, "ping")], tools: [tool])
        #expect(replies.map { $0["id"] } == [8])
    }

    @Test func targetArgumentsDecodeHTMLEntities() throws {
        let arguments = MCPArguments(
            tool: "ui_tap", values: ["element": "Display &amp; Text Size", "on": "label~=Q&amp;A"],
            resolve: { _ in throw DeviceLoopError(.deviceNotFound, "No target in this test.") })
        #expect(try arguments.requireElementTarget("element") == ElementTarget(query: ElementQuery(label: "Display & Text Size")))
        #expect(try arguments.elementTarget("on") == ElementTarget(query: ElementQuery(labelContains: "Q&A")))
        #expect(MCPArguments.decodingEntities("&quot;Fish&quot; &lt;3 &amp;lt;") == "\"Fish\" <3 &lt;")
        #expect(MCPArguments.decodingEntities("Don&#x27;t Allow &#34;x&#34;") == "Don't Allow \"x\"")
        let query = try MCPTools.query(
            MCPArguments(
                tool: "ui_find", values: ["label": "A &amp; B", "label_contains": "Q&amp;A"],
                resolve: { _ in throw DeviceLoopError(.deviceNotFound, "No target in this test.") }))
        #expect(query == ElementQuery(label: "A & B", labelContains: "Q&A"))
    }

    @Test func instructionsNameTheDeviceLoopDeviceTarget() {
        #expect(MCPServer.instructions(environment: [:]) == MCPServer.baseInstructions)
        let pinned = MCPServer.instructions(environment: ["DEVICELOOP_DEVICE": "8B3DE641"])
        let line =
            "DEVICELOOP_DEVICE is 8B3DE641, so tools act on that target when `device` is left out. "
            + "device_list gives its UDID as defaultDevice."
        #expect(pinned == MCPServer.baseInstructions + "\n" + line)
    }
}
