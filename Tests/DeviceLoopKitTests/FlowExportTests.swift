//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct FlowExportTests {
    static let exportCheck = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../ExportCheck/UITests").standardized
    static let exportCheckApp = "com.argmaxinc.deviceloop.exportcheck"
    static let golden = exportCheck.appending(path: "FixtureFlowTests.swift")
    static let fixture = FlowTests.examples.appending(path: "fixture.json")

    func flow(steps: [JSONValue], _ fields: [String: JSONValue] = [:]) throws -> Flow {
        try Flow(FlowTests().flow(steps: steps, fields))
    }

    func rejection(_ body: () throws -> Void) -> DeviceLoopError? {
        do {
            try body()
            return nil
        } catch {
            return error as? DeviceLoopError
        }
    }

    /// Runs `body` with a new temporary folder, then removes it.
    func inFolder(_ body: (URL) async throws -> Void) async throws {
        let folder = try Paths.ensureDirectory(
            FileManager.default.temporaryDirectory.appending(path: "deviceloop-export-\(UUID().uuidString)", directoryHint: .isDirectory))
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(folder)
    }

    /// One step of every exported kind, with labels that need escaping.
    var everyKind: [JSONValue] {
        [
            ["tap": ["id": "login", "type": "button"]],
            ["doubletap": ["label": "Say \"hi\" \\(x)\n\u{1F600}"]],
            ["hold": ["labelContains": "Wi-Fi", "type": "switch", "ms": 1500]],
            ["tap": ["x": 120, "y": 640.5]],
            ["swipe": ["direction": "up"]],
            ["swipe": ["direction": "left", "on": ["id": "list"], "velocity": 1500]],
            ["drag": ["from": ["x": 200, "y": 700], "to": ["x": 200, "y": 200], "velocity": 800, "holdMs": 250]],
            ["type": ["text": "hello"]],
            ["type": ["text": "line\nbreak", "into": ["id": "field"]]],
            ["press": ["button": "action"]],
            ["open": ["url": "https://example.com/a?b=c"]],
            ["sleep": ["ms": 500]],
            ["assert": ["element": ["id": "a"], "is": "exists"]],
            ["assert": ["element": ["id": "a"], "is": "gone"]],
            ["assert": ["element": ["id": "a"], "is": "enabled"]],
            ["assert": ["element": ["id": "a"], "value": "On"]],
            ["screenshot": [:]],
            ["alert": ["button": "Allow"]],
            ["launch": ["bundleID": "com.apple.Preferences", "arguments": ["-a"], "environment": ["B": "2", "A": "1"]]],
            ["tap": ["label": "General"]],
            ["tap": ["label": "Welcome\\nBack"]],
            ["assert": ["element": ["labelContains": "C:\\new"], "label": "C:\\new"]],
            ["assert": ["element": ["id": "a"], "value": "a\\tb"]],
        ]
    }

    @Test(arguments: ["fixture", "fixture-fail"])
    func exportCheckFilesMatchTheExporter(flowName: String) throws {
        let json = try FlowCommands.load(FlowTests.examples.appending(path: "\(flowName).json").path)
        let output = try FlowExport.source(Flow(FlowCommands.overriding(json, app: Self.exportCheckApp, timeoutMs: nil)))
        #expect(output.source == (try String(contentsOf: Self.exportCheck.appending(path: "\(output.className).swift"), encoding: .utf8)))
    }

    @Test func exportsTypecheckAgainstTheSimulatorSDK() async throws {
        try await inFolder { folder in
            let flow = try flow(steps: everyKind, ["cleanup": [["tap": ["id": "done"]], ["press": ["button": "home"]]]])
            let everyKindFile = folder.appending(path: "EveryKindFlowTests.swift")
            try Data(FlowExport.source(flow).source.utf8).write(to: everyKindFile)
            let platform = try await Shell.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-platform-path"]).stdoutString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await Shell.run([
                "xcrun", "--sdk", "iphonesimulator", "swiftc", "-typecheck", "-target", "arm64-apple-ios17.0-simulator",
                "-F", "\(platform)/Developer/Library/Frameworks", "-I", "\(platform)/Developer/usr/lib", "-swift-version", "6",
                Self.golden.path, Self.exportCheck.appending(path: "FixtureFailFlowTests.swift").path, everyKindFile.path,
            ])
            #expect(result.succeeded, "\(result.stderrString)")
            #expect(!result.stderrString.contains("warning:"), "\(result.stderrString)")
        }
    }

    @Test func literalsRoundTripThroughTheCompiler() async throws {
        try await inFolder { folder in
            let label = "quote \" backslash \\ interpolation \\(x) newline \n tab \t emoji \u{1F600}\u{200D}\u{1F469} cafe\u{301}"
            let script = folder.appending(path: "literal.swift")
            try Data("print(\(FlowExport.literal(label)), terminator: \"\")\n".utf8).write(to: script)
            let result = try await Shell.run(["xcrun", "swift", script.path])
            #expect(result.succeeded, "\(result.stderrString)")
            #expect(result.stdout == Data(label.utf8))
            #expect(FlowExport.literal(label).allSatisfy { $0.isASCII && $0 != "\n" })
        }
    }

    @Test func unsupportedStepsFailTogetherAndWriteNothing() async throws {
        try await inFolder { folder in
            let json = FlowTests().flow(
                steps: [["type": ["text": "x", "clear": true]], ["swipe": ["direction": "up", "on": ["x": 1, "y": 2]]]],
                [
                    "reset": "reinstall", "appPath": "App.app", "setup": [["settle": [:]]],
                    "cleanup": [["type": ["text": "y", "into": ["id": "x"], "clear": true]]],
                ])
            let file = folder.appending(path: "TestFlowTests.swift")
            let error = rejection { _ = try FlowCommands.export(json, to: file) }
            #expect(error?.code == .badArguments)
            #expect(error?.exitCode == 2)
            #expect(error?.message == "Flow test cannot be exported to XCTest.")
            #expect(
                error?.detail == """
                    reset reinstall: XCUIApplication cannot install or uninstall apps.
                    setup[0] settle: XCUIAutomation has no public wait for the screen to settle.
                    steps[0] type: clear is not exported.
                    steps[1] swipe: this step needs an element, not a point.
                    cleanup[0] type: clear is not exported.
                    """)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func pointsDragsAndSleepsAreReportedFragile() throws {
        let output = try FlowExport.source(flow(steps: everyKind))
        #expect(output.supported.count == everyKind.count)
        #expect(
            output.fragile == [
                "steps[3] tap: a point target depends on the screen size and layout.",
                "steps[6] drag: drag points depend on the screen size and layout.",
                "steps[11] sleep: a fixed sleep depends on timing.",
            ])
    }

    @Test func flowNamesBecomeSwiftTypeNames() {
        #expect(FlowExport.typeName("fixture-fail") == "FixtureFail")
        #expect(FlowExport.typeName("2 step \u{2713} log_in") == "Flow2StepLogIn")
        #expect(FlowExport.typeName("\u{1F600}") == "Flow")
    }

    @Test func classNameMustBeASwiftTypeName() throws {
        let flow = try flow(steps: [["sleep": ["ms": 1]]])
        #expect(rejection { _ = try FlowExport.source(flow, className: "Login-Tests") }?.code == .badArguments)
        #expect(try FlowExport.source(flow, className: "LoginTests").source.contains("final class LoginTests: XCTestCase {"))
    }

    @Test func launchingAnotherAppRetargetsLaterSteps() throws {
        let source = try FlowExport.source(flow(steps: everyKind, ["cleanup": [["tap": ["id": "done"]]]])).source
        #expect(source.contains("            let app = XCUIApplication(bundleIdentifier: \"com.apple.Preferences\")\n"))
        #expect(source.contains("        var app = XCUIApplication(bundleIdentifier: \"com.example.app\")\n"))
        #expect(source.contains("        app = XCUIApplication(bundleIdentifier: \"com.apple.Preferences\")\n"))
    }

    @Test func resetNoneLaunchesTheAppWhenItIsNotRunning() throws {
        let source = try FlowExport.source(flow(steps: [["sleep": ["ms": 1]]])).source
        #expect(source.contains("        if app.state == .notRunning { app.launch() } else { app.activate() }\n"))
    }

    @Test func labelCopiedFromTreeTextIsExportedInBothForms() throws {
        let source = try FlowExport.source(flow(steps: [["assert": ["element": ["label": "a\\tb"], "label": "a\\tb"]]])).source
        #expect(source.contains(#"NSPredicate(format: "label == %@ OR label == %@", "a\\tb", "a\tb")"#))
        #expect(source.contains(#"XCTAssertTrue(["a\\tb", "a\tb"].contains(element.label))"#))
    }

    @Test func emptyValueAssertAcceptsAMissingValue() throws {
        let source = try FlowExport.source(flow(steps: [["assert": ["element": ["id": "a"], "value": ""]]])).source
        #expect(source.contains("NSPredicate(format: \"value == nil OR value == %@\", \"\")"))
        #expect(source.contains("XCTAssertEqual(element.value as? String ?? \"\", \"\")"))
    }

    @Test func appOverrideReplacesTheFlowApp() async throws {
        try await inFolder { folder in
            let file = folder.appending(path: "FixtureFlowTests.swift")
            _ = try FlowCommands.export(try FlowCommands.load(Self.fixture.path), to: file, app: "com.example.other")
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(source.contains("let app = XCUIApplication(bundleIdentifier: \"com.example.other\")"))
            #expect(!source.contains("com.argmaxinc.deviceloop.host"))
        }
    }

    @Test func exportWritesTheGoldenToANewFile() async throws {
        try await inFolder { folder in
            let file = folder.appending(path: "FixtureFlowTests.swift")
            let result = try FlowCommands.export(try FlowCommands.load(Self.fixture.path), to: file, app: Self.exportCheckApp)
            #expect(try String(contentsOf: file, encoding: .utf8) == (try String(contentsOf: Self.golden, encoding: .utf8)))
            #expect(result.text == "flow fixture exported as FixtureFlowTests: 23 steps, 0 fragile\nsaved \(file.path)")
            #expect(result.files == [file])
        }
    }

    @Test func exportRefusesToReplaceAFile() async throws {
        try await inFolder { folder in
            let file = folder.appending(path: "FixtureFlowTests.swift")
            try Data("keep".utf8).write(to: file)
            let error = rejection { _ = try FlowCommands.export(try FlowCommands.load(Self.fixture.path), to: file) }
            #expect(error?.code == .badArguments)
            #expect(error?.message == "\(file.path) already exists.")
            #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
        }
    }

    @Test func exportWritesOnlySwiftFiles() async throws {
        try await inFolder { folder in
            let file = folder.appending(path: "project.pbxproj")
            let error = rejection { _ = try FlowCommands.export(try FlowCommands.load(Self.fixture.path), to: file) }
            #expect(error?.code == .badArguments)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func elementTypeNamesMatchTheRunner() throws {
        let runner = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Runner/UITests/ElementTypes.swift")
        let names = try String(contentsOf: runner, encoding: .utf8).matches(of: /\n    "(\w+)": \./).map { String($0.output.1) }
        #expect(Set(names) == FlowExport.elementTypes)
        #expect(names.count == FlowExport.elementTypes.count)
    }
}
