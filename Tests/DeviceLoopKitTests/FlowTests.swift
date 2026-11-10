//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct FlowTests {
    static let examples = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Examples/Flows").standardized

    func flow(steps: [JSONValue], _ fields: [String: JSONValue] = [:]) -> JSONValue {
        var object: [String: JSONValue] = [
            "schema": "deviceloop.flow/1",
            "name": "test",
            "app": ["bundleID": "com.example.app", "arguments": ["--fixture"], "environment": ["MODE": "test"]],
            "steps": .array(steps),
        ]
        object.merge(fields) { _, new in new }
        return .object(object)
    }

    func rejection(_ json: JSONValue) -> DeviceLoopError? {
        do {
            _ = try Flow(json)
            return nil
        } catch {
            return error as? DeviceLoopError
        }
    }

    @Test func exampleFlowsValidate() throws {
        let pass = try Flow(JSONValue(data: Data(contentsOf: Self.examples.appending(path: "fixture.json"))))
        let fail = try Flow(JSONValue(data: Data(contentsOf: Self.examples.appending(path: "fixture-fail.json"))))
        #expect(pass.steps.count == 21)
        #expect(fail.steps[2].action == .assert(ElementQuery(id: "fixture.counter.value"), .label("Count: 2")))
    }

    @Test func unknownStepKindNamesItsPath() {
        let steps: [JSONValue] = [["sleep": ["ms": 10]], ["sleep": ["ms": 10]], ["sleep": ["ms": 10]], ["tapp": ["id": "login"]]]
        let error = rejection(flow(steps: steps))
        #expect(error?.code == .badArguments)
        #expect(error?.message == "steps[3].tapp: unknown step kind.")
    }

    @Test func unknownFieldNamesItsPath() {
        #expect(rejection(flow(steps: [["tap": ["id": "login", "lable": "Log In"]]]))?.message == "steps[0].tap.lable: unknown field.")
        #expect(rejection(flow(steps: [["sleep": ["ms": 10]]], ["setps": []]))?.message == "setps: unknown field.")
        #expect(rejection(flow(steps: [["sleep": ["ms": 10, "index": 2]]]))?.message == "steps[0].sleep.index: unknown field.")
        let into: JSONValue = ["type": ["text": "hi", "into": ["id": "field", "role": "x"]]]
        #expect(
            rejection(flow(steps: [], ["cleanup": [into], "steps": [["sleep": ["ms": 1]]]]))?.message
                == "cleanup[0].type.into.role: unknown field.")
    }

    @Test func unknownElementTypeNamesItsPath() {
        let error = rejection(flow(steps: [["sleep": ["ms": 10]], ["tap": ["id": "login", "type": "buton"]]]))
        #expect(error?.code == .badArguments)
        #expect(error?.message == "steps[1].tap.type: buton is not an element type.")
        #expect(error?.fix?.contains("button, cell, checkBox") == true)
    }

    @Test func snapshotSelectorsAreRejected() {
        for key in ["ref", "index", "predicate"] {
            let step: JSONValue = ["tap": .object(["label": "OK", key: "e5"])]
            let error = rejection(flow(steps: [step]))
            #expect(error?.message.hasPrefix("steps[0].tap.\(key): ") == true)
            #expect(error?.message.contains("does not replay") == true)
        }
    }

    @Test func schemaMustBePresentAndKnown() {
        var missing = flow(steps: [["sleep": ["ms": 10]]]).object ?? [:]
        missing["schema"] = nil
        #expect(rejection(.object(missing))?.message == "schema: is missing.")
        #expect(
            rejection(flow(steps: [["sleep": ["ms": 10]]], ["schema": "deviceloop.flow/2"]))?.message
                == "schema: must be deviceloop.flow/1.")
        #expect(
            rejection(flow(steps: [["sleep": ["ms": 10]]], ["schema": "deviceloop-flow/1"]))?.message
                == "schema: must be deviceloop.flow/1.")
    }

    @Test func typedTextReachesTheRequestByteForByte() throws {
        let text = "echo $(rm -rf ~) `id` \"quoted\" 'single' \\n\nsecond line\t\u{e9}"
        let file = #"""
            {"schema": "deviceloop.flow/1", "name": "t", "app": {"bundleID": "com.example.app"},
             "steps": [{"type": {"text": "echo $(rm -rf ~) `id` \"quoted\" 'single' \\n\nsecond line\t\u00e9"}}]}
            """#
        let parsed = try Flow(JSONValue(data: Data(file.utf8)))
        guard case .ui(.type(let typed, _, _)) = parsed.steps[0].action else {
            Issue.record("Expected a type step")
            return
        }
        let request = try JSONDecoder().decode(TypeRequest.self, from: JSONEncoder().encode(TypeRequest(text: typed)))
        #expect(Array(request.text.utf8) == Array(text.utf8))
    }

    @Test func outOfRangeNumbersAreRejected() {
        let steps: [JSONValue] = [
            ["tap": ["id": "a", "timeoutMs": 0]],
            ["tap": ["id": "a", "timeoutMs": 120_001]],
            ["tap": ["id": "a", "timeoutMs": 1.5]],
            ["sleep": ["ms": 10_001]],
            ["sleep": ["ms": 0]],
            ["hold": ["id": "a", "ms": 10_001]],
            ["tap": ["x": -1, "y": 10]],
            ["tap": ["x": 10, "y": 10_001]],
            ["swipe": ["direction": "up", "velocity": 0]],
            ["drag": ["from": ["x": 1, "y": 1], "to": ["x": 2, "y": 2], "holdMs": 10_001]],
            ["settle": ["quietMs": 10_001]],
        ]
        for step in steps {
            #expect(rejection(flow(steps: [step]))?.message.contains("must be") == true, "\(step)")
        }
        #expect(rejection(flow(steps: [["sleep": ["ms": 1]]], ["timeoutMs": 1_800_001]))?.message.hasPrefix("timeoutMs: ") == true)
        #expect(throws: Never.self) { try Flow(flow(steps: [["sleep": ["ms": 10_000]]], ["timeoutMs": 1_800_000])) }
    }

    @Test func laterKindsAreNotInFlowV1() {
        for kind in ["siri", "location", "appearance", "orientation", "audit", "checkpoint"] {
            let error = rejection(flow(steps: [.object([kind: ["text": "x"]])]))
            #expect(error?.message == "steps[0].\(kind): \(kind) is not in flow v1.")
        }
    }

    @Test func targetsNeedExactlyOneSelectorOrAPoint() throws {
        #expect(rejection(flow(steps: [["tap": ["id": "a", "label": "A"]]]))?.message == "steps[0].tap: takes one of id and label.")
        #expect(rejection(flow(steps: [["tap": ["type": "button"]]]))?.message == "steps[0].tap: needs id, label or labelContains.")
        #expect(
            rejection(flow(steps: [["tap": ["x": 1, "y": 2, "id": "a"]]]))?.message == "steps[0].tap.id: a point target takes only x and y."
        )
        #expect(
            rejection(flow(steps: [["assert": ["element": ["x": 1, "y": 2], "is": "exists"]]]))?.message
                == "steps[0].assert.element.x: unknown field.")
        let parsed = try Flow(flow(steps: [["tap": ["labelContains": "wi", "type": "cell"]], ["doubletap": ["x": 10, "y": 20]]]))
        #expect(parsed.steps[0].action == .ui(.tap(ElementTarget(query: ElementQuery(type: "cell", labelContains: "wi")))))
        #expect(parsed.steps[1].action == .ui(.tap(ElementTarget(point: WirePoint(x: 10, y: 20)), count: 2)))
    }

    @Test func assertTakesOneCondition() throws {
        let element: JSONValue = ["id": "a"]
        #expect(rejection(flow(steps: [["assert": ["element": element]]]))?.message == "steps[0].assert: needs is, label or value.")
        #expect(
            rejection(flow(steps: [["assert": ["element": element, "is": "exists", "label": "A"]]]))?.message
                == "steps[0].assert: takes one of is and label.")
        #expect(
            rejection(flow(steps: [["assert": ["element": element, "is": "visible"]]]))?.message
                == "steps[0].assert.is: must be exists, gone, hittable or enabled.")
        let parsed = try Flow(flow(steps: [["assert": ["element": element, "value": "On", "timeoutMs": 500]]]))
        #expect(parsed.steps[0] == FlowStep(.assert(ElementQuery(id: "a"), .value("On")), timeoutMs: 500))
    }

    @Test func launchDefaultsToTheFlowApp() throws {
        let parsed = try Flow(flow(steps: [["launch": [:]], ["launch": ["bundleID": "com.apple.Preferences"]]]))
        #expect(
            parsed.steps[0].action == .ui(.launch(bundleID: "com.example.app", arguments: ["--fixture"], environment: ["MODE": "test"])))
        #expect(parsed.steps[1].action == .ui(.launch(bundleID: "com.apple.Preferences")))
    }

    @Test func reinstallNeedsAppPathAndOnlyReinstallTakesOne() {
        #expect(rejection(flow(steps: [["sleep": ["ms": 1]]], ["reset": "reinstall"]))?.message == "appPath: is missing.")
        #expect(
            rejection(flow(steps: [["sleep": ["ms": 1]]], ["reset": "relaunch", "appPath": "App.app"]))?.message
                == "appPath: is used only with reset reinstall.")
        #expect(throws: Never.self) { try Flow(flow(steps: [["sleep": ["ms": 1]]], ["reset": "reinstall", "appPath": "App.app"])) }
    }

    @Test func appPathMustBeAnAppOrIpa() {
        #expect(
            rejection(flow(steps: [["sleep": ["ms": 1]]], ["reset": "reinstall", "appPath": "App.zip"]))?.message
                == "appPath: must be an .app bundle or an .ipa file.")
        #expect(throws: Never.self) { try Flow(flow(steps: [["sleep": ["ms": 1]]], ["reset": "reinstall", "appPath": "build/App.ipa"])) }
    }

    @Test func unknownRequirementNamesItsIndex() {
        let error = rejection(flow(steps: [["sleep": ["ms": 1]]], ["requires": ["home button", "volume button"]]))
        #expect(error?.message == "requires[1]: volume button is not a requirement DeviceLoop checks.")
    }

    @Test func validateSummarizesTheExampleFlow() throws {
        let result = try FlowCommands.validate(try FlowCommands.load(Self.examples.appending(path: "fixture.json").path))
        #expect(result.json["name"] == "fixture")
        #expect(result.json["steps"] == 21)
        #expect(result.json["requirements"] == ["ui runner", "home button"])
    }

    @Test func badFlowFileFailsValidationWithItsPathAndExitStatusTwo() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "deviceloop-flow-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try flow(steps: [["sleep": ["ms": 1]], ["tapp": ["id": "login"]]]).data().write(to: file)
        let error = #expect(throws: DeviceLoopError.self) { try FlowCommands.validate(try FlowCommands.load(file.path)) }
        #expect(error?.message == "steps[1].tapp: unknown step kind.")
        #expect(error?.exitCode == 2)
    }

    @Test func invalidJSONNamesTheLineAndColumn() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "deviceloop-flow-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("{\n \"name\": }".utf8).write(to: file)
        let error = #expect(throws: DeviceLoopError.self) { try FlowCommands.load(file.path) }
        #expect(error?.code == .badArguments)
        #expect(error?.detail?.contains("line 2") == true, "\(error?.rendered ?? "")")
    }

    @Test func appAndTimeoutOverridesApplyBeforeValidation() throws {
        let json = FlowCommands.overriding(flow(steps: [["launch": [:]]]), app: "com.example.other", timeoutMs: 5000)
        let parsed = try Flow(json)
        #expect(parsed.app.bundleID == "com.example.other")
        #expect(parsed.timeoutMs == 5000)
        let launch = UIStep.launch(bundleID: "com.example.other", arguments: ["--fixture"], environment: ["MODE": "test"])
        #expect(parsed.steps[0].action == .ui(launch))
    }

    @Test func savedFlowFilesHideTypedTextInsideARun() throws {
        let json = flow(steps: [
            ["type": ["text": "hunter2", "into": ["id": "password"]]], ["assert": ["element": ["id": "password"], "value": "hunter2"]],
        ])
        let result: JSONValue = ["message": #"id=password has value "hunter", expected "hunter2"."#]
        #expect(FlowCommands.typedText(json) == ["hunter2"])
        #expect(FlowCommands.saving(json, from: json) == json)
        let run = try RunStore.create(owned: false)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        try RunStore.$current.withValue(run) {
            let savedFlow = FlowCommands.saving(json, from: json)
            #expect(savedFlow["steps"]?[0]?["type"]?["text"] == "[hidden]")
            #expect(savedFlow["steps"]?[1]?["assert"]?["value"] == "[hidden]")
            let savedText = String(decoding: try savedFlow.data(), as: UTF8.self)
            #expect(!savedText.contains("hunter2"))
            #expect(FlowCommands.saving(result, from: json)["message"] == #"id=password has value "hunter", expected "[hidden]"."#)
        }
    }

    @Test func stepNeedsExactlyOneKind() {
        #expect(rejection(flow(steps: [[:]]))?.message.hasPrefix("steps[0]: must be an object with one step kind") == true)
        #expect(rejection(flow(steps: [["tap": ["id": "a"], "sleep": ["ms": 1]]]))?.message.hasPrefix("steps[0]: ") == true)
    }
}
