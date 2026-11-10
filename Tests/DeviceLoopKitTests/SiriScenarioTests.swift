//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Testing

@testable import DeviceLoopKit

private let epoch = "00000000-0000-0000-0000-0000000000e1"
private let operationID = "00000000-0000-0000-0000-0000000000a1"
private let app = "com.example.fixture"

private let target = Target(
    udid: "00000000-0000-0000-0000-000000000001", identifier: "00000000-0000-0000-0000-000000000001", name: "Test Simulator",
    kind: .simulator, deviceType: "iPhone", platform: "iOS", model: "iPhone 17 Pro", productType: "iPhone18,1", osVersion: "27.2",
    connectionState: "connected", bootState: "booted", transport: "sameMachine"
)

private let expectation = SiriScenario.Expectation(entity: "TaskEntity", matching: "marker", property: "title", equals: "Blue marker")

private func scenario(phrases: [String] = ["Add Blue marker"], seed: [SiriScenario.Seed]? = nil, language: String? = nil) -> SiriScenario {
    SiriScenario(
        app: app, reset: .init(intent: "ResetTasksIntent"), seed: seed, phrases: phrases, expect: expectation, requiredLanguage: language)
}

private func ok<Result: Codable & Sendable>(_ result: Result) throws -> FakeRunner.Reply {
    (200, try JSONEncoder().encode(WireResponse(ok: true, result: result)))
}

private func failure(_ status: Int, _ code: String, _ message: String) throws -> FakeRunner.Reply {
    (status, try JSONEncoder().encode(WireResponse<WireEmpty>(ok: false, error: WireError(code: code, message: message))))
}

/// A runner whose intents, Siri, receipt, entity, launch and find routes succeed. `changes` replaces or removes replies, and
/// `calls` gives a route one reply per call.
private func fakeRunner(
    titles: [String] = ["Blue marker"], _ changes: [String: FakeRunner.Reply?] = [:], calls: [String: [FakeRunner.Reply?]] = [:]
) throws -> FakeRunner {
    let info = InfoResult(
        screenWidth: 402, screenHeight: 874, scale: 3, model: "iPhone", systemName: "iOS", systemVersion: "27.2", orientation: "portrait",
        appearance: "light", hardwareButtons: [], preferredLanguages: ["en-US"], locale: "en_US")
    let finished = WireResponse.completed(ActionResult(eventTime: 1), timing: WireTiming(start: 0, end: 1), issues: [])
    let receipt = OperationStatusResult(
        operation: OperationReference(id: operationID, sessionEpoch: epoch, phase: "finished"), responseStatus: 200,
        responseContentType: "application/json", responseJSON: String(decoding: try JSONEncoder().encode(finished), as: UTF8.self))
    let entities = titles.enumerated().map { IntentEntity(id: "\($0.offset)", properties: ["title": $0.element]) }
    var replies: [String: FakeRunner.Reply?] = [
        "GET \(RunnerWire.Path.info)": try ok(info),
        "POST \(RunnerWire.Path.intentsRun)": try ok(ActionResult(eventTime: 1)),
        "POST \(RunnerWire.Path.siri)": try ok(
            ActionResult(operation: OperationReference(id: operationID, sessionEpoch: epoch, phase: "accepted"))),
        "GET \(RunnerWire.Path.operations + operationID)": try ok(receipt),
        "POST \(RunnerWire.Path.intentsEntities)": try ok(IntentEntitiesResult(count: entities.count, entities: entities)),
        "POST \(RunnerWire.Path.appLaunch)": try ok(ActionResult(eventTime: 1)),
        "POST \(RunnerWire.Path.find)": try ok(
            FindResult(matches: titles.map { FoundElement(type: "staticText", label: $0, frame: [0, 0, 1, 1]) })),
    ]
    for (route, reply) in changes { replies[route] = reply }
    return FakeRunner(epoch: epoch, replies: replies.mapValues { [$0] }.merging(calls) { $1 })
}

private func run(_ scenario: SiriScenario, _ runner: FakeRunner, settle: Duration = .zero) async throws -> SiriScenarioReport {
    try await SiriCommands.run(
        scenario, target: target, client: runner.client, directory: URL(filePath: "/nonexistent"), settle: settle,
        holdInterval: .seconds(60), pollInterval: .milliseconds(10)
    ) { _ in }
}

@Suite struct SiriScenarioTests {
    @Test func unknownFieldIsRejected() throws {
        let json = #"""
            {"app": "com.example.fixture", "reset": {"intent": "ResetTasksIntent"}, "phrases": ["Add Blue marker"],
             "expect": {"entity": "TaskEntity", "matching": "marker", "property": "title", "equals": "Blue marker", "titel": "x"}}
            """#
        let error = #expect(throws: DeviceLoopError.self) { try SiriScenario.parse(Data(json.utf8), name: "scenario.json") }
        #expect(error?.code == .badArguments)
        #expect(error?.message == "scenario.json has an unknown field expect.titel.")
    }

    @Test func timeoutAboveAnHourIsRejected() throws {
        let json = #"""
            {"app": "com.example.fixture", "reset": {"intent": "ResetTasksIntent"}, "phrases": ["Add Blue marker"], "timeoutS": 1e21,
             "expect": {"entity": "TaskEntity", "matching": "marker", "property": "title", "equals": "Blue marker"}}
            """#
        let error = #expect(throws: DeviceLoopError.self) { try SiriScenario.parse(Data(json.utf8), name: "scenario.json") }
        #expect(error?.code == .badArguments)
    }

    @Test func settleOutsideTenMinutesIsRejected() throws {
        for settle in ["-1", "601"] {
            let json = #"""
                {"app": "com.example.fixture", "reset": {"intent": "ResetTasksIntent"}, "phrases": ["Add Blue marker"],
                 "settleS": \#(settle),
                 "expect": {"entity": "TaskEntity", "matching": "marker", "property": "title", "equals": "Blue marker"}}
                """#
            let error = #expect(throws: DeviceLoopError.self) { try SiriScenario.parse(Data(json.utf8), name: "scenario.json") }
            #expect(error?.message == "scenario.json has a settleS that is not between 0 and 600.")
        }
    }

    @Test func exactCountOfTheExpectedValueIsVerified() {
        #expect(SiriCommands.classify(["Blue marker"], expect: expectation) == .verified)
    }

    @Test func noEntityIsMissing() {
        #expect(SiriCommands.classify([], expect: expectation) == .missing)
    }

    @Test func twoOfTheExpectedValueAreADuplicate() {
        #expect(SiriCommands.classify(["Blue marker", "Blue marker"], expect: expectation) == .duplicate)
    }

    @Test func anotherTitleIsAWrongEntity() {
        #expect(SiriCommands.classify(["Red marker"], expect: expectation) == .wrongEntity)
    }

    @Test func nothingReadBackIsUnverified() {
        #expect(SiriCommands.classify(nil, expect: expectation) == .unverified)
    }

    @Test func anyPhraseThatIsNotVerifiedExitsEight() {
        let phrases: JSONValue = [["outcome": "verified"], ["outcome": "duplicate"]]
        #expect(SiriCommands.exitCode(CommandResult(text: "", json: ["phrases": phrases, "notSent": []])) == 8)
        #expect(SiriCommands.exitCode(CommandResult(text: "", json: ["phrases": [["outcome": "verified"]], "notSent": []])) == 0)
    }

    @Test func eachPhraseRunsAfterTheResetAndCleanupRunsTheResetOnly() async throws {
        let runner = try fakeRunner()
        let report = try await run(scenario(phrases: ["Add Blue marker", "Add a Blue marker"]), runner)
        #expect(report.backend == .entity)
        #expect(report.phrases.map(\.outcome) == [.verified, .verified])
        #expect(runner.sent("POST \(RunnerWire.Path.intentsRun)") == 3)
        #expect(runner.requests.last == "POST \(RunnerWire.Path.intentsRun)")
        #expect(report.cleanup == "ran")
    }

    @Test func seedsRunAfterEachReset() async throws {
        let seed = SiriScenario.Seed(intent: "AddTaskIntent", params: ["title": .string("Blue marker")])
        let runner = try fakeRunner(titles: ["Blue marker", "Blue marker"])
        let report = try await run(scenario(seed: [seed]), runner)
        #expect(report.phrases.first?.outcome == .duplicate)
        #expect(runner.sent("POST \(RunnerWire.Path.intentsRun)") == 3)
    }

    @Test func unsupportedIntentsFallBackToUIVerificationWithoutReset() async throws {
        let unsupported = try failure(501, "unsupported", "App Intents testing needs iOS 27.0 or later. This device runs iOS 18.5.")
        let runner = try fakeRunner(titles: ["Red marker"], ["POST \(RunnerWire.Path.intentsRun)": unsupported])
        let report = try await run(scenario(), runner)
        #expect(report.backend == .ui)
        #expect(report.resetSkipped == "App Intents testing needs iOS 27.0 or later. This device runs iOS 18.5.")
        #expect(report.phrases.first?.outcome == .wrongEntity)
        #expect(runner.sent("POST \(RunnerWire.Path.intentsRun)") == 1)
        #expect(runner.sent("POST \(RunnerWire.Path.intentsEntities)") == 0)
        #expect(runner.sent("POST \(RunnerWire.Path.find)") == 1)
        #expect(report.cleanup == "not_run")
    }

    @Test func seedsWithoutAppIntentsAreUnsupported() async throws {
        let unsupported = try failure(501, "unsupported", "App Intents testing needs iOS 27.0 or later.")
        let seeded = scenario(seed: [SiriScenario.Seed(intent: "AddTaskIntent")])
        let runner = try fakeRunner(["POST \(RunnerWire.Path.intentsRun)": unsupported])
        let error = await #expect(throws: DeviceLoopError.self) { try await run(seeded, runner) }
        #expect(error?.code == .unsupportedOnTarget)
        #expect(runner.sent("POST \(RunnerWire.Path.siri)") == 0)
    }

    @Test func seedFixNamesNoIOSVersionAndDetailSaysWhyIntentsDidNotLoad() async throws {
        let message = "AppIntentsTesting from this Xcode did not load on iOS 27.0: image not found"
        let unsupported = try failure(501, "unsupported", message)
        let seeded = scenario(seed: [SiriScenario.Seed(intent: "AddTaskIntent")])
        let error = await #expect(throws: DeviceLoopError.self) {
            try await run(seeded, fakeRunner(["POST \(RunnerWire.Path.intentsRun)": unsupported]))
        }
        #expect(error?.detail == message)
        #expect(error?.fix?.contains("iOS") == false)
    }

    @Test func readBackWaitsForTheSettleAfterSiriAccepts() async throws {
        let runner = try fakeRunner()
        let report = try await run(scenario(), runner, settle: .milliseconds(300))
        #expect(report.phrases.first?.outcome == .verified)
        let accepted = try #require(runner.sentAt("POST \(RunnerWire.Path.siri)"))
        let readBack = try #require(runner.sentAt("POST \(RunnerWire.Path.intentsEntities)"))
        #expect(readBack - accepted >= .milliseconds(300))
    }

    @Test func errorAfterAReportedPhraseKeepsItListsTheRestAndRunsCleanup() async throws {
        let reset = try ok(ActionResult(eventTime: 1))
        let failed = try failure(500, "intent_failed", "ResetTasksIntent threw")
        let runner = try fakeRunner(calls: ["POST \(RunnerWire.Path.intentsRun)": [reset, failed, reset]])
        let report = try await run(scenario(phrases: ["Add Blue marker", "Add Red marker"]), runner)
        #expect(report.phrases.map(\.phrase) == ["Add Blue marker"])
        #expect(report.notSent == ["Add Red marker"])
        #expect(report.error?.code == .intentFailed)
        #expect(report.cleanup == "ran")
        #expect(runner.sent("POST \(RunnerWire.Path.siri)") == 1)
    }

    @Test func lostConnectionIsUncertainAndStopsWithoutResubmitOrCleanup() async throws {
        let runner = try fakeRunner(["POST \(RunnerWire.Path.siri)": nil])
        let report = try await run(scenario(phrases: ["Add Blue marker", "Add Red marker"]), runner)
        #expect(report.phrases.map(\.outcome) == [.uncertain])
        #expect(report.phrases.first?.error?.code == .actionOutcomeUnknown)
        #expect(report.notSent == ["Add Red marker"])
        #expect(runner.sent("POST \(RunnerWire.Path.siri)") == 1)
        #expect(runner.sent("POST \(RunnerWire.Path.intentsRun)") == 1)
        #expect(report.cleanup == "not_run")
    }

    @Test func failedReadBackIsUnverifiedWithTheError() async throws {
        let unreadable = try failure(400, "bad_request", "Could not read property title of TaskEntity as a string")
        let report = try await run(scenario(), fakeRunner(["POST \(RunnerWire.Path.intentsEntities)": unreadable]))
        #expect(report.phrases.first?.outcome == .unverified)
        #expect(report.phrases.first?.error?.code == .badArguments)
        #expect(report.cleanup == "ran")
    }

    @Test func failingResetStopsBeforeSiriWithIntentFailed() async throws {
        let failed = try failure(500, "intent_failed", "No intent named ResetTasksIntent")
        let runner = try fakeRunner(["POST \(RunnerWire.Path.intentsRun)": failed])
        let error = await #expect(throws: DeviceLoopError.self) { try await run(scenario(), runner) }
        #expect(error?.code == .intentFailed)
        #expect(runner.sent("POST \(RunnerWire.Path.siri)") == 0)
    }

    @Test func otherDeviceLanguageStopsBeforeAnyRequest() async throws {
        let runner = try fakeRunner()
        let error = await #expect(throws: DeviceLoopError.self) { try await run(scenario(language: "fr"), runner) }
        #expect(error?.code == .unsupportedOnTarget)
        #expect(runner.requests == ["GET \(RunnerWire.Path.info)"])
    }

    @Test func unknownDeviceLanguageIsReportedAsNotChecked() async throws {
        let languageScenario = scenario(language: "fr")
        let report = try await run(languageScenario, fakeRunner(["GET \(RunnerWire.Path.info)": nil]))
        #expect(report.phrases.first?.outcome == .verified)
        let text = SiriCommands.render(report, scenario: languageScenario, target: target)
        #expect(text.contains("required language fr was not checked, because the device language is unknown."))
    }

    @Test func languageMatchesTheDeviceLanguageWithItsRegion() async throws {
        let report = try await run(scenario(language: "en"), fakeRunner())
        #expect(report.phrases.first?.outcome == .verified)
        #expect(report.deviceLanguages == ["en-US"])
    }
}
