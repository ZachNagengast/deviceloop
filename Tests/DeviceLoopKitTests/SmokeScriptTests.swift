//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct SmokeScriptTests {
    static let scripts = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../scripts").standardized

    /// Prints the result each command would report when the fixture behaves as the Siri smoke test expects.
    static let fakeDeviceLoop = """
        #!/bin/sh
        case "$*" in
        "runner start"*) echo '{"hostApp": "com.example.deviceloop.host"}' ;;
        "siri test "*/duplicate.json*) echo '{"backend": "entity", "cleanup": "ran", "phrases": [{"outcome": "duplicate"}]}'; exit 8 ;;
        "siri test "*/wrong-title.json*) echo '{"backend": "entity", "cleanup": "ran", "phrases": [{"outcome": "wrong_entity"}]}'; exit 8 ;;
        "siri test "*) echo '{"backend": "entity", "cleanup": "ran", "phrases": [{"outcome": "verified"}]}' ;;
        "ui find"*) echo '{"matches": []}' ;;
        *) echo '{}' ;;
        esac

        """

    @Test func siriSmokePassesAgainstAnExpectedFixture() async throws {
        let directory = Paths.home.appending(path: "smoke-script-tests/\(UUID().uuidString)")
        try Paths.ensureDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appending(path: "deviceloop")
        try Self.fakeDeviceLoop.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let artifacts = directory.appending(path: "artifacts")

        let result = try await Shell.run(
            [
                "python3", Self.scripts.appending(path: "smoke-siri.py").path, "--binary", binary.path,
                "--device", UUID().uuidString, "--artifacts", artifacts.path, "--phrase", "Add Milk", "--title", "Milk",
            ],
            timeout: .seconds(60))

        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: artifacts.appending(path: "report.json"))) as? [String: Any]
        #expect(result.status == 0, "\(result.stderrString)")
        #expect(report?["testOutcome"] as? String == "passed", "\(report?["error"] ?? "")")
    }
}
