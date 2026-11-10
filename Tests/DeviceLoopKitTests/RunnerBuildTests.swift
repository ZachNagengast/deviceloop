//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct RunnerBuildTests {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = Paths.home.appending(path: "cache-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ text: String, to path: String, in root: URL) throws {
        let file = root.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func key(
        _ root: URL, simulator: Bool = true, team: String? = nil, configuration: String = "Debug",
        toolchain: [String] = ["27A1", "/Xcode", "24A1", "Swift 6"]
    ) throws -> String {
        try RunnerBuild.cacheIdentity(project: root, simulator: simulator, team: team, configuration: configuration, toolchain: toolchain)
    }

    /// The runner target of a session xctestrun written next to the recorded simulator runner template in `root`.
    private func sessionConfig(in root: URL, _ write: (URL) throws -> URL) throws -> [String: Any] {
        let template = try #require(Bundle.module.url(forResource: "Resources/xctestrun/runner-simulator", withExtension: "xctestrun"))
        try FileManager.default.copyItem(at: template, to: root.appending(path: "DeviceLoopRunner.xctestrun"))
        let file = try write(root)
        let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        return try #require(plist["DeviceLoopRunner"] as? [String: Any])
    }

    @Test func serveXctestrunRunsOnlyTestServe() throws {
        try fixture { root in
            let config = try sessionConfig(in: root) { try RunnerBuild.writeServeXctestrun(from: $0, token: "test-only", bind: "::1") }
            #expect(config["OnlyTestIdentifiers"] as? [String] == ["DeviceLoopRunner/testServe"])
        }
    }

    @Test func measureXctestrunRunsOnlyItsTestWithTheScenario() throws {
        try fixture { root in
            let scenario = MeasureScenario(
                bundleID: "com.argmaxinc.deviceloop.host", iterations: 5, launchArguments: ["-UITestDelay", "2"])
            let config = try sessionConfig(in: root) {
                try RunnerBuild.writeMeasureXctestrun(from: $0, test: "testLaunch", scenario: scenario)
            }
            #expect(config["OnlyTestIdentifiers"] as? [String] == ["DeviceLoopMeasure/testLaunch"])
            let environment = try #require(config["TestingEnvironmentVariables"] as? [String: String])
            let json = try #require(environment[RunnerWire.Environment.scenario])
            #expect(try JSONDecoder().decode(MeasureScenario.self, from: Data(json.utf8)) == scenario)
            #expect(environment[RunnerWire.Environment.token] == nil)
            #expect(environment["XCODE_SCHEME_NAME"] == "DeviceLoopRunner")
        }
    }

    @Test func hostBundleIdentifierComesFromTheBuiltApp() throws {
        try fixture { root in
            let xctestrun: [String: Any] = [
                "__xctestrun_metadata__": ["FormatVersion": 1],
                "DeviceLoopRunner": ["UITargetAppPath": "__TESTROOT__/Debug-iphoneos/DeviceLoopHost.app"],
            ]
            try PropertyListSerialization.data(fromPropertyList: xctestrun, format: .xml, options: 0)
                .write(to: root.appending(path: "run-test.xctestrun"))
            let app = root.appending(path: "Debug-iphoneos/DeviceLoopHost.app")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": "com.argmaxinc.deviceloop.hostABCDE12345"], format: .binary, options: 0
            )
            .write(to: app.appending(path: "Info.plist"))

            #expect(
                RunnerBuild.hostBundleIdentifier(xctestrun: root.appending(path: "run-test.xctestrun"))
                    == "com.argmaxinc.deviceloop.hostABCDE12345")
            #expect(RunnerBuild.hostBundleIdentifier(xctestrun: root.appending(path: "missing.xctestrun")) == nil)
        }
    }

    private func decodedProfile(_ fields: [String: Any]) throws -> Data {
        var profile: [String: Any] = [
            "Name": "iOS Team Provisioning Profile: *", "TeamIdentifier": ["ABCDE12345"],
            "ExpirationDate": Date(timeIntervalSinceNow: 7 * 24 * 3600),
        ]
        profile.merge(fields) { _, new in new }
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    @Test func cachedBuildIsReusedOnlyForDevicesInItsProfile() throws {
        let profile = try decodedProfile(["ProvisionedDevices": ["00008130-578D60C5D3FFD610", "00008110-001A2C3E0A12801E"]])
        #expect(RunnerBuild.profileUsable(profile, udid: "00008110-001A2C3E0A12801E"))
        #expect(RunnerBuild.profileUsable(profile, udid: "00008110-001a2c3e0a12801e"))
        #expect(!RunnerBuild.profileUsable(profile, udid: "00008150-0011223344556677"))
        #expect(!RunnerBuild.profileUsable(Data("not a profile".utf8), udid: "00008110-001A2C3E0A12801E"))
    }

    @Test func profileProvisioningAllDevicesIsReusedForAnyDevice() throws {
        let profile = try decodedProfile(["ProvisionsAllDevices": true])
        #expect(RunnerBuild.profileUsable(profile, udid: "00008150-0011223344556677"))
    }

    @Test func profileIsUsableOnlyBeforeItExpires() throws {
        let expiration = try Date("2026-11-08T20:00:00Z", strategy: .iso8601)
        let profile = try decodedProfile(["ProvisionsAllDevices": true, "ExpirationDate": expiration])
        #expect(RunnerBuild.profileUsable(profile, udid: "00008150-0011223344556677", now: expiration.addingTimeInterval(-60)))
        #expect(!RunnerBuild.profileUsable(profile, udid: "00008150-0011223344556677", now: expiration))
        #expect(!RunnerBuild.profileUsable(profile, udid: "00008150-0011223344556677", now: expiration.addingTimeInterval(60)))
    }

    @Test(arguments: [true, false])
    func swiftPMConfigurationDirectoriesEndAt0755(existing: Bool) throws {
        try fixture { root in
            let shared = root.appending(path: "DeviceLoopRunner.xcodeproj/project.xcworkspace/xcshareddata")
            let directories = [shared, shared.appending(path: "swiftpm"), shared.appending(path: "swiftpm/configuration")]
            if existing {
                try FileManager.default.createDirectory(at: directories[2], withIntermediateDirectories: true)
                for directory in directories {
                    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
                }
            }
            RunnerBuild.createSwiftPMConfiguration(in: root)
            for directory in directories {
                let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
                #expect(permissions == 0o755, "\(directory.lastPathComponent)")
            }
        }
    }

    @Test func unregisteredDeviceBuildErrorsNameTheDevice() {
        let target = Target(
            udid: "00008150-0011223344556677", identifier: "6812A417-3B91-576A-A4EB-F81FED731A58", name: "Test iPhone",
            kind: .device, deviceType: "iPhone", platform: "iOS", model: "iPhone 15 Pro Max", productType: "iPhone16,2",
            osVersion: "27.0", connectionState: "connected"
        )
        for output in [
            "error: Communication with Apple failed: Your team has no devices from which to generate a provisioning profile.",
            "error: Provisioning profile \"iOS Team Provisioning Profile: *\" doesn't include the currently selected device "
                + "\"Test iPhone\" (identifier 00008150-0011223344556677).",
        ] {
            let result = ShellResult(status: 65, stdout: Data(output.utf8), stderr: Data())
            let error = RunnerBuild.buildError(result, target: target, team: "ABCDE12345")
            #expect(error.code == .signingProfileFailed)
            #expect(error.fix?.contains("Test iPhone (UDID 00008150-0011223344556677) to team ABCDE12345") == true)
        }
    }

    @Test func sourceProjectAndResourceChangesInvalidateCache() throws {
        try fixture { root in
            for path in [
                "UITests/Actions.swift", "DeviceLoopRunner.xcodeproj/project.pbxproj", "Host/Assets.xcassets/icon.png",
                "Shared/Protocol.swift",
            ] {
                try write("first", to: path, in: root)
                let before = try key(root)
                try write("second", to: path, in: root)
                #expect(try key(root) != before)
            }
        }
    }

    @Test func sourceRenameAndDeletionInvalidateCache() throws {
        try fixture { root in
            try write("source", to: "Host/App.swift", in: root)
            try write("project", to: "project.yml", in: root)
            let original = try key(root)
            try FileManager.default.moveItem(at: root.appending(path: "Host/App.swift"), to: root.appending(path: "Host/Renamed.swift"))
            let renamed = try key(root)
            #expect(renamed != original)
            try FileManager.default.removeItem(at: root.appending(path: "Host/Renamed.swift"))
            #expect(try key(root) != renamed)
        }
    }

    @Test func checkoutLocationCreationOrderAndModificationTimeDoNotChangeIdentity() throws {
        try fixture { root in
            let a = root.appending(path: "a")
            let b = root.appending(path: "b")
            try write("first", to: "Host/App.swift", in: a)
            try write("second", to: "Shared/Protocol.swift", in: a)
            try write("second", to: "Shared/Protocol.swift", in: b)
            try write("first", to: "Host/App.swift", in: b)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: b.appending(path: "Host/App.swift").path)
            #expect(try key(a) == key(b))
        }
    }

    @Test func localOutputsAndUserDataDoNotInvalidateCache() throws {
        try fixture { root in
            try write("source", to: "Host/App.swift", in: root)
            let original = try key(root)
            for path in [
                ".build/output", "build/output", "DerivedData/output", "DeviceLoopRunner.xcodeproj/xcuserdata/user.xcuserdatad/state",
                ".DS_Store",
            ] {
                try write("local", to: path, in: root)
            }
            #expect(try key(root) == original)
        }
    }

    @Test func buildConfigurationAndToolchainInvalidateCache() throws {
        try fixture { root in
            try write("source", to: "App.swift", in: root)
            let original = try key(root)
            #expect(try key(root, simulator: false) != original)
            #expect(try key(root, team: "TEAM") != original)
            #expect(try key(root, configuration: "Release") != original)
            for index in 0 ..< 4 {
                var identity = ["27A1", "/Xcode", "24A1", "Swift 6"]
                identity[index] += "-changed"
                #expect(try key(root, toolchain: identity) != original)
            }
        }
    }

    @Test func templateSelectionIsSortedAndExcludesSessionFilesAndDirectories() throws {
        try fixture { root in
            try write("session", to: "run-device.xctestrun", in: root)
            #expect(RunnerBuild.existingXctestrun(in: root) == nil)
            try FileManager.default.createDirectory(at: root.appending(path: "0-directory.xctestrun"), withIntermediateDirectories: true)
            try write("template", to: "B.xctestrun", in: root)
            try write("template", to: "A.xctestrun", in: root)
            #expect(RunnerBuild.existingXctestrun(in: root)?.lastPathComponent == "A.xctestrun")
        }
    }

    @Test func partialBuildTemplateWithoutCompletionIsNotReusable() throws {
        try fixture { root in
            try write("partial template", to: "Build/Products/DeviceLoopRunner.xctestrun", in: root)
            #expect(RunnerBuild.completedProducts(in: root, key: "expected") == nil)
        }
    }

    @Test func completedBuildRequiresTheExactCacheIdentity() throws {
        try fixture { root in
            try write("template", to: "Build/Products/DeviceLoopRunner.xctestrun", in: root)
            try RunnerBuild.publishCompletion(in: root, key: "original")
            #expect(RunnerBuild.completedProducts(in: root, key: "changed") == nil)
            #expect(RunnerBuild.completedProducts(in: root, key: "original") == root.appending(path: "Build/Products"))
        }
    }

    @Test func completionWithoutARegularBuildTemplateIsNotReusable() throws {
        try fixture { root in
            let products = root.appending(path: "Build/Products")
            let template = products.appending(path: "DeviceLoopRunner.xctestrun")
            try write("template", to: "Build/Products/DeviceLoopRunner.xctestrun", in: root)
            try RunnerBuild.publishCompletion(in: root, key: "expected")
            try FileManager.default.removeItem(at: template)
            #expect(RunnerBuild.completedProducts(in: root, key: "expected") == nil)
            try write("session", to: "Build/Products/run-device.xctestrun", in: root)
            try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
            #expect(RunnerBuild.completedProducts(in: root, key: "expected") == nil)
        }
    }

    @Test func firstBuildGoesToTheKeyFolder() throws {
        try fixture { root in
            let key = "device-\(String(repeating: "a", count: 64))"
            try write("partial template", to: "\(key)/Build/Products/DeviceLoopRunner.xctestrun", in: root)
            let folders = RunnerBuild.buildFolders(for: key, in: root)
            #expect(folders.published == nil)
            #expect(folders.next == root.appending(path: key))
        }
    }

    @Test func rebuildGoesToANewFolderAndLeavesTheCompletedBuildUntouched() throws {
        try fixture { root in
            let key = "device-\(String(repeating: "a", count: 64))"
            let first = root.appending(path: key)
            try write("first", to: "\(key)/Build/Products/DeviceLoopRunner.xctestrun", in: root)
            try RunnerBuild.publishCompletion(in: first, key: key)

            let rebuild = RunnerBuild.buildFolders(for: key, in: root)
            #expect(rebuild.published == first.appending(path: "Build/Products"))
            #expect(rebuild.next != first)
            #expect(rebuild.next.deletingLastPathComponent().path == root.path)
            #expect(rebuild.next.lastPathComponent.hasPrefix("device-"))
            #expect(rebuild.next.lastPathComponent.count == key.count)

            try write("second", to: "\(rebuild.next.lastPathComponent)/Build/Products/DeviceLoopRunner.xctestrun", in: root)
            try RunnerBuild.publishCompletion(in: rebuild.next, key: key)
            let after = RunnerBuild.buildFolders(for: key, in: root)
            #expect(after.published == rebuild.next.appending(path: "Build/Products"))
            #expect(![first, rebuild.next].contains(after.next))
            #expect(try String(contentsOf: first.appending(path: "Build/Products/DeviceLoopRunner.xctestrun"), encoding: .utf8) == "first")
            #expect(RunnerBuild.completedProducts(in: first, key: key) != nil)
        }
    }

    @Test func completionCannotBePublishedForMissingBuildProducts() throws {
        try fixture { root in
            #expect(throws: DeviceLoopError.self) { try RunnerBuild.publishCompletion(in: root, key: "expected") }
            #expect(RunnerBuild.completedProducts(in: root, key: "expected") == nil)
        }
    }

    @Test func provisioningErrorIsTheLastProfileErrorLine() {
        let log = """
            /Users/dev/deviceloop/Examples/SuiteFixture/SuiteFixture.xcodeproj: error: No signing certificate "iOS Development" found: No "iOS Development" signing certificate matching team ID "ABCDE12345" with a private key was found. (in target 'SuiteFixtureTests' from project 'SuiteFixture')
            /Users/dev/deviceloop/Examples/SuiteFixture/SuiteFixture.xcodeproj: error: No profiles for 'com.argmaxinc.deviceloop.suitefixtureABCDE12345' were found: Xcode couldn't find any iOS App Development provisioning profiles matching 'com.argmaxinc.deviceloop.suitefixtureABCDE12345'. (in target 'SuiteFixture' from project 'SuiteFixture')
            ** TEST BUILD FAILED **
            """
        let line = RunnerBuild.provisioningError(in: log)
        #expect(line?.contains("error: No profiles for 'com.argmaxinc.deviceloop.suitefixtureABCDE12345'") == true)
    }

    @Test func provisioningTextOutsideErrorLinesIsNotAProvisioningError() {
        let log = """
            Command line invocation:
                /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build-for-testing -allowProvisioningUpdates
            GatherProvisioningInputs
                Provisioning Profile: "iOS Team Provisioning Profile: *"
            /Users/dev/deviceloop/Runner/UITests/Router.swift:12:5: error: cannot find 'route' in scope
            ** TEST BUILD FAILED **
            """
        #expect(RunnerBuild.provisioningError(in: log) == nil)
    }

    @Test func failingTestAboutProfilesIsNotAProvisioningError() {
        let log = """
            /Users/dev/AppTests/ProvisioningTests.swift:8: error: -[AppTests.ProvisioningTests testLoad] : failed - No profiles loaded
            /Users/dev/App/App/Enrollment.swift:12:5: error: cannot find 'ProvisioningClient' in scope
            ** TEST FAILED **
            """
        #expect(RunnerBuild.provisioningError(in: log) == nil)
    }

    @Test func unknownXcodeVersionIsRejected() throws {
        #expect(throws: DeviceLoopError.self) { try RunnerBuild.xcodeBuildVersion("") }
        #expect(throws: DeviceLoopError.self) { try RunnerBuild.xcodeBuildVersion("Xcode 27\nBuild version ") }
        #expect(throws: DeviceLoopError.self) { try RunnerBuild.xcodeBuildVersion("Build version 27A1") }
        #expect(try RunnerBuild.xcodeBuildVersion("Xcode 27.0\nBuild version 27A1\n") == "27A1")
    }
}
