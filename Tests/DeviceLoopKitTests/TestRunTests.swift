//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

private let bundle = URL(filePath: "/jobs/test-1/result.xcresult")

private func target(_ kind: Target.Kind) -> Target {
    Target(
        udid: "UDID", identifier: "UDID", name: "Test iPhone", kind: kind, deviceType: "iPhone", platform: "iOS",
        model: "fixture", productType: "fixture", osVersion: "27.0", connectionState: "connected", bootState: "booted"
    )
}

private func xctestrun(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: "Resources/xctestrun/\(name)", withExtension: "xctestrun"))
}

private func plist(_ name: String) throws -> [String: Any] {
    let data = try Data(contentsOf: try xctestrun(name))
    return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

private func temporaryLog(_ body: (URL) async throws -> Void) async throws {
    let directory = try Paths.ensureDirectory(Paths.home.appending(path: "test-run-tests/\(UUID().uuidString)"))
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory.appending(path: "xcodebuild.log"))
}

@Suite struct TestRunTests {
    @Test func projectAndWorkspaceAreExclusive() {
        #expect(throws: DeviceLoopError.self) {
            try TestCommands.xcodebuildArguments(
                project: "App.xcodeproj", workspace: "App.xcworkspace", scheme: "App", udid: "UDID", resultBundle: bundle)
        }
        #expect(throws: DeviceLoopError.self) {
            try TestCommands.xcodebuildArguments(project: nil, workspace: nil, scheme: "App", udid: "UDID", resultBundle: bundle)
        }
        #expect(throws: DeviceLoopError.self) {
            try TestCommands.xcodebuildArguments(
                project: "App.xcodeproj", workspace: nil, xctestrun: "App.xctestrun", scheme: nil, udid: "UDID", resultBundle: bundle)
        }
    }

    @Test func projectRunNeedsAScheme() {
        #expect(throws: DeviceLoopError.self) {
            try TestCommands.xcodebuildArguments(project: "App.xcodeproj", workspace: nil, scheme: nil, udid: "UDID", resultBundle: bundle)
        }
    }

    @Test func xctestrunRunsTestWithoutBuildingWithSelection() throws {
        let arguments = try TestCommands.xcodebuildArguments(
            project: nil, workspace: nil, xctestrun: "App.xctestrun", scheme: nil, onlyTesting: ["AppTests/Passing"],
            udid: "UDID", resultBundle: bundle
        )
        #expect(
            arguments == [
                "xcrun", "xcodebuild", "test-without-building", "-xctestrun", "App.xctestrun", "-destination", "id=UDID",
                "-resultBundlePath", bundle.path, "-collect-test-diagnostics", "never", "-only-testing:AppTests/Passing",
            ]
        )
    }

    @Test func schemeOptionsDoNotApplyToAnXctestrun() {
        #expect(throws: DeviceLoopError.self) {
            try TestCommands.xcodebuildArguments(
                project: nil, workspace: nil, xctestrun: "App.xctestrun", scheme: "App", udid: "UDID", resultBundle: bundle)
        }
    }

    @Test(arguments: [
        ("runner-simulator", true), ("fixture-device", false), ("fixture-plan-simulator", true), ("fixture-plan-device", false),
    ])
    func xctestrunPlatformComesFromItsProducts(sample: String, simulator: Bool) throws {
        #expect(TestCommands.builtForSimulator(try plist(sample)) == simulator)
    }

    @Test func xctestrunWithoutMetadataIsFormatOne() throws {
        var runner = try plist("runner-simulator")
        runner["__xctestrun_metadata__"] = nil
        #expect(TestCommands.builtForSimulator(runner) == true)
    }

    @Test func undecidedXctestrunIsLeftToXcodebuild() {
        let undecided: [[String: Any]] = [
            ["__xctestrun_metadata__": ["FormatVersion": 3], "App": ["DependentProductPaths": ["__TESTROOT__/Debug-iphoneos/App.app"]]],
            ["App": ["DependentProductPaths": ["__TESTROOT__/Debug/App.app"]]],
            ["App": ["DependentProductPaths": ["__TESTROOT__/Debug-iphoneos/App.app", "__TESTROOT__/Debug-iphonesimulator/App.xctest"]]],
            ["App": ["TestHostPath": "__TESTROOT__/Debug-iphoneos/App.app"]],
        ]
        for plist in undecided {
            #expect(TestCommands.builtForSimulator(plist) == nil)
        }
    }

    @Test func deviceXctestrunIsRefusedOnASimulatorBeforeTheJob() async throws {
        let path = try xctestrun("fixture-device").path
        let error = await #expect(throws: DeviceLoopError.self) {
            _ = try await TestCommands.run(target(.simulator), project: nil, workspace: nil, xctestrun: path, scheme: nil)
        }
        #expect(error?.code == .unsupportedOnTarget)
    }

    @Test func xctestrunNextToAProjectIsAUsageError() async throws {
        let path = try xctestrun("fixture-device").path
        let error = await #expect(throws: DeviceLoopError.self) {
            _ = try await TestCommands.run(target(.simulator), project: "App.xcodeproj", workspace: nil, xctestrun: path, scheme: nil)
        }
        #expect(error?.code == .badArguments)
    }

    @Test func simulatorXctestrunIsRefusedOnADevice() throws {
        #expect(throws: DeviceLoopError.self) {
            try TestCommands.checkXctestrun(try xctestrun("fixture-plan-simulator"), for: target(.device))
        }
        try TestCommands.checkXctestrun(try xctestrun("fixture-plan-device"), for: target(.device))
    }

    @Test func missingXctestrunIsABadArgument() {
        let error = #expect(throws: DeviceLoopError.self) {
            try TestCommands.checkXctestrun(URL(filePath: "/missing/App.xctestrun"), for: target(.simulator))
        }
        #expect(error?.code == .badArguments)
    }

    @Test func diagnosticsAreCollectedOnlyWhenAsked() throws {
        let quiet = try TestCommands.xcodebuildArguments(
            project: "App.xcodeproj", workspace: nil, scheme: "App", udid: "UDID", resultBundle: bundle)
        let verbose = try TestCommands.xcodebuildArguments(
            project: "App.xcodeproj", workspace: nil, scheme: "App", diagnostics: true, udid: "UDID", resultBundle: bundle)
        #expect(quiet.suffix(2) == ["-collect-test-diagnostics", "never"])
        #expect(verbose.suffix(2) == ["-collect-test-diagnostics", "on-failure"])
    }

    @Test func provisioningUpdatesAreOptIn() throws {
        let plain = try TestCommands.xcodebuildArguments(
            project: "App.xcodeproj", workspace: nil, scheme: "App", udid: "UDID", resultBundle: bundle)
        let updating = try TestCommands.xcodebuildArguments(
            project: "App.xcodeproj", workspace: nil, scheme: "App", allowProvisioningUpdates: true, udid: "UDID", resultBundle: bundle)
        #expect(!plain.contains("-allowProvisioningUpdates"))
        #expect(updating.last == "-allowProvisioningUpdates")
    }

    @Test func workspaceRunBuildsTheTestArgv() throws {
        let arguments = try TestCommands.xcodebuildArguments(
            project: nil, workspace: "App.xcworkspace", scheme: "App", testPlan: "Smoke", configuration: "Debug",
            udid: "UDID", resultBundle: bundle
        )
        #expect(
            arguments == [
                "xcrun", "xcodebuild", "test", "-workspace", "App.xcworkspace", "-scheme", "App", "-testPlan", "Smoke",
                "-configuration", "Debug", "-destination", "id=UDID", "-resultBundlePath", bundle.path,
                "-collect-test-diagnostics", "never",
            ]
        )
    }

    @Test func eachOnlyTestingIdentifierGetsItsOwnArgument() throws {
        let arguments = try TestCommands.xcodebuildArguments(
            project: "App.xcodeproj", workspace: nil, scheme: "App",
            onlyTesting: ["AppTests/Passing", "AppTests/Other/testOne()"], skipTesting: ["AppTests/Slow"],
            udid: "UDID", resultBundle: bundle
        )
        #expect(
            arguments.suffix(3) == [
                "-only-testing:AppTests/Passing", "-only-testing:AppTests/Other/testOne()", "-skip-testing:AppTests/Slow",
            ]
        )
    }

    @Test func passthroughArgumentsComeLast() throws {
        let arguments = try TestCommands.xcodebuildArguments(
            project: "App.xcodeproj", workspace: nil, scheme: "App", onlyTesting: ["AppTests/Passing"],
            extraArguments: ["-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=NO"], udid: "UDID", resultBundle: bundle
        )
        #expect(arguments.suffix(4) == ["-only-testing:AppTests/Passing", "-parallel-testing-enabled", "NO", "CODE_SIGNING_ALLOWED=NO"])
    }

    @Test func destinationIsTheResolvedUDID() throws {
        let arguments = try TestCommands.xcodebuildArguments(
            project: "App.xcodeproj", workspace: nil, scheme: "App", udid: "00000000-0000-0000-0000-000000000108", resultBundle: bundle)
        #expect(arguments.filter { $0 == "-destination" }.count == 1)
        let destination = try #require(arguments.firstIndex(of: "-destination"))
        #expect(arguments[destination + 1] == "id=00000000-0000-0000-0000-000000000108")
    }

    @Test(arguments: ["-destination", "-resultBundlePath", "-collect-test-diagnostics"])
    func passthroughCannotReplaceOwnedArguments(owned: String) {
        #expect(throws: DeviceLoopError.self) {
            try TestCommands.xcodebuildArguments(
                project: "App.xcodeproj", workspace: nil, scheme: "App", extraArguments: [owned, "other"],
                udid: "UDID", resultBundle: bundle
            )
        }
    }

    @Test func passedThroughDiagnosticsPointToTheFlag() {
        let error = #expect(throws: DeviceLoopError.self) {
            try TestCommands.xcodebuildArguments(
                project: "App.xcodeproj", workspace: nil, scheme: "App", extraArguments: ["-collect-test-diagnostics", "always"],
                udid: "UDID", resultBundle: bundle
            )
        }
        #expect(error?.fix == "Pass --diagnostics.")
    }

    @Test func timeoutInterruptsTheOwnedChild() async throws {
        let directory = try Paths.ensureDirectory(Paths.home.appending(path: "test-run-tests/\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let interrupt = InterruptFlag()
        defer { interrupt.remove() }
        let pid = try Shell.spawnDetached(["/bin/sleep", "30"], log: directory.appending(path: "sleep.log"))
        let (status, cancelReason) = await TestCommands.wait(
            for: pid, timeout: .milliseconds(200), interrupt: interrupt, grace: .seconds(5))
        #expect(cancelReason == "timeout")
        #expect(status.map { $0 & 0x7f } == SIGINT)
    }

    @Test func checkReasonInterruptsTheOwnedChild() async throws {
        try await temporaryLog { log in
            let interrupt = InterruptFlag()
            defer { interrupt.remove() }
            let pid = try Shell.spawnDetached(["/bin/sleep", "30"], log: log)
            let (status, cancelReason) = await TestCommands.wait(
                for: pid, timeout: .seconds(30), interrupt: interrupt, grace: .seconds(5), check: { "passcode" })
            #expect(cancelReason == "passcode")
            #expect(status.map { $0 & 0x7f } == SIGINT)
        }
    }

    @Test func passcodeTimeoutIsFoundAcrossPartialWrites() async throws {
        try await temporaryLog { log in
            var watch = PasscodeWatch(log: log, target: target(.device))
            try Data("Testing started\nTest Suite 'All tests' started\nTimed out while enab".utf8).write(to: log)
            #expect(watch.check { _ in } == nil)
            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("ling automation mode\n".utf8))
            try handle.close()
            #expect(watch.check { _ in } == "passcode")
        }
    }

    @Test func passcodeHintPrintsOnceWhenUITestsStart() async throws {
        try await temporaryLog { log in
            var watch = PasscodeWatch(log: log, target: target(.device))
            var hints: [String] = []
            try Data("SuiteFixtureUITests-Runner[1:2] [Default] Running tests...\n".utf8).write(to: log)
            _ = watch.check { hints.append($0) }
            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("OtherUITests-Runner[3:4] [Default] Running tests...\n".utf8))
            try handle.close()
            _ = watch.check { hints.append($0) }
            #expect(hints == ["Unlock Test iPhone and enter its passcode to allow UI Automation (up to 60 s)."])
        }
    }

    @Test func passcodeTimeoutNeedsTheUser() {
        let summary = URL(filePath: "/jobs/test-1/summary.json")
        let error = TestCommands.userError(
            in: "Testing failed:\n\tTimed out while enabling automation mode.\n", status: "cancelled", target: target(.device),
            summary: summary)
        #expect(error?.code == .uiAutomationPasscode)
        #expect(error?.exitCode == 3)
        #expect(error?.detail == "Summary: /jobs/test-1/summary.json")
    }

    @Test func provisioningFailureNeedsTheUser() {
        let line =
            "/Users/dev/App.xcodeproj: error: No profiles for 'com.example.app' were found: Xcode couldn't find any "
            + "iOS App Development provisioning profiles matching 'com.example.app'."
        let error = TestCommands.userError(
            in: "Command line invocation:\n    xcodebuild test -allowProvisioningUpdates\n\(line)\n** TEST BUILD FAILED **\n",
            status: "failed", target: target(.device), summary: URL(filePath: "/jobs/test-1/summary.json"))
        #expect(error?.code == .signingProfileFailed)
        #expect(error?.detail == line)
    }

    @Test func missingDevelopmentTeamNeedsTheUser() {
        let line =
            "/Users/dev/App.xcodeproj: error: Signing for \"App\" requires a development team. Select a development team in "
            + "the Signing & Capabilities editor. (in target 'App' from project 'App')"
        let error = TestCommands.userError(
            in: "Command line invocation:\n    xcodebuild test\n\(line)\n** TEST BUILD FAILED **\n", status: "failed",
            target: target(.device), summary: URL(filePath: "/jobs/test-1/summary.json"))
        #expect(error?.code == .signingNoTeam)
        #expect(error?.exitCode == 3)
        #expect(error?.detail == line)
    }

    @Test func savedJobWhoseProcessExitedSaysItEnded() throws {
        let job = "test-\(UUID().uuidString)"
        let directory = try Paths.ensureDirectory(Paths.artifacts.appending(path: job))
        defer { try? FileManager.default.removeItem(at: directory) }
        let error = #expect(throws: DeviceLoopError.self) { try TestCommands.saved(job: job) }
        #expect(error?.message == "Test job \(job) ended without a summary.json because the process that ran it exited first.")
        #expect(error?.fix?.contains("\(directory.path)/result.xcresult") == true)
    }

    @Test func savedJobIsFoundInARunsArtifacts() throws {
        let job = "test-\(UUID().uuidString)"
        let run = Paths.runs.appending(path: "run-\(UUID().uuidString)")
        let directory = try Paths.ensureDirectory(RunStore(directory: run).artifacts.appending(path: job))
        defer { try? FileManager.default.removeItem(at: run) }
        let error = #expect(throws: DeviceLoopError.self) { try TestCommands.saved(job: job) }
        #expect(error?.message == "Test job \(job) ended without a summary.json because the process that ran it exited first.")
        #expect(error?.fix?.contains("\(directory.path)/result.xcresult") == true)
    }

    @Test func runningFlowMakesATestRunDeviceBusy() async throws {
        let udid = "TEST-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(at: Paths.session(for: udid)) }
        let simulator = Target(
            udid: udid, identifier: udid, name: "Test iPhone", kind: .simulator, deviceType: "iPhone", platform: "iOS",
            model: "fixture", productType: "fixture", osVersion: "27.0", connectionState: "connected", bootState: "booted"
        )
        try await SessionLock.withFlowLock("flow-20261108-131927-3f9a2c", on: simulator) {
            let error = await #expect(throws: DeviceLoopError.self) {
                _ = try await TestCommands.run(simulator, project: "App.xcodeproj", workspace: nil, scheme: "App", stopRunner: true)
            }
            #expect(error?.code == .deviceBusy)
            #expect(error?.message == "Flow flow-20261108-131927-3f9a2c is running on \(simulator.summary).")
        }
    }

    @Test func savedJobWithALiveMarkerIsStillRunning() throws {
        let job = "test-\(UUID().uuidString)"
        let udid = "TEST-\(UUID().uuidString)"
        let directory = try Paths.ensureDirectory(Paths.artifacts.appending(path: job))
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: Paths.session(for: udid))
        }
        try SuiteMarker(job: job, pid: getpid(), processIdentity: try #require(RunnerProcess.identity(of: getpid()))).write(for: udid)
        let error = #expect(throws: DeviceLoopError.self) { try TestCommands.saved(job: job) }
        #expect(error?.message.contains("has no summary.json yet") == true)
    }

    @Test(arguments: [("pass", "passed"), ("failure", "failed"), ("build-error", "failed"), ("build-only", "failed")])
    func statusComesFromTheBundle(scenario: String, status: String) async throws {
        #expect(TestCommands.status(of: try await recordedReport(scenario)) == status)
    }

    @Test func runTextListsTestsThatRan() async throws {
        let report = try await recordedReport("swift-testing")
        let lines = TestCommands.lines(report, listTests: true)
        #expect(lines.contains("PASS SuiteFixtureTests/swiftTestingPasses()"))
        #expect(lines.contains("PASS SuiteFixtureUITests/TapUITests/testTapCounts()"))
    }
}
