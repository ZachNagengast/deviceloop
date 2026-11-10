//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct SessionCredentialTests {
    private func fixture(_ body: (URL, URL, URL) throws -> Void) throws {
        let root = Paths.home.appending(path: "credential-tests/\(UUID().uuidString)")
        let products = root.appending(path: "sim-\(String(repeating: "a", count: 64))/Build/Products")
        try Paths.ensureDirectory(products)
        defer { try? FileManager.default.removeItem(at: root) }
        let template = products.appending(path: "DeviceLoopRunner.xctestrun")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["DeviceLoopRunner": ["TestBundlePath": "__TESTROOT__/runner.xctest"]], format: .xml, options: 0)
        try data.write(to: template)
        try body(root, products, template)
    }

    private func session(path: URL) -> SessionFile {
        SessionFile(udid: "test", host: "::1", port: 1234, token: "test-only", pid: 0, xctestrunPath: path.path)
    }

    @Test func sessionConfigurationsAreUniquePrivateAndLeaveTheTemplateUntouched() throws {
        try fixture { _, products, template in
            let original = try Data(contentsOf: template)
            let first = try RunnerBuild.writeServeXctestrun(from: products, token: "first-test-token", bind: "::1")
            let second = try RunnerBuild.writeServeXctestrun(from: products, token: "second-test-token", bind: "::1")
            #expect(first != second)
            #expect(first.deletingLastPathComponent().path == products.path)
            #expect(try Data(contentsOf: template) == original)
            #expect(RunnerBuild.existingXctestrun(in: products) == template)
            for (file, token) in [(first, "first-test-token"), (second, "second-test-token")] {
                let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
                #expect(permissions?.intValue == 0o600)
                let plist = try #require(
                    PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
                let config = try #require(plist["DeviceLoopRunner"] as? [String: Any])
                let environment = try #require(config["TestingEnvironmentVariables"] as? [String: String])
                #expect(environment[RunnerWire.Environment.token] == token)
                #expect(config["TestBundlePath"] as? String == "__TESTROOT__/runner.xctest")
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: products.path).count == 3)
        }
    }

    @Test func recordedCredentialsAreRemovedWithoutDeletingTheTemplate() throws {
        try fixture { root, products, template in
            let file = try RunnerBuild.writeServeXctestrun(from: products, token: "test-only", bind: "::1")
            #expect(session(path: file).removeCredentials(in: root))
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(!session(path: template).removeCredentials(in: root))
            #expect(FileManager.default.fileExists(atPath: template.path))
        }
    }

    @Test func cleanupRejectsFilesOutsideTheCacheOrWithAnUnexpectedName() throws {
        try fixture { root, products, _ in
            let outside = root.appending(path: "run-\(UUID().uuidString).xctestrun")
            let unexpected = products.appending(path: "run-user-file.xctestrun")
            for file in [outside, unexpected] {
                try Data("retain".utf8).write(to: file)
                #expect(!session(path: file).removeCredentials(in: root))
                #expect(FileManager.default.fileExists(atPath: file.path))
            }
        }
    }

    @Test func cleanupDoesNotFollowARecordedFileSymlink() throws {
        try fixture { root, products, template in
            let link = products.appending(path: "run-\(UUID().uuidString).xctestrun")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: template)
            #expect(!session(path: link).removeCredentials(in: root))
            #expect(FileManager.default.fileExists(atPath: template.path))
        }
    }

    @Test func cleanupDoesNotFollowASymlinkedCacheDirectory() throws {
        try fixture { root, products, _ in
            let external = root.appending(path: "external-products")
            try Paths.ensureDirectory(external)
            let file = external.appending(path: "run-\(UUID().uuidString).xctestrun")
            try Data("retain".utf8).write(to: file)
            try FileManager.default.removeItem(at: products)
            try FileManager.default.createSymbolicLink(at: products, withDestinationURL: external)
            let recorded = products.appending(path: file.lastPathComponent)
            #expect(!session(path: recorded).removeCredentials(in: root))
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func sessionsWrittenBeforeCredentialTrackingStillDecode() throws {
        let legacy = Data(#"{"udid":"test","host":"::1","port":1234,"token":"test-only","pid":0}"#.utf8)
        let decoded = try JSONDecoder().decode(SessionFile.self, from: legacy)
        #expect(decoded.xctestrunPath == nil)
        #expect(!decoded.removeCredentials())
    }
}
