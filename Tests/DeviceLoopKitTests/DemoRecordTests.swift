//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct DemoRecordTests {
    static let script = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../scripts/demo/record.py").standardized

    /// `text` after record.py's `redact`, for one device named Test iPhone.
    func redact(_ text: String, team: String = "") async throws -> String {
        let devices = #"[{"name": "Test iPhone", "udid": "00008150-0011223344556677", "model": "iPhone 17 Pro"}]"#
        let result = try await Shell.run([
            "python3", "-I", "-c",
            "import json, runpy, sys\nprint(runpy.run_path(sys.argv[1])['redact'](sys.argv[2], json.loads(sys.argv[3]), sys.argv[4]), end='')",
            Self.script.path, text, devices, team,
        ])
        #expect(result.succeeded, "\(result.stderrString)")
        return result.stdoutString
    }

    @Test func redactReplacesDeviceNamesAndUDIDs() async throws {
        #expect(try await redact("Test iPhone\nudid: 00008150-0011223344556677") == "iPhone 17 Pro\nudid: <udid>")
    }

    @Test func redactHidesTheTeamAndUTCClockTimes() async throws {
        let text = "Launched com.example.appABCDE12345\nlaunchedAt 2026-11-09T21:51:47.162Z\nchanges-2026-11-09T215204.134Z.jsonl"
        #expect(
            try await redact(text, team: "ABCDE12345")
                == "Launched com.example.app<team>\nlaunchedAt 2026-11-09T<time>Z\nchanges-2026-11-09T<time>Z.jsonl")
    }
}
