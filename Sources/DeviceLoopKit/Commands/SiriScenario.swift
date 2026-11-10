//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation

/// A Siri phrase test: each phrase runs after the app's reset intent, then the app's entities are read back.
public struct SiriScenario: Codable, Sendable, Equatable {
    public struct Reset: Codable, Sendable, Equatable {
        /// App Intent type name that removes the app's test data.
        public var intent: String
    }

    /// An App Intent run after each reset, for example to add an entity a phrase should not duplicate.
    public struct Seed: Codable, Sendable, Equatable {
        public var intent: String
        public var params: [String: IntentValue]?
    }

    /// Entities of `entity` found by `matching`, whose `property` should equal `equals` exactly `count` times.
    public struct Expectation: Codable, Sendable, Equatable {
        public var entity: String
        public var matching: String
        public var property: String
        public var equals: String
        /// Defaults to 1.
        public var count: Int?
    }

    public var app: String
    public var reset: Reset
    public var seed: [Seed]?
    public var phrases: [String]
    public var expect: Expectation
    /// Seconds to wait for each Siri receipt. Defaults to 180.
    public var timeoutS: Double?
    /// Seconds after Siri accepts a phrase before the after screenshot and read-back. Defaults to 10.
    public var settleS: Double?
    /// The device's first preferred language must be this language, for example `en` or `en-US`.
    public var requiredLanguage: String?

    static let fields: [String: Set<String>] = [
        "": ["app", "reset", "seed", "phrases", "expect", "timeoutS", "settleS", "requiredLanguage"],
        "reset": ["intent"],
        "seed": ["intent", "params"],
        "expect": ["entity", "matching", "property", "equals", "count"],
    ]

    /// Reads a scenario and rejects unknown fields, empty names and phrases, a negative count, a timeout outside 0 to 3600 s
    /// and a settle time outside 0 to 600 s.
    public static func load(from url: URL) throws -> SiriScenario {
        let contents: Data
        do {
            contents = try Data(contentsOf: url)
        } catch {
            throw DeviceLoopError(
                .badArguments, "Could not read \(url.path).", fix: "Pass the path of a scenario JSON file.", detail: "\(error)")
        }
        return try parse(contents, name: url.lastPathComponent)
    }

    static func parse(_ data: Data, name: String) throws -> SiriScenario {
        let fix = "See `deviceloop siri test --help` for the scenario fields."
        guard let json = try? JSONValue(data: data) else {
            throw DeviceLoopError(.badArguments, "\(name) is not JSON.", fix: fix)
        }
        if let field = unknownFields(json).first {
            throw DeviceLoopError(.badArguments, "\(name) has an unknown field \(field).", fix: fix)
        }
        let scenario: SiriScenario
        do {
            scenario = try JSONDecoder().decode(SiriScenario.self, from: data)
        } catch {
            throw DeviceLoopError(.badArguments, "\(name) is not a valid Siri scenario.", fix: fix, detail: "\(error)")
        }
        if let problem = scenario.problem {
            throw DeviceLoopError(.badArguments, "\(name) \(problem).", fix: fix)
        }
        return scenario
    }

    /// Field paths the schema does not define, for example `expect.titel`. Seed parameter names are not checked.
    static func unknownFields(_ json: JSONValue) -> [String] {
        let objects = [("", json), ("reset", json["reset"]), ("expect", json["expect"])] + (json["seed"]?.array ?? []).map { ("seed", $0) }
        return objects.flatMap { path, object in
            (object?.object?.keys.sorted() ?? []).filter { !(fields[path]?.contains($0) ?? true) }.map {
                path.isEmpty ? $0 : "\(path).\($0)"
            }
        }
    }

    var problem: String? {
        let names = [app, reset.intent, expect.entity, expect.matching, expect.property, expect.equals] + (seed ?? []).map(\.intent)
        if names.contains(where: \.isEmpty) { return "has an empty app, intent, entity, matching, property or equals" }
        if phrases.isEmpty { return "has no phrases" }
        if phrases.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) { return "has an empty phrase" }
        if (expect.count ?? 1) < 0 { return "expects a negative count" }
        if let timeoutS, !(timeoutS > 0 && timeoutS <= 3600) { return "has a timeoutS that is not between 0 and 3600" }
        if let settleS, !(0 ... 600).contains(settleS) { return "has a settleS that is not between 0 and 600" }
        if requiredLanguage?.isEmpty == true { return "has an empty requiredLanguage" }
        return nil
    }
}

public enum SiriPhraseOutcome: String, Codable, Sendable {
    /// `count` entities, all with the expected value.
    case verified
    /// Fewer entities with the expected value than `count`, and no others.
    case missing
    /// An entity with another value was found.
    case wrongEntity = "wrong_entity"
    /// More entities with the expected value than `count`.
    case duplicate
    /// Nothing could be read back.
    case unverified
    /// The connection was lost, so what happened is unknown. The scenario stops.
    case uncertain
}

/// How a scenario reads entities back.
public enum SiriScenarioBackend: String, Codable, Sendable {
    /// The entity query, through App Intents testing.
    case entity
    /// Labels in the app's UI, where App Intents testing is unsupported.
    case ui
}

public struct SiriPhraseResult: Codable, Sendable, Equatable {
    public var phrase: String
    public var outcome: SiriPhraseOutcome
    /// Property values read back. Nil when nothing could be read.
    public var observed: [String]?
    public var operation: OperationReference?
    public var responseStatus: Int?
    public var issues: [WireIssue]
    public var screenshots: [String]
    /// Why nothing was read back, or what stopped the scenario.
    public var error: DeviceLoopError?
}

/// The `siri test` result: printed with --json and saved as report.json.
public struct SiriScenarioReport: Codable, Sendable, Equatable {
    public var app: String
    public var backend: SiriScenarioBackend?
    /// Why the reset intent did not run, with the UI backend.
    public var resetSkipped: String?
    public var requiredLanguage: String?
    public var deviceLanguages: [String]?
    public var siriLanguage = "unknown"
    public var siriEnabled = "unknown"
    public var phrases: [SiriPhraseResult] = []
    /// Phrases not sent after a phrase with an uncertain outcome, or from the phrase that `error` stopped.
    public var notSent: [String] = []
    /// The error that stopped the scenario after a phrase was reported.
    public var error: DeviceLoopError?
    /// `ran`, `not_run` or `failed`.
    public var cleanup = "not_run"
    public var cleanupError: DeviceLoopError?
    public var scope: String
    public var path: String?
}

extension SiriCommands {
    /// Exit status of `deviceloop siri test` when a phrase is not verified.
    public static let scenarioFailedExitCode: Int32 = 8

    static let transportLost: Set<DeviceLoopError.Code> = [.actionOutcomeUnknown, .runnerUnreachable]

    /// `deviceloop siri test`: runs the scenario and saves report.json and screenshots in `artifacts` or a new directory. Throws
    /// the report's `error` after saving it, with the report path added to its detail.
    public static func test(_ target: Target, scenario: SiriScenario, artifacts: URL?) async throws -> CommandResult {
        guard target.isDrivable else {
            throw DeviceLoopError.unsupported("Siri", on: target, alternatives: ["Use an iPhone or iPad"])
        }
        let directory = try Paths.ensureDirectory(artifacts ?? Paths.newArtifact("siri-test", extension: "json").deletingPathExtension())
        let session = try await UICommands.connect(target)
        var report = try await run(
            scenario, target: target, client: session.client, directory: directory, settle: .seconds(scenario.settleS ?? 10)
        ) {
            try await DeviceCommands.screenshotPNG(target, to: $0)
        }
        let reportURL = directory.appending(path: "report.json")
        report.path = reportURL.path
        let json = try JSONValue(encoding: report)
        try json.data(pretty: true).write(to: reportURL)
        if var error = report.error {
            error.detail = [error.detail, "saved \(reportURL.path)"].compactMap { $0 }.joined(separator: "\n")
            throw error
        }
        let screenshots = report.phrases.flatMap(\.screenshots).map { URL(filePath: $0) }
        return CommandResult(text: render(report, scenario: scenario, target: target), json: json, files: [reportURL] + screenshots)
    }

    /// 0, or `scenarioFailedExitCode` when a phrase is not verified or was not sent.
    public static func exitCode(_ result: CommandResult) -> Int32 {
        let outcomes = result.json["phrases"]?.array?.map { $0["outcome"]?.string } ?? []
        let allSent = result.json["notSent"]?.array?.isEmpty ?? true
        return allSent && outcomes.allSatisfy { $0 == SiriPhraseOutcome.verified.rawValue } ? 0 : scenarioFailedExitCode
    }

    /// Resets, screenshots, sends each phrase, screenshots during the hold and once the receipt is in and `settle` has passed
    /// since Siri accepted the phrase, then reads entities back. An error after a phrase was reported stops the scenario,
    /// runs cleanup and is returned in `error`.
    static func run(
        _ scenario: SiriScenario, target: Target, client: RunnerClient, directory: URL, settle: Duration,
        holdInterval: Duration = .seconds(5), pollInterval: Duration = .seconds(1),
        screenshot: @escaping @Sendable (URL) async throws -> Void
    ) async throws -> SiriScenarioReport {
        let languages = try? await client.get(RunnerWire.Path.info, as: InfoResult.self, timeout: 10).preferredLanguages
        if let required = scenario.requiredLanguage, let first = languages?.first, first != required, !first.hasPrefix(required + "-") {
            throw DeviceLoopError(
                .unsupportedOnTarget, "The scenario needs language \(required), but the first language of \(target.name) is \(first).",
                fix: "Change the language in Settings > General > Language & Region, or requiredLanguage in the scenario.",
                device: target.name)
        }
        var report = SiriScenarioReport(
            app: scenario.app, requiredLanguage: scenario.requiredLanguage, deviceLanguages: languages,
            scope: "Siri effects outside \(scenario.app) are not observed or cleaned.")
        let reset = IntentRunRequest(app: scenario.app, intent: scenario.reset.intent)
        for (number, phrase) in zip(1..., scenario.phrases) {
            var result = SiriPhraseResult(phrase: phrase, outcome: .unverified, issues: [], screenshots: [])
            func shoot(_ name: String) async {
                let url = directory.appending(path: "phrase-\(number)-\(name).png")
                if (try? await screenshot(url)) != nil { result.screenshots.append(url.path) }
            }
            do {
                if report.backend != .ui {
                    do {
                        _ = try await client.post(RunnerWire.Path.intentsRun, reset, as: ActionResult.self)
                        report.backend = .entity
                    } catch let error as DeviceLoopError where error.code == .unsupportedOnTarget && report.backend == nil {
                        guard scenario.seed == nil else {
                            throw DeviceLoopError(
                                .unsupportedOnTarget, "The scenario seeds with App Intents, which \(target.name) cannot run.",
                                fix: "Remove seed, or use a target where App Intents testing loads. Detail says why it did not load here.",
                                detail: error.message, device: target.name)
                        }
                        report.backend = .ui
                        report.resetSkipped = error.message
                    }
                }
                if report.backend == .entity {
                    for seed in scenario.seed ?? [] {
                        let request = IntentRunRequest(app: scenario.app, intent: seed.intent, params: seed.params)
                        _ = try await client.post(RunnerWire.Path.intentsRun, request, as: ActionResult.self)
                    }
                }
                await shoot("before")
                let accepted = try await client.post(RunnerWire.Path.siri, SiriRequest(text: phrase), as: ActionResult.self, timeout: 10)
                let acceptedAt = ContinuousClock.now
                guard let operation = accepted.operation else {
                    throw DeviceLoopError(.internalError, "The runner accepted the Siri request without a receipt.")
                }
                result.operation = operation
                let hold = Task { () -> [String] in
                    var paths: [String] = []
                    while true {
                        try? await Task.sleep(for: holdInterval)
                        if Task.isCancelled { return paths }
                        let url = directory.appending(path: "phrase-\(number)-hold-\(paths.count + 1).png")
                        if (try? await screenshot(url)) != nil { paths.append(url.path) }
                    }
                }
                let polled: Result<OperationStatusResult, any Error>
                do {
                    polled = .success(
                        try await finished(operation, client: client, timeout: .seconds(scenario.timeoutS ?? 180), interval: pollInterval))
                } catch {
                    polled = .failure(error)
                }
                hold.cancel()
                result.screenshots += await hold.value
                let receipt = try polled.get()
                result.operation = receipt.operation
                result.responseStatus = receipt.responseStatus
                let envelope = receipt.responseJSON.flatMap {
                    try? JSONDecoder().decode(WireResponse<ActionResult>.self, from: Data($0.utf8))
                }
                result.issues = envelope?.issues ?? []
                try await Task.sleep(until: acceptedAt + settle)
                await shoot("after")
                do {
                    result.observed = try await observe(scenario, backend: report.backend ?? .ui, client: client)
                } catch let error as DeviceLoopError where !transportLost.contains(error.code) {
                    result.error = error
                }
                result.outcome = classify(result.observed, expect: scenario.expect)
                report.phrases.append(result)
            } catch let error as DeviceLoopError where transportLost.contains(error.code) {
                result.outcome = .uncertain
                result.error = error
                report.phrases.append(result)
                report.notSent = Array(scenario.phrases.dropFirst(number))
                return report
            } catch let error as DeviceLoopError where !report.phrases.isEmpty {
                report.notSent = Array(scenario.phrases.dropFirst(number - 1))
                report.error = error
                break
            }
        }
        if report.backend == .entity {
            do {
                _ = try await client.post(RunnerWire.Path.intentsRun, reset, as: ActionResult.self)
                report.cleanup = "ran"
            } catch let error as DeviceLoopError {
                report.cleanup = "failed"
                report.cleanupError = error
            }
        }
        return report
    }

    /// Values of the expected property: from the entity query, or the labels containing `matching` after bringing the app to the front.
    static func observe(_ scenario: SiriScenario, backend: SiriScenarioBackend, client: RunnerClient) async throws -> [String] {
        let expect = scenario.expect
        switch backend {
            case .entity:
                let request = IntentEntitiesRequest(
                    app: scenario.app, entity: expect.entity, matching: expect.matching, properties: [expect.property])
                let found = try await client.post(RunnerWire.Path.intentsEntities, request, as: IntentEntitiesResult.self)
                return found.entities.map { $0.properties[expect.property] ?? "" }
            case .ui:
                _ = try await client.post(RunnerWire.Path.appLaunch, AppRequest(app: scenario.app, mode: "activate"), as: ActionResult.self)
                let request = FindRequest(app: scenario.app, query: ElementQuery(labelContains: expect.matching), all: true)
                return try await client.post(RunnerWire.Path.find, request, as: FindResult.self).matches.map { $0.label ?? "" }
        }
    }

    /// Classifies the values read back after a phrase. Nil means nothing could be read.
    static func classify(_ observed: [String]?, expect: SiriScenario.Expectation) -> SiriPhraseOutcome {
        guard let observed else { return .unverified }
        let matches = observed.filter { $0 == expect.equals }.count
        if matches < observed.count { return .wrongEntity }
        if matches > expect.count ?? 1 { return .duplicate }
        return matches < expect.count ?? 1 ? .missing : .verified
    }

    static func render(_ report: SiriScenarioReport, scenario: SiriScenario, target: Target) -> String {
        let expect = scenario.expect
        var lines = [target.summary]
        switch report.backend {
            case .entity:
                lines.append("read back: \(expect.entity) entities matching \"\(expect.matching)\" through App Intents")
            case .ui:
                lines.append("read back: UI verification, labels containing \"\(expect.matching)\" in \(scenario.app)")
                let reason = report.resetSkipped?.split(separator: "\n").first.map(String.init) ?? "unknown reason"
                lines.append("the reset intent did not run: \(reason)")
            case nil: break
        }
        let expected = "\(expect.count ?? 1) \"\(expect.equals)\""
        for (number, phrase) in zip(1..., report.phrases) {
            var line = "\(number) \(phrase.outcome.rawValue): \"\(phrase.phrase)\""
            if let observed = phrase.observed {
                let values = observed.map { " \"\($0)\"" }.joined(separator: ",")
                line += ", found \(observed.count)\(values), expected \(expected)"
            } else if let error = phrase.error {
                line += ", \(error.code.rawValue): \(error.message)"
            }
            lines.append(line)
            lines += phrase.issues.map { "  XCTest \($0.isFailure ? "failure" : "issue"): \($0.message)" }
        }
        if !report.notSent.isEmpty {
            let plural = report.notSent.count == 1 ? "" : "s"
            lines.append("stopped without sending \(report.notSent.count) more phrase\(plural). Inspect the device first.")
        }
        switch report.cleanup {
            case "ran": lines.append("cleanup: ran \(scenario.reset.intent)")
            case "failed": lines.append("cleanup failed: \(report.cleanupError?.message ?? "")")
            default: lines.append("cleanup: not run")
        }
        let languages = report.deviceLanguages?.joined(separator: ", ") ?? "unknown"
        lines.append("device languages: \(languages). Siri's language and enabled state are unknown.")
        if let required = report.requiredLanguage {
            lines.append(
                report.deviceLanguages?.first == nil
                    ? "required language \(required) was not checked, because the device language is unknown."
                    : "required language \(required) was checked against the device language only.")
        }
        lines.append(report.scope)
        let screenshotCount = report.phrases.flatMap(\.screenshots).count
        lines.append("saved \(report.path ?? "report.json") and \(screenshotCount) screenshot\(screenshotCount == 1 ? "" : "s")")
        return lines.joined(separator: "\n")
    }
}
