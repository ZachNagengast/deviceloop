//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct FlowEngineTests {
    /// A flow whose steps sleep 1, 2 and 3 ms and whose cleanup presses home.
    func flow(_ fields: [String: JSONValue] = [:]) throws -> Flow {
        var object: [String: JSONValue] = [
            "schema": "deviceloop.flow/1",
            "name": "engine",
            "app": ["bundleID": "com.example.app"],
            "steps": [["sleep": ["ms": 1]], ["sleep": ["ms": 2]], ["sleep": ["ms": 3]]],
            "cleanup": [["press": ["button": "home"]]],
        ]
        object.merge(fields) { _, new in new }
        return try Flow(.object(object))
    }

    static let second = FlowStep.Action.ui(.sleep(ms: 2))
    static let home = FlowStep.Action.ui(.press(button: "home"))

    private actor Dispatched {
        var steps: [FlowStep] = []
        var actions: [FlowStep.Action] { steps.map(\.action) }
        func record(_ step: FlowStep) { steps.append(step) }
    }

    @Test func failureStopsLaterStepsAndStillRunsCleanup() async throws {
        let dispatched = Dispatched()
        let failure = DeviceLoopError(.elementNotFound, "No element matches id=login.", fix: "Check the id.")
        let result = await FlowEngine.run(try flow()) { step in
            await dispatched.record(step)
            if step.action == Self.second { throw failure }
        }
        #expect(await dispatched.actions == [.ui(.sleep(ms: 1)), Self.second, Self.home])
        #expect(result.status == .failed)
        #expect(result.steps.map(\.status) == [.passed, .failed, .skipped])
        #expect(result.steps[1].error == failure)
        #expect(result.cleanup.map(\.status) == [.passed])
    }

    @Test func unknownOutcomeIsNotRetriedAndSkipsLaterSteps() async throws {
        let dispatched = Dispatched()
        var receipted = DeviceLoopError(.actionOutcomeUnknown, "The runner did not return a readable, confirmed action result.")
        receipted.operationID = "op-1"
        receipted.sessionEpoch = "epoch-1"
        let unknown = receipted
        let result = await FlowEngine.run(try flow(["cleanup": []])) { step in
            await dispatched.record(step)
            throw unknown
        }
        #expect(await dispatched.actions == [.ui(.sleep(ms: 1))])
        #expect(result.steps.map(\.status) == [.unknown, .skipped, .skipped])
        #expect(result.steps[0].error?.operationID == "op-1")
        #expect(result.steps[0].error?.sessionEpoch == "epoch-1")
    }

    @Test func cleanupFailureKeepsTheStepFailure() async throws {
        let stepFailure = DeviceLoopError(.elementNotFound, "No element matches id=login.")
        let cleanupFailure = DeviceLoopError(.runnerUnreachable, "Could not reach the runner.")
        let result = await FlowEngine.run(try flow()) { step in
            if step.action == Self.second { throw stepFailure }
            if step.action == Self.home { throw cleanupFailure }
        }
        #expect(result.status == .failed)
        #expect(result.steps[1].error == stepFailure)
        #expect(result.cleanup[0].status == .failed)
        #expect(result.cleanup[0].error == cleanupFailure)
    }

    @Test func cleanupFailureFailsAPassingFlow() async throws {
        let result = await FlowEngine.run(try flow()) { step in
            if step.action == Self.home { throw DeviceLoopError(.runnerUnreachable, "Could not reach the runner.") }
        }
        #expect(result.steps.map(\.status) == [.passed, .passed, .passed])
        #expect(result.status == .cleanupFailed)
    }

    @Test func expiredDeadlineNeverInvokesTheExecutor() async throws {
        let dispatched = Dispatched()
        let result = await FlowEngine.run(try flow(["timeoutMs": 50, "cleanup": []])) { step in
            await dispatched.record(step)
            try await Task.sleep(for: .milliseconds(60))
        }
        #expect(await dispatched.actions == [.ui(.sleep(ms: 1))])
        #expect(result.status == .failed)
        #expect(result.steps.map(\.status) == [.passed, .notStarted, .skipped])
        #expect(result.steps[1].error?.code == .timeout)
    }

    @Test func stepTimeoutIsCutToTheTimeLeftInTheFlow() async throws {
        let dispatched = Dispatched()
        _ = await FlowEngine.run(try flow(["timeoutMs": 10_000, "cleanup": []])) { step in await dispatched.record(step) }
        let timeouts = await dispatched.steps.map(\.timeoutMs)
        #expect(timeouts.count == 3)
        #expect(timeouts.allSatisfy { $0 >= 1 && $0 <= 10_000 })
    }

    @Test func cancellationStopsBeforeTheNextStepAndRunsCleanupUncancelled() async throws {
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (proceed, proceedContinuation) = AsyncStream<Void>.makeStream()
        let dispatched = Dispatched()
        let sawCancellation = Dispatched()
        let flow = try flow()
        let run = Task {
            await FlowEngine.run(flow) { step in
                await dispatched.record(step)
                if step.action == .ui(.sleep(ms: 1)) {
                    startedContinuation.yield()
                    for await _ in proceed { break }
                }
                if Task.isCancelled { await sawCancellation.record(step) }
            }
        }
        for await _ in started { break }
        run.cancel()
        proceedContinuation.yield()
        let result = await run.value
        #expect(await dispatched.actions == [.ui(.sleep(ms: 1)), Self.home])
        #expect(result.status == .cancelled)
        #expect(result.steps.map(\.status) == [.passed, .notStarted, .skipped])
        #expect(result.cleanup.map(\.status) == [.passed])
        #expect(await sawCancellation.steps.isEmpty)
    }

    @Test func runWithoutDeadlineKeepsEachStepTimeout() async throws {
        let dispatched = Dispatched()
        let steps = [FlowStep(.ui(.sleep(ms: 1)), timeoutMs: 120_000), FlowStep(.ui(.sleep(ms: 2)), timeoutMs: 120_000)]
        let result = await FlowEngine.run("ui do", timeoutMs: nil, setup: [], steps: steps, cleanup: []) { await dispatched.record($0) }
        #expect(result.status == .passed)
        #expect(await dispatched.steps.map(\.timeoutMs) == [120_000, 120_000])
    }

    @Test func errorAfterAnInterruptIsReportedAsCancellation() async {
        let interrupt = InterruptFlag()
        await #expect(throws: CancellationError.self) {
            try await FlowEngine.cancellingOnInterrupt(interrupt: interrupt) {
                interrupt.raise()
                try? await Task.sleep(for: .seconds(10))
                throw DeviceLoopError(.runnerUnreachable, "Could not reach the runner at ::1.")
            }
        }
    }

    @Test func statusExitCodes() {
        #expect([FlowResult.Status.passed, .failed, .cleanupFailed, .cancelled].map(\.exitCode) == [0, 1, 1, 130])
    }

    @Test func resultEncodesSchemaPhaseAndKind() async throws {
        let result = await FlowEngine.run(try flow(["setup": [["hold": ["id": "a"]]]])) { _ in }
        let json = try JSONValue(encoding: result)
        #expect(json["schema"] == "deviceloop.flow-result/1")
        #expect(json["steps"]?[0]?["phase"] == "setup")
        #expect(json["steps"]?[0]?["kind"] == "hold")
        #expect(json["steps"]?[1]?["phase"] == "steps")
        #expect(json["steps"]?[1]?["index"] == 0)
        #expect(json["cleanup"]?[0]?["kind"] == "press")
    }
}

@Suite struct UIDoTests {
    static func record(_ index: Int, _ status: FlowStepResult.Status, error: DeviceLoopError? = nil) -> FlowStepResult {
        FlowStepResult(phase: .steps, index: index, kind: "tap", status: status, error: error)
    }

    @Test func unknownElementTypeFailsBeforeAnyStepRuns() async {
        let steps: [UIStep] = [.sleep(ms: 1), .tap(ElementTarget(query: ElementQuery(type: "buton", id: "login")))]
        let error = await #expect(throws: DeviceLoopError.self) {
            try await UICommands.perform(steps, on: FlowExecutorTests.target, app: nil, screenshot: false)
        }
        #expect(error?.message == "buton is not an element type.")
    }

    @Test func sleepLongerThanTheStepTimeoutFailsBeforeAnyStepRuns() async {
        let error = await #expect(throws: DeviceLoopError.self) {
            try await UICommands.perform([.sleep(ms: 600_000)], on: FlowExecutorTests.target, app: nil, screenshot: false)
        }
        #expect(error?.code == .badArguments)
        #expect(error?.message == "Sleep must be at most 120000 ms, not 600000.")
    }

    func typeStep(answering body: String) async throws -> DeviceLoopError? {
        let server = try #require(LoopbackServer(answering: body))
        defer { server.stop() }
        let type = UIStep.type("abc", into: ElementTarget(query: ElementQuery(id: "search")))
        return await #expect(throws: DeviceLoopError.self) {
            try await UICommands.runFlowStep(type, app: nil, client: server.client, timeoutMs: 5000)
        }
    }

    @Test func typeThatDoesNotReadBackFailsWithTextMismatch() async throws {
        let error = try await typeStep(answering: #"{"ok":true,"result":{"readBack":"ab","elementType":"textField"}}"#)
        #expect(error?.code == .textMismatch)
        #expect(error?.message == "The field does not hold the 3 characters typed.")
    }

    @Test func typeIntoAFieldThatCannotBeReadSaysSo() async throws {
        let error = try await typeStep(answering: #"{"ok":true,"result":{"elementType":"textField"}}"#)
        #expect(error?.code == .textMismatch)
        #expect(error?.message == "The field could not be read after typing, so the 3 characters typed are not verified.")
    }

    @Test func sleepLongerThanTheTimeLeftStopsAtTheTimeout() async {
        let client = RunnerClient(baseURL: .runner(host: "::1", port: 1), token: "token")
        let started = ContinuousClock.now
        let error = await #expect(throws: DeviceLoopError.self) {
            try await UICommands.runFlowStep(.sleep(ms: 30_000), app: nil, client: client, timeoutMs: 100)
        }
        #expect(error?.code == .timeout)
        #expect(started.duration(to: .now) < .seconds(10))
    }

    @Test func linesShowCompletedStepsThenTheFailingStep() {
        let failure = DeviceLoopError(.elementNotFound, "No element matches id=does.not.exist.", fix: "Check the id.")
        let steps = [Self.record(0, .passed), Self.record(1, .failed, error: failure), Self.record(2, .skipped)]
        let result = FlowResult(name: "ui do", status: .failed, steps: steps)
        #expect(UICommands.doLines(result, completed: ["tapped at 10,20"]) == ["tapped at 10,20", "step 2 tap failed", failure.rendered])
    }

    @Test func linesNameTheStepACancelledRunStoppedBefore() {
        let result = FlowResult(name: "ui do", status: .cancelled, steps: [Self.record(0, .passed), Self.record(1, .notStarted)])
        #expect(UICommands.doLines(result, completed: ["tapped at 10,20"]) == ["tapped at 10,20", "cancelled before step 2"])
    }

    @Test func linesReportAFailedScreenshot() {
        let failure = DeviceLoopError(.deviceError, "simctl io screenshot failed.")
        let screenshot = FlowStepResult(phase: .cleanup, index: 0, kind: "screenshot", status: .failed, error: failure)
        let result = FlowResult(name: "ui do", status: .cleanupFailed, steps: [Self.record(0, .passed)], cleanup: [screenshot])
        #expect(UICommands.doLines(result, completed: ["tapped at 10,20"]) == ["tapped at 10,20", "screenshot failed", failure.rendered])
    }

    @Test func linesLeaveOutTheTextOfAFailedTypeStep() async throws {
        let server = try #require(LoopbackServer(answering: #"{"ok":true,"result":{"readBack":"hunter"}}"#))
        defer { server.stop() }
        let type = FlowStep(.ui(.type("hunter2", into: ElementTarget(query: ElementQuery(id: "password")))), timeoutMs: 5000)
        let result = await FlowEngine.run("ui do", timeoutMs: nil, setup: [], steps: [type], cleanup: []) { step in
            guard case .ui(let action) = step.action else { return }
            _ = try await UICommands.runFlowStep(action, app: nil, client: server.client, timeoutMs: step.timeoutMs)
        }
        let lines = UICommands.doLines(result, completed: [])
        #expect(lines.first == "step 1 type failed")
        #expect(!lines.contains { $0.contains("hunter") }, "\(lines)")
    }
}

@Suite struct FlowAssertionTests {
    static let counter = ElementQuery(id: "fixture.counter.value")

    static func match(label: String? = "Count: 1", value: String? = nil, hittable: Bool = true) -> FoundElement {
        FoundElement(
            type: "staticText", id: "fixture.counter.value", label: label, value: value, frame: [0, 0, 10, 10], hittable: hittable)
    }

    @Test func noMatchIsElementNotFound() {
        let failure = FlowCommands.failure(of: .exists, query: Self.counter, matches: [])
        #expect(failure?.code == .elementNotFound)
        #expect(failure?.message == "No element matches id=fixture.counter.value.")
    }

    @Test func oneMatchExists() {
        #expect(FlowCommands.failure(of: .exists, query: Self.counter, matches: [Self.match()]) == nil)
    }

    @Test func twoMatchesAreAmbiguousAndListTheCandidates() {
        let failure = FlowCommands.failure(
            of: .label("Count: 1"), query: Self.counter, matches: [Self.match(), Self.match(label: "Count: 2")])
        #expect(failure?.code == .elementAmbiguous)
        #expect(
            failure?.detail?.split(separator: "\n") == [
                "staticText \"Count: 1\" id=fixture.counter.value [0,0,10,10]",
                "staticText \"Count: 2\" id=fixture.counter.value [0,0,10,10]",
            ])
    }

    @Test func ambiguityListsAtMostFiveCandidates() {
        let failure = FlowCommands.failure(of: .exists, query: Self.counter, matches: Array(repeating: Self.match(), count: 7))
        #expect(failure?.message == "7 elements match id=fixture.counter.value.")
        #expect(failure?.detail?.split(separator: "\n").count == 5)
    }

    @Test func labelMustMatchExactly() {
        #expect(FlowCommands.failure(of: .label("Count: 1"), query: Self.counter, matches: [Self.match()]) == nil)
        let failure = FlowCommands.failure(of: .label("Count: 2"), query: Self.counter, matches: [Self.match()])
        #expect(failure?.code == .assertionFailed)
        #expect(failure?.message == "id=fixture.counter.value has label \"Count: 1\", expected \"Count: 2\".")
    }

    @Test func valueMustMatchExactly() {
        #expect(FlowCommands.failure(of: .value("On"), query: Self.counter, matches: [Self.match(value: "On")]) == nil)
        let failure = FlowCommands.failure(of: .value("on"), query: Self.counter, matches: [Self.match(value: "On")])
        #expect(failure?.message == "id=fixture.counter.value has value \"On\", expected \"on\".")
        let missing = FlowCommands.failure(of: .value("On"), query: Self.counter, matches: [Self.match()])
        #expect(missing?.message == "id=fixture.counter.value has no value, expected \"On\".")
    }

    @Test func goneHoldsOnlyWithNoMatches() {
        #expect(FlowCommands.failure(of: .gone, query: Self.counter, matches: []) == nil)
        let failure = FlowCommands.failure(of: .gone, query: Self.counter, matches: [Self.match(), Self.match()])
        #expect(failure?.code == .assertionFailed)
        #expect(failure?.message == "id=fixture.counter.value still matches 2 elements.")
    }

    @Test func hittableNeedsAHittableMatch() {
        let failure = FlowCommands.failure(of: .hittable, query: Self.counter, matches: [Self.match(hittable: false)])
        #expect(failure?.code == .elementNotHittable)
        #expect(FlowCommands.failure(of: .hittable, query: Self.counter, matches: [Self.match()]) == nil)
    }

    @Test func enabledUsesTheSeparatelyReadState() {
        #expect(FlowCommands.failure(of: .enabled, query: Self.counter, matches: [Self.match()], enabled: true) == nil)
        let disabled = FlowCommands.failure(of: .enabled, query: Self.counter, matches: [Self.match()], enabled: false)
        #expect(disabled?.code == .assertionFailed)
    }
}

@Suite struct FlowPreflightTests {
    static let device = Target(
        udid: "00000000-0000-0000-0000-000000000003", identifier: "00000000-0000-0000-0000-000000000003", name: "Test iPhone",
        kind: .device, deviceType: "iPhone", platform: "iOS", model: "iPhone 13 Pro", productType: "iPhone14,2", osVersion: "27.1",
        connectionState: "connected")

    func flow(_ fields: [String: JSONValue]) throws -> Flow {
        var object: [String: JSONValue] = [
            "schema": "deviceloop.flow/1", "name": "preflight", "app": ["bundleID": "com.example.app"], "steps": [["sleep": ["ms": 1]]],
        ]
        object.merge(fields) { _, new in new }
        return try Flow(.object(object))
    }

    @Test func requirementsComeFromPressStepsResetAndRequires() throws {
        let home: JSONValue = ["press": ["button": "home"]]
        let action: JSONValue = ["press": ["button": "action"]]
        #expect(try flow([:]).requirements == ["ui runner"])
        #expect(try flow(["cleanup": [home]]).requirements == ["ui runner", "home button"])
        #expect(try flow(["setup": [action], "steps": [home]]).requirements == ["ui runner", "home button", "action button"])
        #expect(try flow(["reset": "reinstall", "appPath": "App.app"]).requirements == ["ui runner", "install", "uninstall"])
        #expect(try flow(["requires": ["uninstall", "action button"]]).requirements == ["ui runner", "action button", "uninstall"])
        #expect(try flow(["requires": ["home button"], "cleanup": [home]]).requirements == ["ui runner", "home button"])
    }

    @Test func missingButtonIsUnsupportedAndListsTheButtonsThereAre() throws {
        #expect(throws: Never.self) { try FlowCommands.check(["ui runner", "action button"], on: Self.device) }
        let error = #expect(throws: DeviceLoopError.self) {
            try FlowCommands.check(["ui runner", "action button"], on: Self.device, buttons: ["home"])
        }
        #expect(error?.code == .unsupportedOnTarget)
        #expect(error?.message == "The action button is not available on Test iPhone (device, iOS 27.1).")
        #expect(error?.fix == "Use a target that has the action button, or remove the steps and requires entry that need it.")
        #expect(error?.detail == "hardware buttons: home")
    }

    static let reinstall: JSONValue = [
        "schema": "deviceloop.flow/1", "name": "reinstall", "app": ["bundleID": "com.example.app"], "reset": "reinstall",
        "appPath": "/nonexistent/App.app", "steps": [["tap": ["id": "login"]]],
    ]

    @Test func unmetRequirementThrowsBeforeTheRunnerOrDeviceIsUsed() async throws {
        let error = await #expect(throws: DeviceLoopError.self) { try await FlowCommands.run(Self.device, flow: Self.reinstall) }
        #expect(error?.code == .unsupportedOnTarget)
        #expect(error?.detail == "missing capability \(Capability.installApp)")
    }

    @Test func missingAppPathFailsBeforeTheAppIsUninstalled() async throws {
        var device = Self.device
        device.capabilities = [Capability.installApp, Capability.uninstallApp]
        let error = await #expect(throws: DeviceLoopError.self) { try await FlowCommands.run(device, flow: Self.reinstall) }
        #expect(error?.code == .badArguments)
        #expect(error?.message == "appPath: nothing at /nonexistent/App.app.")
    }

    @Test func pinnedBuildMustMatchTheInstalledApp() throws {
        let installed = try #require(
            InstalledApp(devicectl: ["bundleIdentifier": "com.example.app", "version": "1.2", "bundleVersion": "41"]))
        let app = try flow(["app": ["bundleID": "com.example.app", "version": "1.2", "build": "42"]]).app
        let error = #expect(throws: DeviceLoopError.self) {
            try FlowCommands.checkPins(app, version: installed.version, build: installed.build, on: Self.device)
        }
        #expect(error?.code == .appNotInstalled)
        #expect(error?.message == "com.example.app build 41 is installed on Test iPhone (device, iOS 27.1), the flow pins build 42.")
        var matching = app
        matching.build = "41"
        #expect(throws: Never.self) {
            try FlowCommands.checkPins(matching, version: installed.version, build: installed.build, on: Self.device)
        }
    }

    /// A new folder holding `App.app` with an Info.plist of `info`.
    func appBundle(_ info: [String: String]) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appending(path: "deviceloop-preflight-\(UUID().uuidString)/App.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appending(path: "Info.plist"))
        return app
    }

    func reinstall(_ appPath: URL, pins: [String: JSONValue] = [:]) -> JSONValue {
        var app: [String: JSONValue] = ["bundleID": "com.example.app"]
        app.merge(pins) { _, new in new }
        return [
            "schema": "deviceloop.flow/1", "name": "reinstall", "app": .object(app), "reset": "reinstall", "appPath": .string(appPath.path),
            "steps": [["tap": ["id": "login"]]],
        ]
    }

    var reinstallDevice: Target {
        var device = Self.device
        device.capabilities = [Capability.installApp, Capability.uninstallApp]
        return device
    }

    @Test func appPathWithAnotherBundleIDFailsBeforeTheAppIsUninstalled() async throws {
        let app = try appBundle(["CFBundleIdentifier": "com.example.other", "CFBundleVersion": "42"])
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let error = await #expect(throws: DeviceLoopError.self) { try await FlowCommands.run(reinstallDevice, flow: reinstall(app)) }
        #expect(error?.code == .badArguments)
        #expect(error?.message == "appPath: \(app.path) is com.example.other, and the flow app is com.example.app.")
    }

    @Test func appPathBuildMustMatchThePinnedBuild() async throws {
        let app = try appBundle(["CFBundleIdentifier": "com.example.app", "CFBundleShortVersionString": "1.2", "CFBundleVersion": "41"])
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let flow = reinstall(app, pins: ["version": "1.2", "build": "42"])
        let error = await #expect(throws: DeviceLoopError.self) { try await FlowCommands.run(reinstallDevice, flow: flow) }
        #expect(error?.code == .badArguments)
        #expect(error?.message == "com.example.app build 41 is at \(app.path), the flow pins build 42.")
    }

    @Test func installedAppIsLookedUpInsideTheFlowLock() async throws {
        var device = Self.device
        device.udid = "flow-preflight-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: Paths.session(for: device.udid)) }
        let flow: JSONValue = [
            "schema": "deviceloop.flow/1", "name": "locked", "app": ["bundleID": "com.example.app"], "steps": [["sleep": ["ms": 1]]],
        ]
        try await SessionLock.withFlowLock("flow-holding", on: device) {
            let error = await #expect(throws: DeviceLoopError.self) { try await FlowCommands.run(device, flow: flow) }
            #expect(error?.code == .deviceBusy)
            #expect(error?.message == "Flow flow-holding is running on \(device.summary).")
        }
    }

    @Test func ipaAppPathIsReadFromItsPayload() async throws {
        let bundle = try appBundle(["CFBundleIdentifier": "com.example.other"])
        let folder = bundle.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let payload = folder.appending(path: "Payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: bundle, to: payload.appending(path: "App.app"))
        let ipa = folder.appending(path: "App.ipa")
        let zip = try await Shell.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", payload.path, ipa.path])
        #expect(zip.succeeded, "\(zip.stderrString)")
        let app = try Flow(reinstall(ipa)).app
        let error = await #expect(throws: DeviceLoopError.self) { try await FlowCommands.check(ipa, against: app, on: reinstallDevice) }
        #expect(error?.code == .badArguments)
        #expect(error?.message == "appPath: \(ipa.path) is com.example.other, and the flow app is com.example.app.")
    }
}

@Suite struct FlowExecutorTests {
    static let target = Target(
        udid: "00000000-0000-0000-0000-000000000002", identifier: "00000000-0000-0000-0000-000000000002", name: "Test iPhone",
        kind: .device, deviceType: "iPhone", platform: "iOS", model: "iPhone 17 Pro", productType: "iPhone18,1", osVersion: "27.1",
        connectionState: "disconnected")

    func executor(port: UInt16) -> FlowExecutor {
        let client = RunnerClient(baseURL: .runner(host: "::1", port: port), token: "token")
        return FlowExecutor(target: Self.target, client: client, app: "com.example.app", directory: Paths.artifacts)
    }

    @Test func hungActionTimesOutAtTheStepTimeoutWithUnknownOutcome() async throws {
        let server = try #require(LoopbackServer())
        defer { server.stop() }
        let tap = FlowStep(.ui(.tap(ElementTarget(query: ElementQuery(id: "login")))), timeoutMs: 300)
        let started = ContinuousClock.now
        let error = await #expect(throws: DeviceLoopError.self) { try await executor(port: server.port).execute(tap) }
        #expect(error?.code == .actionOutcomeUnknown)
        #expect(started.duration(to: .now) < .seconds(10))
    }

    @Test func assertCutOffByItsDeadlineReportsThePreviousPoll() async throws {
        let found = #"{"ok":true,"result":{"matches":[{"type":"staticText","id":"count","label":"Count: 1","frame":[0,0,10,10]}]}}"#
        let server = try #require(LoopbackServer(answering: found))
        defer { server.stop() }
        let assert = FlowStep(.assert(ElementQuery(id: "count"), .label("Count: 2")), timeoutMs: 1000)
        let error = await #expect(throws: DeviceLoopError.self) { try await executor(port: server.port).execute(assert) }
        #expect(error?.code == .assertionFailed, "\(error?.rendered ?? "")")
    }

    @Test func textMismatchDoesNotRepeatTheTypedText() async throws {
        let server = try #require(LoopbackServer(answering: #"{"ok":true,"result":{"readBack":"hunter"}}"#))
        defer { server.stop() }
        let type = FlowStep(.ui(.type("hunter2", into: ElementTarget(query: ElementQuery(id: "password")))), timeoutMs: 5000)
        let error = await #expect(throws: DeviceLoopError.self) { try await executor(port: server.port).execute(type) }
        #expect(error?.code == .textMismatch)
        let rendered = try #require(error?.rendered)
        #expect(!rendered.contains("hunter"), "\(rendered)")
    }

    @Test func sleepLongerThanTheStepTimeoutStopsAtTheTimeoutAndThrowsTimeout() async throws {
        let sleep = FlowStep(.ui(.sleep(ms: 30_000)), timeoutMs: 100)
        let started = ContinuousClock.now
        let error = await #expect(throws: DeviceLoopError.self) { try await executor(port: 1).execute(sleep) }
        #expect(error?.code == .timeout)
        #expect(error?.message == "The 30000 ms sleep is longer than the 100 ms left for this step.")
        #expect(started.duration(to: .now) < .seconds(10))
    }
}

/// Runs the example flows against a booted simulator: DEVICELOOP_TEST_SIMULATOR=<udid> xcrun swift test --filter FlowLiveTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEVICELOOP_TEST_SIMULATOR"] != nil), .serialized)
struct FlowLiveTests {
    static let host = "com.argmaxinc.deviceloop.host"
    let target: Target

    init() async throws {
        target = try await TargetResolver.resolve(ProcessInfo.processInfo.environment["DEVICELOOP_TEST_SIMULATOR"])
    }

    func example(_ name: String) throws -> JSONValue {
        try JSONValue(data: Data(contentsOf: FlowTests.examples.appending(path: "\(name).json")))
    }

    func file(_ result: CommandResult, _ name: String) -> URL? {
        result.files.first { $0.lastPathComponent == name }
    }

    @Test func fixtureFlowPasses() async throws {
        let result = try await FlowCommands.run(target, flow: try example("fixture"))
        #expect(result.json["status"] == "passed", "\(result.text)")
        #expect(result.json["screenshots"] == ["1-fixture-final.png"])
        #expect(file(result, "1-fixture-final.png").map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func failingAssertStopsTheFlowRunsCleanupAndKeepsEvidence() async throws {
        let result = try await FlowCommands.run(target, flow: try example("fixture-fail"))
        let statuses = result.json["steps"]?.array?.compactMap { $0["status"]?.string }
        #expect(result.json["status"] == "failed", "\(result.text)")
        #expect(statuses == ["passed", "passed", "failed", "skipped"])
        #expect(result.json["steps"]?[2]?["error"]?["code"] == "assertion_failed")
        #expect(result.json["cleanup"]?[0]?["kind"] == "press")
        #expect(result.json["cleanup"]?[0]?["status"] == "passed")
        for name in ["result.json", "failure.png"] {
            #expect(file(result, name).map { FileManager.default.fileExists(atPath: $0.path) } == true, "\(name)")
        }
        let found = try await UICommands.find(target, app: Self.host, query: ElementQuery(id: "fixture.counter.value"), all: false)
        #expect(found.json["matches"]?[0]?["label"] == "Count: 1", "\(found.text)")
    }

    @Test func relaunchStartsTheSecondRunAtCountZeroAndRecordsProcessRestart() async throws {
        let first = try await FlowCommands.run(target, flow: try example("fixture"))
        #expect(first.json["status"] == "passed", "\(first.text)")
        let increment: JSONValue = [
            "schema": "deviceloop.flow/1", "name": "increment",
            "app": ["bundleID": .string(Self.host), "arguments": ["--deviceloop-fixture"]],
            "steps": [
                ["settle": [:]], ["tap": ["id": "fixture.counter.increment"]],
                ["assert": ["element": ["id": "fixture.counter.value"], "label": "Count: 1"]],
            ],
        ]
        let left = try await FlowCommands.run(target, flow: increment)
        #expect(left.json["status"] == "passed", "\(left.text)")
        #expect(left.json["isolation"] == "none")
        let second = try await FlowCommands.run(target, flow: try example("fixture"))
        #expect(second.json["status"] == "passed", "\(second.text)")
        #expect(second.json["isolation"] == "processRestart")
        #expect(second.json["app"]?["bundleID"] == .string(Self.host))
    }

    func dataContainer(_ bundleID: String) async throws -> URL {
        let path = try await Simctl.run(["get_app_container", target.udid, bundleID, "data"]).stdoutString
        return URL(filePath: path.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Reinstalls a copy of the runner's host app under another bundle ID, so the shared host stays installed.
    @Test func reinstallClearsAppDataAndRecordsReinstalled() async throws {
        let probe = "com.argmaxinc.deviceloop.reinstallprobe"
        let folder = FileManager.default.temporaryDirectory.appending(path: "deviceloop-reinstall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = try await RunnerBuild.products(for: target) { _ in }.appending(path: "Debug-iphonesimulator/DeviceLoopHost.app")
        let app = folder.appending(path: "ReinstallProbe.app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: host, to: app)
        let plist = app.appending(path: "Info.plist")
        var info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        info["CFBundleIdentifier"] = probe
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: plist)
        _ = try await AppCommands.install(target, path: app)
        try Data().write(to: try await dataContainer(probe).appending(path: "marker"))

        let flow: JSONValue = [
            "schema": "deviceloop.flow/1", "name": "reinstall", "app": ["bundleID": .string(probe), "arguments": ["--deviceloop-fixture"]],
            "reset": "reinstall", "appPath": .string(app.path),
            "steps": [["assert": ["element": ["id": "fixture.counter.value"], "label": "Count: 0"]]],
        ]
        var result: CommandResult?
        do {
            result = try await FlowCommands.run(target, flow: flow)
        } catch {
            Issue.record(error)
        }
        let markerKept = (try? await dataContainer(probe)).map { FileManager.default.fileExists(atPath: $0.appending(path: "marker").path) }
        _ = try await AppCommands.uninstall(target, bundleID: probe)
        #expect(result?.json["status"] == "passed", "\(result?.text ?? "")")
        #expect(result?.json["isolation"] == "reinstalled")
        #expect(markerKept == false)
    }

    @Test func resetNoneLaunchesAStoppedAppWithTheFlowArguments() async throws {
        _ = try await UICommands.perform(.launch(bundleID: Self.host, arguments: ["--deviceloop-fixture"]), on: target, app: Self.host)
        _ = try await AppCommands.terminate(target, bundleID: Self.host)
        let flow: JSONValue = [
            "schema": "deviceloop.flow/1", "name": "reset-none", "app": ["bundleID": .string(Self.host)],
            "steps": [["assert": ["element": ["label": "DeviceLoop runner"], "is": "exists", "timeoutMs": 5000]]],
        ]
        let result = try await FlowCommands.run(target, flow: flow)
        #expect(result.json["status"] == "passed", "\(result.text)")
    }
}
