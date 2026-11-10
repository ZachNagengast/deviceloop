//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct SmokeCompareScriptTests {
    static let script = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../scripts/smoke-compare.py").standardized

    /// Prints the result each command would report for the seeded fixture variants. run compare fails when given --device.
    static let fakeDeviceLoop = """
        #!/bin/sh
        case "$*" in
        "run compare "*--device*) echo '{"error": {"code": "bad_arguments"}}'; exit 2 ;;
        "run compare smoke-compare-a smoke-compare-a-again "*) cat "$(dirname "$0")/control.json" ;;
        "run compare smoke-compare-a smoke-compare-b "*) cat "$(dirname "$0")/seeded.json" ;;
        "run start "*) echo "{\\"id\\": \\"$4\\"}" ;;
        "runner start"*) echo '{"hostApp": "com.example.deviceloop.host"}' ;;
        "ui tree"*) echo '{"app": "com.example.deviceloop.host", "root": {"children": [{"type": "navigationBar", "frame": [0, 62, 402, 54]}]}}' ;;
        "screenshot"*) echo '{"pointWidth": 402}' ;;
        *) echo '{}' ;;
        esac

        """

    @Test func compareSmokePassesAgainstSeededVariants() async throws {
        let directory = Paths.home.appending(path: "smoke-script-tests/\(UUID().uuidString)")
        let runs = directory.appending(path: "runs")
        let files = ["steps/0003.json", "steps/0006.json"]
        for run in ["smoke-compare-a", "smoke-compare-b"] {
            try Paths.ensureDirectory(runs.appending(path: "\(run)/steps"))
            for file in files { try Data().write(to: runs.appending(path: "\(run)/\(file)")) }
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appending(path: "deviceloop")
        try Self.fakeDeviceLoop.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        func sides(_ file: String) -> [String: Any] {
            ["baseline": ["seq": 3, "files": [file]], "candidate": ["seq": 3, "files": [file]]]
        }
        let treeStep = sides(files[0]).merging([
            "index": 2, "command": "ui tree",
            "tree": [
                "changed": [
                    ["property": "frame", "element": ["id": "fixture.text.submit"], "delta": [40, 0, 0, 0]],
                    [
                        "property": "label", "element": ["id": "fixture.navigation.open"], "baseline": "Open detail",
                        "candidate": "Show detail",
                    ],
                ]
            ],
        ]) { $1 }
        let videoStep = sides(files[1]).merging([
            "index": 5, "command": "video capture",
            "timing": [["metric": "animation", "status": "changed", "baselineMs": 200, "candidateMs": 400]],
        ]) { $1 }
        let comparisons: [String: [String: Any]] = [
            "control": ["verdict": "same", "steps": []],
            "seeded": [
                "verdict": "different", "baseline": ["id": "smoke-compare-a"], "candidate": ["id": "smoke-compare-b"],
                "steps": [treeStep, videoStep],
            ],
        ]
        for (name, comparison) in comparisons {
            let path = runs.appending(path: "comparisons/\(name)").path
            let output = comparison.merging(["id": name, "path": path, "report": path + "/comparison.html"]) { $1 }
            try JSONSerialization.data(withJSONObject: output).write(to: directory.appending(path: "\(name).json"))
        }
        let artifacts = directory.appending(path: "artifacts")

        let result = try await Shell.run(
            ["python3", Self.script.path, "--binary", binary.path, "--device", UUID().uuidString, "--artifacts", artifacts.path],
            timeout: .seconds(60))

        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: artifacts.appending(path: "report.json"))) as? [String: Any]
        #expect(result.status == 0, "\(result.stderrString)")
        #expect(report?["testOutcome"] as? String == "passed", "\(report?["error"] ?? "")")
        #expect((report?["comparisons"] as? [String: Any])?.keys.sorted() == ["control", "seeded"])
    }
}
