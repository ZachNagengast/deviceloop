//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct RunReportTests {
    /// Runs `body` with a running run in a new temporary folder, then removes the folder.
    private func inRun(_ body: (RunStore) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "deviceloop-report-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let run = RunStore(directory: folder.appending(path: "run", directoryHint: .isDirectory))
        try run.write(RunManifest(id: run.id, status: .running, createdAt: RunStore.timestamp(), hostStart: hostNow()))
        try await body(run)
    }

    @Test func eventLabelsAndErrorLinesAreEscaped() async throws {
        try await inRun { run in
            let started = try await run.append(RunEvent(kind: "started", command: "ui tap", args: ["<img src=x onerror=alert(1)>"])).get()
            let error = DeviceLoopError(.elementNotFound, "No element matches.", detail: "line one\n</table>")
            _ = try await run.append(RunEvent(kind: "finished", command: "ui tap", started: started.seq, outcome: .error, error: error))
                .get()
            let html = try RunReport.html(run)
            #expect(html.contains("ui tap &lt;img src=x onerror=alert(1)&gt;"))
            #expect(!html.contains("<img src=x"))
            #expect(html.contains("line one\n&lt;/table&gt;"))
            #expect(html.components(separatedBy: "</table>").count == html.components(separatedBy: "<table").count)
        }
    }

    @Test func everySourceAndLinkIsAFileInsideTheRun() async throws {
        try await inRun { run in
            let outside = run.directory.deletingLastPathComponent().appending(path: "outside.png")
            try Data("png".utf8).write(to: outside)
            for name in ["shot.png", "a b#?.png"] {
                try Paths.writePrivate(Data("png".utf8), to: run.artifacts.appending(path: name))
            }
            let started = try await run.append(RunEvent(kind: "started", command: "screenshot", args: ["https://example.com/x.png"])).get()
            let artifacts = ["artifacts/shot.png", "artifacts/a b#?.png", "../outside.png", outside.path, "https://example.com/x.png"]
            _ = try await run.append(
                RunEvent(kind: "finished", command: "screenshot", started: started.seq, outcome: .ok, artifacts: artifacts)
            ).get()
            let html = try RunReport.html(run)
            #expect(!html.lowercased().contains("<script"))
            let links = html.matches(of: /(?:src|href)="([^"]*)"/).map { String($0.1) }
            #expect(Set(links) == ["./artifacts/shot.png", "./artifacts/a%20b%23%3F.png", "./events.jsonl"])
            let root = run.directory.resolvingSymlinksInPath().path + "/"
            for link in links {
                let file = run.directory.appending(path: try #require(link.removingPercentEncoding)).resolvingSymlinksInPath()
                #expect(file.path.hasPrefix(root))
                #expect(FileManager.default.fileExists(atPath: file.path))
            }
        }
    }

    @Test func incompleteRunWithoutFinishedEventsAndAnUndecodablePNGRenders() async throws {
        try await inRun { run in
            try Paths.writePrivate(Data("not a png".utf8), to: run.artifacts.appending(path: "broken.png"))
            _ = try await run.append(RunEvent(kind: "started", command: "screenshot")).get()
            var manifest = try run.manifest()
            manifest.owner = RunManifest.Owner(pid: getpid(), pidStart: 1)
            try run.write(manifest)
            let html = try RunReport.html(run)
            #expect(html.contains("<p class=\"pill warn\">incomplete, 1 command</p>"))
            #expect(html.contains("<li>1 screenshot has no finished event.</li>"))
            #expect(html.contains("<a href=\"./artifacts/broken.png\">artifacts/broken.png</a>"))
        }
    }

    @Test func failingStepShowsCodeFixAndDetail() async throws {
        try await inRun { run in
            _ = try await run.append(RunEvent(kind: "started", command: "screenshot")).get()
            _ = try await run.append(RunEvent(kind: "finished", command: "screenshot", started: 1, outcome: .ok)).get()
            let started = try await run.append(RunEvent(kind: "started", command: "ui tap", args: ["id=missing"])).get()
            let error = DeviceLoopError(.elementNotFound, "No element matches id=missing.", fix: "Run ui tree.", detail: "run x event 3")
            _ = try await run.append(RunEvent(kind: "finished", command: "ui tap", started: started.seq, outcome: .error, error: error))
                .get()
            #expect(
                try RunReport.html(run).contains(
                    "<dl class=\"failure\"><dt>Step</dt><dd>3 ui tap id=missing</dd>"
                        + "<dt>Code</dt><dd>element_not_found</dd><dt>Message</dt><dd>No element matches id=missing.</dd>"
                        + "<dt>Fix</dt><dd>Run ui tree.</dd><dt>Detail</dt><dd>run x event 3</dd></dl>"))
        }
    }

    @Test func xctestIssuesInResultsAreListed() async throws {
        try await inRun { run in
            let started = try await run.append(RunEvent(kind: "started", command: "ui tap", args: ["id=go"])).get()
            _ = try await run.append(RunEvent(kind: "finished", command: "ui tap", started: started.seq, outcome: .ok)).get()
            let result: JSONValue = ["issues": [["type": 4, "message": "Timed out waiting for idle", "isFailure": false]]]
            try Paths.writePrivate(try result.data(), to: run.directory.appending(path: "results/1.json"))
            #expect(try RunReport.html(run).contains("<li>1 ui tap: warning type 4: Timed out waiting for idle</li>"))
        }
    }

    @Test func xctestIssueWithATypeOutsideIntRenders() async throws {
        try await inRun { run in
            let started = try await run.append(RunEvent(kind: "started", command: "ui tap")).get()
            _ = try await run.append(RunEvent(kind: "finished", command: "ui tap", started: started.seq, outcome: .ok)).get()
            let result: JSONValue = ["issues": [["type": 1e300, "message": "Timed out", "isFailure": true]]]
            try Paths.writePrivate(try result.data(), to: run.directory.appending(path: "results/1.json"))
            #expect(try RunReport.html(run).contains("<li>1 ui tap: failure: Timed out</li>"))
        }
    }

    @Test func hashInventoryListsRecordedFilesAndNotesMissingOnes() async throws {
        try await inRun { run in
            try Paths.writePrivate(Data("png".utf8), to: run.artifacts.appending(path: "shot.png"))
            try Paths.writePrivate(Data("mp4".utf8), to: run.artifacts.appending(path: "gone.mp4"))
            let manifest = try await run.finalize()
            try FileManager.default.removeItem(at: run.artifacts.appending(path: "gone.mp4"))
            let shot = try #require(manifest.files?.first { $0.path == "artifacts/shot.png" })
            let html = try RunReport.html(run)
            #expect(
                html.contains(
                    "<tr><td><a href=\"./artifacts/shot.png\">artifacts/shot.png</a></td><td>3</td>"
                        + "<td class=\"hash\">\(shot.sha256)</td></tr>"))
            #expect(html.contains("<li>artifacts/gone.mp4 is in the hash inventory but not in the run.</li>"))
        }
    }

    @Test func escapeCoversAQuoteFollowedByACombiningMark() {
        #expect(RunReport.escape("\"\u{301}'\u{301}<\u{338}") == "&quot;\u{301}&#39;\u{301}&lt;\u{338}")
    }

    @Test func finalizeSkipsAReportRenderedDuringTheRun() async throws {
        try await inRun { run in
            try RunReport.write(run)
            #expect(try await run.finalize().files?.map(\.path) == [])
        }
    }

    @Test func stopWritesTheReport() async throws {
        let target = Target(
            udid: "unit-test-\(UUID().uuidString)", identifier: "unit-test", name: "Test Simulator", kind: .simulator, deviceType: "iPhone",
            platform: "iOS", model: "iPhone 17 Pro", productType: "iPhone18,1", osVersion: "27.1", connectionState: "connected",
            bootState: "booted")
        let run = try RunStore.create(owned: false)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        try RunRecorder.activate(run, on: target.udid)
        let result = try await RunCommands.stop(target)
        let page = run.directory.appending(path: "report.html")
        #expect(result.text.hasSuffix("\nreport \(page.path)"))
        #expect(try String(contentsOf: page, encoding: .utf8).contains("<h1>run \(run.id)</h1>"))
    }
}
