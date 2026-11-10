//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import CryptoKit
import DeviceLoopProtocol
import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct RunComparisonTests {
    static let iPhone = RunProvenance(
        deviceloop: "0.1.0", macOS: "27.2.0",
        device: .init(udid: "unit-test", model: "iPhone 17 Pro", productType: "iPhone18,1", osVersion: "27.0", osBuild: "24A434"),
        screen: .init(pointWidth: 402, pointHeight: 874, scale: 3, orientation: "portrait"),
        app: .init(bundleID: "com.example.app", version: "1.2", build: "34"),
        source: .init(revision: "0123456789abcdef0123456789abcdef01234567", dirty: false))

    static let fourSteps: [(command: String, args: JSONValue, code: DeviceLoopError.Code?)] = [
        ("screenshot", [], nil), ("ui tree", [], nil), ("ui tap", ["id=go"], nil), ("screenshot", [], nil),
    ]

    /// Runs `body` with a new temporary runs folder, then removes it.
    private func runsFolder(_ body: (URL) async throws -> Void) async throws {
        let runs = FileManager.default.temporaryDirectory.appending(
            path: "deviceloop-compare-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: runs) }
        try await body(runs)
    }

    /// A finished run `id` in `runs` with one command per step, each with a saved result and a screenshot when it is ok.
    @discardableResult
    private func makeRun(
        _ id: String, in runs: URL, provenance: RunProvenance? = RunComparisonTests.iPhone,
        steps: [(command: String, args: JSONValue, code: DeviceLoopError.Code?)] = RunComparisonTests.fourSteps
    ) async throws -> RunStore {
        let run = try RunStore.named(id, in: runs)
        try run.write(RunManifest(id: id, status: .running, createdAt: RunStore.timestamp(), hostStart: hostNow(), provenance: provenance))
        for step in steps {
            let started = try await run.append(RunEvent(kind: "started", command: step.command, args: step.args)).get()
            if let code = step.code {
                let error = DeviceLoopError(code, "\(step.command) failed.")
                _ = try await run.append(
                    RunEvent(kind: "finished", command: step.command, started: started.seq, outcome: .error, error: error)
                ).get()
            } else {
                try Paths.writePrivate(Data("{}".utf8), to: run.directory.appending(path: "results/\(started.seq).json"))
                try Paths.writePrivate(Data("png".utf8), to: run.artifacts.appending(path: "\(started.seq).png"))
                _ = try await run.append(
                    RunEvent(
                        kind: "finished", command: step.command, started: started.seq, outcome: .ok,
                        artifacts: ["artifacts/\(started.seq).png"])
                ).get()
            }
        }
        try await run.finalize()
        return run
    }

    @Test func identicalRunsAreSame() async throws {
        try await runsFolder { runs in
            try await makeRun("run-a", in: runs)
            try await makeRun("run-b", in: runs)
            let comparison = try RunComparison.write(baseline: "run-a", candidate: "run-b", in: runs).comparison
            #expect(comparison.verdict == .same)
            #expect(comparison.reasons.isEmpty)
            #expect(comparison.steps.map(\.change) == [.same, .same, .same, .same])
        }
    }

    @Test func candidateFailingStep3IsRegressedWithBothLinks() async throws {
        try await runsFolder { runs in
            try await makeRun("run-a", in: runs)
            var steps = Self.fourSteps
            steps[2].code = .elementNotFound
            try await makeRun("run-b", in: runs, steps: steps)
            let (comparison, directory) = try RunComparison.write(baseline: "run-a", candidate: "run-b", in: runs)
            #expect(comparison.verdict == .different)
            let step = try #require(comparison.steps.first { $0.change != .same })
            #expect(step.index == 3)
            #expect(step.change == .regressed)
            #expect(step.baseline == .init(seq: 5, args: ["id=go"], outcome: "ok", files: ["results/5.json", "artifacts/5.png"]))
            #expect(step.candidate == .init(seq: 5, args: ["id=go"], outcome: "element_not_found", files: []))
            let html = try String(contentsOf: directory.appending(path: "comparison.html"), encoding: .utf8)
            #expect(html.contains("<a href=\"../../run-a/results/5.json\">5.json</a>"))
            #expect(html.contains("event 5 id=go: element_not_found"))
            for link in html.matches(of: /(?:src|href)="([^"]*)"/).map({ String($0.1) }) {
                #expect(FileManager.default.fileExists(atPath: directory.appending(path: link).path))
            }
        }
    }

    @Test(
        arguments: [
            (nil, nil, RunComparison.Change.same), (nil, .elementNotFound, .regressed), (.elementNotFound, nil, .fixed),
            (.elementNotFound, .timeout, .changed),
        ] as [(DeviceLoopError.Code?, DeviceLoopError.Code?, RunComparison.Change)])
    func stepChangeFollowsBothOutcomes(baseline: DeviceLoopError.Code?, candidate: DeviceLoopError.Code?, change: RunComparison.Change)
        async throws
    {
        try await runsFolder { runs in
            try await makeRun("run-a", in: runs, steps: [("ui tap", ["id=go"], baseline)])
            try await makeRun("run-b", in: runs, steps: [("ui tap", ["id=go"], candidate)])
            #expect(try RunComparison.write(baseline: "run-a", candidate: "run-b", in: runs).comparison.steps.map(\.change) == [change])
        }
    }

    @Test func differentProductTypeIsInconclusive() async throws {
        try await runsFolder { runs in
            var other = Self.iPhone
            other.device.productType = "iPhone17,1"
            try await makeRun("run-a", in: runs)
            try await makeRun("run-b", in: runs, provenance: other)
            let comparison = try RunComparison.write(baseline: "run-a", candidate: "run-b", in: runs).comparison
            #expect(comparison.verdict == .inconclusive)
            #expect(comparison.reasons == ["productType differs: iPhone18,1 vs iPhone17,1."])
        }
    }

    @Test func differentCommandListsAreInconclusive() async throws {
        try await runsFolder { runs in
            try await makeRun("run-a", in: runs)
            var steps = Self.fourSteps
            steps[1].command = "ui find"
            try await makeRun("run-b", in: runs, steps: steps)
            let comparison = try RunComparison.write(baseline: "run-a", candidate: "run-b", in: runs).comparison
            #expect(comparison.verdict == .inconclusive)
            #expect(comparison.reasons == ["Command sequences differ at step 2: ui tree vs ui find."])
            #expect(comparison.steps.isEmpty)
        }
    }

    @Test func compareLeavesEveryBaselineFileUnchanged() async throws {
        try await runsFolder { runs in
            let baseline = try await makeRun("run-a", in: runs)
            try RunReport.write(baseline)
            try await makeRun("run-b", in: runs)
            func hashes() throws -> [String: String] {
                var hashes: [String: String] = [:]
                for path in try FileManager.default.subpathsOfDirectory(atPath: baseline.directory.path) {
                    let url = baseline.directory.appending(path: path)
                    guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                    hashes[path] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                }
                return hashes
            }
            let before = try hashes()
            let directory = try RunComparison.write(baseline: "run-a", candidate: "run-b", in: runs).directory
            #expect(try hashes() == before)
            #expect(directory.deletingLastPathComponent().path == runs.appending(path: "comparisons").path)
        }
    }

    @Test func argumentDifferencesLeaveOutTheDevice() async throws {
        try await runsFolder { runs in
            try await makeRun("run-a", in: runs, steps: [("ui tap", ["id=go", "--device", "A"], nil), ("ui tap", ["id=go"], nil)])
            try await makeRun("run-b", in: runs, steps: [("ui tap", ["id=go", "-d", "B"], nil), ("ui tap", ["id=stop"], nil)])
            let comparison = try RunComparison.write(baseline: "run-a", candidate: "run-b", in: runs).comparison
            #expect(comparison.steps.map(\.argumentsDiffer) == [false, true])
            #expect(comparison.verdict == .same)
        }
    }

    @Test func jsonFlagIsNotAnArgumentDifference() async throws {
        try await runsFolder { runs in
            try await makeRun("run-a", in: runs, steps: [("ui tap", ["@e5", "--json"], nil)])
            try await makeRun("run-b", in: runs, steps: [("ui tap", ["@e5"], nil)])
            #expect(
                try RunComparison.write(baseline: "run-a", candidate: "run-b", in: runs).comparison.steps.map(\.argumentsDiffer) == [false])
        }
    }

    @Test func refArgumentsAreFragile() async throws {
        try await runsFolder { runs in
            try await makeRun("run-a", in: runs, steps: [("ui tap", ["@e5"], nil), ("ui do", ["tap id=go"], nil)])
            try await makeRun("run-b", in: runs, steps: [("ui tap", ["@e5"], nil), ("ui do", ["tap @e12"], nil)])
            #expect(
                try RunComparison.write(baseline: "run-a", candidate: "run-b", in: runs).comparison.steps.map(\.fragile) == [true, true])
        }
    }

    @Test func dirtySourceIsWarnedAndShownPerSide() async throws {
        try await runsFolder { runs in
            var dirty = Self.iPhone
            dirty.source?.dirty = true
            dirty.app?.build = "35"
            try await makeRun("run-a", in: runs)
            try await makeRun("run-b", in: runs, provenance: dirty)
            let comparison = try RunComparison.write(baseline: "run-a", candidate: "run-b", in: runs).comparison
            #expect(comparison.warnings == ["candidate source 0123456789abcdef0123456789abcdef01234567 has uncommitted changes."])
            let fields = Dictionary(uniqueKeysWithValues: comparison.fields.map { ($0.name, [$0.baseline, $0.candidate]) })
            #expect(fields["appVersion"] == ["1.2", "1.2"])
            #expect(fields["appBuild"] == ["34", "35"])
            #expect(fields["source"]?[1] == "0123456789abcdef0123456789abcdef01234567 with changes")
            #expect(comparison.verdict == .same)
        }
    }

    @Test func deviceLocaleIsUnknown() async throws {
        try await runsFolder { runs in
            try await makeRun("run-a", in: runs)
            try await makeRun("run-b", in: runs)
            let comparison = try RunComparison.write(baseline: "run-a", candidate: "run-b", in: runs).comparison
            let locale = try #require(comparison.fields.first { $0.name == "locale" })
            #expect([locale.baseline, locale.candidate] == ["unknown", "unknown"])
            #expect(!locale.gate)
        }
    }

    /// Replaces the `ui tree` result of step 2 in `run` with `tree`.
    private func saveTree(_ tree: TreeResult, in run: RunStore) throws {
        try JSONValue(encoding: tree).data(pretty: true).write(to: run.directory.appending(path: "results/3.json"))
    }

    @Test func movedElementInSavedTreesMakesTheComparisonDifferent() async throws {
        try await runsFolder { runs in
            try saveTree(TreeDiffTests.fixture(), in: try await makeRun("run-a", in: runs))
            let moved = TreeDiffTests.fixture { $0[TreeDiffTests.index(of: "fixture.counter.increment", in: $0)].frame[0] = 56 }
            try saveTree(moved, in: try await makeRun("run-b", in: runs))
            let result = try RunCommands.compare("run-a", "run-b", in: runs)
            #expect(result.json["verdict"] == "different")
            #expect(result.text.contains(", 0 changed, 1 tree changed, 0 screenshots changed, 0 timings changed\n"))
            #expect(
                result.text.contains(
                    "step 2 ui tree: same, tree changed, baseline event 3 ok, candidate event 3 ok\n"
                        + "  frame of button \"Increment\" id=fixture.counter.increment: [16,181,100.7,34.3] to [56,181,100.7,34.3], "
                        + "delta 40,0,0,0\n"))
        }
    }

    @Test func ignoredIDKeepsAChangedTreeSame() async throws {
        try await runsFolder { runs in
            try saveTree(TreeDiffTests.fixture(), in: try await makeRun("run-a", in: runs))
            let counted = TreeDiffTests.fixture { $0[TreeDiffTests.index(of: "fixture.counter.value", in: $0)].label = "Count: 1" }
            try saveTree(counted, in: try await makeRun("run-b", in: runs))
            let result = try RunCommands.compare("run-a", "run-b", ignore: ["id=fixture.counter.value"], in: runs)
            #expect(result.json["verdict"] == "same")
            #expect(result.json["ignoredIDs"] == ["fixture.counter.value"])
        }
    }

    @Test(arguments: ["fixture.counter.value", "id="])
    func ignoreWithoutIDIsRejected(value: String) async throws {
        try await runsFolder { runs in
            try await makeRun("run-a", in: runs)
            try await makeRun("run-b", in: runs)
            let error = #expect(throws: DeviceLoopError.self) { try RunCommands.compare("run-a", "run-b", ignore: [value], in: runs) }
            #expect(error?.code == .badArguments)
        }
    }

    /// Saves a screenshot of 120 by `height` pixels with white `blocks` as step 1 of `run`, with a result at point scale 2.
    private func saveScreenshot(in run: RunStore, height: Int = 80, blocks: [[Int]] = []) throws {
        try ImageDiffTests.png("1.png", in: run.artifacts, height: height, blocks: blocks)
        try Data(#"{"pointScale":2}"#.utf8).write(to: run.directory.appending(path: "results/1.json"))
    }

    @Test func changedScreenshotIsDifferentWithItsDiffImageOnlyInTheComparisonFolder() async throws {
        try await runsFolder { runs in
            try saveScreenshot(in: try await makeRun("run-a", in: runs))
            try saveScreenshot(in: try await makeRun("run-b", in: runs), blocks: [[40, 20, 10, 10]])
            let result = try RunCommands.compare("run-a", "run-b", in: runs)
            let directory = try #require(result.json["path"]?.string)
            #expect(result.json["verdict"] == "different")
            #expect(
                result.text.contains(
                    "step 1 screenshot: same, screenshot changed, baseline event 1 ok, candidate event 1 ok\n"
                        + "  screenshot changed: 1.042% of unmasked pixels, 100 of 9600, in [20,10,5,5]\n"
                        + "  diff \(directory)/step-1-diff.png\n"))
            let diffs = try FileManager.default.subpathsOfDirectory(atPath: runs.path).filter { $0.hasSuffix("diff.png") }
            #expect(diffs.map { runs.appending(path: $0).path } == ["\(directory)/step-1-diff.png"])
            let html = try String(contentsOf: URL(filePath: directory).appending(path: "comparison.html"), encoding: .utf8)
            #expect(html.contains("<img src=\"./step-1-diff.png\""))
        }
    }

    @Test func screenshotChangeInsideAMaskIsSame() async throws {
        try await runsFolder { runs in
            try saveScreenshot(in: try await makeRun("run-a", in: runs))
            try saveScreenshot(in: try await makeRun("run-b", in: runs), blocks: [[40, 20, 10, 10]])
            let result = try RunCommands.compare("run-a", "run-b", mask: ["18,8,9,9"], in: runs)
            #expect(result.json["verdict"] == "same")
            #expect(result.json["masks"] == [[18, 8, 9, 9]])
        }
    }

    @Test func screenshotsOfDifferentSizesAreInconclusive() async throws {
        try await runsFolder { runs in
            try saveScreenshot(in: try await makeRun("run-a", in: runs))
            try saveScreenshot(in: try await makeRun("run-b", in: runs), height: 100)
            let (comparison, directory) = try RunComparison.write(baseline: "run-a", candidate: "run-b", in: runs)
            #expect(comparison.verdict == .inconclusive)
            #expect(comparison.reasons == ["step 1: screenshots not compared: the screenshots differ in size, 120x80 px vs 120x100 px."])
            let html = try String(contentsOf: directory.appending(path: "comparison.html"), encoding: .utf8)
            #expect(html.contains("<span class=\"pill warn\">same, screenshot inconclusive</span></h3><ul>"))
        }
    }

    @Test(arguments: ["1,2,3", "1,2,3,x", "1,2,0,4", "1,,3,4"])
    func maskWithoutFourNumbersAndAnAreaIsRejected(value: String) async throws {
        try await runsFolder { runs in
            try await makeRun("run-a", in: runs)
            try await makeRun("run-b", in: runs)
            let error = #expect(throws: DeviceLoopError.self) { try RunCommands.compare("run-a", "run-b", mask: [value], in: runs) }
            #expect(error?.code == .badArguments)
        }
    }

    /// Two runs of one `video capture`, with the analysis of a synthetic recording of a box that moves for the given number
    /// of frames, still before and after.
    private func captureRuns(moving baselineFrames: Int, _ candidateFrames: Int, in runs: URL) async throws {
        for (id, frames) in [("run-a", baselineFrames), ("run-b", candidateFrames)] {
            let run = try await makeRun(id, in: runs, steps: [("video capture", ["--do", "tap id=go"], nil)])
            let video = try await SyntheticVideo.write(boxAt: (0 ..< 90).map { 40 + 4 * min(max(0, $0 - 20), frames) })
            defer { try? FileManager.default.removeItem(at: video) }
            var options = VideoAnalyzer.Options()
            options.actionAt = 0.25
            options.endAt = 1.5
            let report = try await VideoAnalyzer.analyze(video, options: options).report
            try JSONValue(encoding: report).data(pretty: true).write(to: run.directory.appending(path: "results/1.json"))
        }
    }

    @Test func animationTwiceAsLongIsChangedButNotRegressed() async throws {
        try await runsFolder { runs in
            try await captureRuns(moving: 19, 37, in: runs)
            let result = try RunCommands.compare("run-a", "run-b", in: runs)
            #expect(result.json["verdict"] == "different")
            #expect(
                result.text.contains(
                    "step 1 video capture --do tap id=go: same, timing changed, baseline event 1 ok, candidate event 1 ok\n"))
            #expect(
                result.text.contains(
                    "  animation 300 ms vs 600 ms, delta +300 ms, floor 50 ms: changed "
                        + "(visual estimate, single trial, capture not calibrated)\n"))
        }
    }

    @Test func animationOneFrameLongerIsWithinTheDetectionFloor() async throws {
        try await runsFolder { runs in
            try await captureRuns(moving: 19, 20, in: runs)
            let comparison = try RunComparison.write(baseline: "run-a", candidate: "run-b", in: runs).comparison
            #expect(comparison.verdict == .same)
            let timing = try #require(comparison.steps.first?.timing)
            #expect(
                timing.first { $0.metric == "animation" }?.line
                    == "animation 300 ms vs 316.7 ms, delta +16.7 ms, floor 50 ms: within detection floor "
                    + "(visual estimate, single trial, capture not calibrated)")
            #expect(timing.map(\.metric) == ["latency", "animation", "last change", "visual gaps"])
            #expect(timing.allSatisfy { $0.line.hasSuffix("(visual estimate, single trial, capture not calibrated)") })
        }
    }

    @Test func twiceTheCadenceSlotIsTheFloorWhenLargerThanMinMs() async throws {
        try await runsFolder { runs in
            try await captureRuns(moving: 19, 20, in: runs)
            let comparison = try RunComparison.write(baseline: "run-a", candidate: "run-b", minMs: 0, in: runs).comparison
            let animation = try #require(comparison.steps.first?.timing?.first { $0.metric == "animation" })
            #expect(animation.floorMs == 33.4)
            #expect(animation.status == .withinDetectionFloor)
        }
    }

    @Test func runListSkipsTheComparisonsFolder() async throws {
        try await runsFolder { runs in
            try await makeRun("run-a", in: runs)
            try await makeRun("run-b", in: runs)
            _ = try RunComparison.write(baseline: "run-a", candidate: "run-b", in: runs)
            let listing = RunStore.list(in: runs)
            #expect(listing.runs.map(\.id).sorted() == ["run-a", "run-b"])
            #expect(listing.warnings.isEmpty)
        }
    }
}
