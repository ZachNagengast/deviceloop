//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct RunExportTests {
    static let home = "/Users/averyfixture"
    static let device = "Avery Fixture iPhone"
    static let errorDevice = "Avery Fixture iPad"
    static let udid = "00008140-001A2B3C4D5E6F70"
    static let typed = "hunter2 secret"
    static let token = Data("deviceloop-fake-runner-token-12345".utf8).base64EncodedString()

    /// Runs `body` with a new temporary folder, its `runs` folder and its `export` folder path, then removes it.
    private func inFolder(_ body: (_ folder: URL, _ runs: URL, _ exportFolder: URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "deviceloop-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(folder, folder.appending(path: "runs"), folder.appending(path: "export"))
    }

    /// A finished run `id` under `runs` with the UDID in its provenance, the device name in `--device`, another device name
    /// in its error, and the home path, typed text and a token in results, the error and a crash report, plus a screenshot
    /// and a video.
    @discardableResult
    private func plantedRun(_ id: String, in runs: URL, image: Data = Data("png".utf8)) async throws -> RunStore {
        let run = try RunStore.named(id, in: runs)
        var provenance = RunComparisonTests.iPhone
        provenance.device.udid = Self.udid
        try run.write(RunManifest(id: id, status: .running, createdAt: RunStore.timestamp(), hostStart: hostNow(), provenance: provenance))
        func record(
            _ command: String, _ args: JSONValue, result: JSONValue? = nil, files: [String: Data] = [:], error: DeviceLoopError? = nil
        ) async throws {
            let started = try await run.append(RunEvent(kind: "started", command: command, args: args)).get()
            if let result { try Paths.writePrivate(try result.data(), to: run.directory.appending(path: "results/\(started.seq).json")) }
            for (path, data) in files { try Paths.writePrivate(data, to: run.directory.appending(path: path)) }
            let finished = RunEvent(
                kind: "finished", command: command, started: started.seq, outcome: error == nil ? .ok : .error, error: error,
                artifacts: files.keys.sorted())
            _ = try await run.append(finished).get()
        }
        try await record("ui type", [.string(Self.typed), "--device", .string(Self.device)], result: ["typed": .string(Self.typed)])
        let field: JSONValue = ["type": "textField", "value": .string(Self.typed), "label": .string("Saved in \(Self.home)/Documents")]
        try await record("ui tree", [], result: ["nodes": [field]])
        let crash = "Incident on \(Self.device) \(Self.udid)\nAuthorization: Bearer \(Self.token)\n"
        try await record(
            "screenshot", [], result: ["pointScale": 3],
            files: ["artifacts/5-shot.png": image, "artifacts/5-capture.mp4": Data("mp4".utf8), "artifacts/5-crash.ips": Data(crash.utf8)])
        let error = DeviceLoopError(
            .textMismatch, "Typed \(Self.typed), the field shows hunter.", detail: "token \(Self.token) in \(Self.home)/Library",
            device: Self.errorDevice)
        try await record("ui tap", ["id=go"], error: error)
        try await run.finalize()
        return run
    }

    private func export(
        run id: String? = "run-a", comparison: String? = nil, from runs: URL, to exportFolder: URL, media: Bool = true,
        keepTypedText: Bool = false, zip: Bool = false, users: [String] = []
    ) async throws -> RunExport.Summary {
        var redactor = SupportExport.redactor(
            home: Self.home, targets: [], signing: SigningState(teams: [], identities: []), storedTeam: nil)
        for user in users { redactor.add(user, as: .user) }
        return try await RunExport.write(
            run: id, comparison: comparison, to: exportFolder, media: media, keepTypedText: keepTypedText, zip: zip, redactor: &redactor,
            in: runs)
    }

    /// Every file under `folder`, relative to it.
    private func files(_ folder: URL) throws -> [String] {
        try RunStore.inventory(folder).map(\.path)
    }

    @Test func exportHasNoPlantedValue() async throws {
        try await inFolder { _, runs, exportFolder in
            try await plantedRun("run-a", in: runs)
            _ = try await export(from: runs, to: exportFolder)
            for path in try files(exportFolder) {
                let data = try Data(contentsOf: exportFolder.appending(path: path))
                for value in [Self.home, Self.device, Self.errorDevice, Self.udid, Self.typed, Self.token] {
                    #expect(data.range(of: Data(value.utf8)) == nil, "\(path) contains \(value)")
                    #expect(!path.contains(value))
                }
            }
        }
    }

    @Test func everyExportedFileIsOwnerOnly() async throws {
        try await inFolder { _, runs, exportFolder in
            let run = try await plantedRun("run-a", in: runs)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: run.artifacts.appending(path: "5-shot.png").path)
            _ = try await export(from: runs, to: exportFolder)
            for path in try files(exportFolder) {
                let attributes = try FileManager.default.attributesOfItem(atPath: exportFolder.appending(path: path).path)
                #expect(attributes[.posixPermissions] as? Int == 0o600, "\(path)")
            }
        }
    }

    @Test func reportLinksResolveInsideTheExport() async throws {
        try await inFolder { _, runs, exportFolder in
            try await plantedRun("run-a", in: runs)
            let summary = try await export(from: runs, to: exportFolder)
            #expect(summary.report == "run-a/report.html")
            let html = try String(contentsOf: exportFolder.appending(path: summary.report), encoding: .utf8)
            let links = html.matches(of: /(?:src|href)="([^"]*)"/).map { String($0.1) }
            #expect(links.contains("./artifacts/5-shot.png"))
            let root = exportFolder.appending(path: "run-a").resolvingSymlinksInPath().path + "/"
            for link in links {
                let file = exportFolder.appending(path: "run-a/\(try #require(link.removingPercentEncoding))").resolvingSymlinksInPath()
                #expect(file.path.hasPrefix(root), "\(link)")
                #expect(FileManager.default.fileExists(atPath: file.path), "\(link)")
            }
        }
    }

    @Test func exportTxtListsTheSHA256OfEveryOtherFile() async throws {
        try await inFolder { _, runs, exportFolder in
            try await plantedRun("run-a", in: runs)
            _ = try await export(from: runs, to: exportFolder)
            let notes = try String(contentsOf: exportFolder.appending(path: "EXPORT.txt"), encoding: .utf8)
            let listed = notes.split(separator: "\n").filter { $0.contains(#/^[0-9a-f]{64}  /#) }.map(String.init)
            let hashed = try RunStore.inventory(exportFolder, skipping: ["EXPORT.txt"]).map { "\($0.sha256)  \($0.path)" }
            #expect(listed == hashed)
            #expect(hashed.contains { $0.hasSuffix("  run-a/report.html") })
        }
    }

    @Test func sourceRunIsByteIdenticalAfterExport() async throws {
        try await inFolder { _, runs, exportFolder in
            let run = try await plantedRun("run-a", in: runs)
            try RunReport.write(run)
            let before = try RunStore.inventory(runs)
            _ = try await export(from: runs, to: exportFolder)
            #expect(try RunStore.inventory(runs) == before)
        }
    }

    @Test func noMediaLeavesNoImageOrVideo() async throws {
        try await inFolder { _, runs, exportFolder in
            try await plantedRun("run-a", in: runs)
            let summary = try await export(from: runs, to: exportFolder, media: false)
            let names = try files(exportFolder)
            #expect(!names.contains { $0.hasSuffix(".png") || $0.hasSuffix(".mp4") })
            #expect(names.contains("run-a/artifacts/5-crash.ips"))
            #expect(
                summary.leftOut == [
                    "run-a/artifacts/5-capture.mp4: image or video, --no-media", "run-a/artifacts/5-shot.png: image or video, --no-media",
                ])
        }
    }

    @Test func noMediaReportSaysTheImageIsLeftOutOfTheExport() async throws {
        try await inFolder { _, runs, exportFolder in
            try await plantedRun("run-a", in: runs)
            _ = try await export(from: runs, to: exportFolder, media: false)
            let html = try String(contentsOf: exportFolder.appending(path: "run-a/report.html"), encoding: .utf8)
            #expect(html.contains("artifacts/5-shot.png left out of this export"))
            #expect(!html.contains("not a file in the run"))
        }
    }

    @Test func noMediaComparisonLinksNoDiffImage() async throws {
        try await inFolder { _, runs, exportFolder in
            for (id, blocks) in [("run-a", []), ("run-b", [[40, 20, 10, 10]])] {
                _ = try ImageDiffTests.png("5-shot.png", in: try await plantedRun(id, in: runs).artifacts, blocks: blocks)
            }
            let (comparison, directory) = try RunComparison.write(baseline: "run-a", candidate: "run-b", in: runs)
            #expect(FileManager.default.fileExists(atPath: directory.appending(path: "step-3-diff.png").path))
            _ = try await export(run: nil, comparison: comparison.id, from: runs, to: exportFolder, media: false)
            let html = try String(contentsOf: exportFolder.appending(path: "comparisons/\(comparison.id)/comparison.html"), encoding: .utf8)
            #expect(!html.contains("diff.png"))
            #expect(html.contains("artifacts/5-shot.png left out of this export"))
            #expect(!html.contains("missing artifacts/"))
        }
    }

    @Test func keepTypedTextKeepsTypedTextAndStillRedacts() async throws {
        try await inFolder { _, runs, exportFolder in
            try await plantedRun("run-a", in: runs)
            _ = try await export(from: runs, to: exportFolder, keepTypedText: true)
            let events = try String(contentsOf: exportFolder.appending(path: "run-a/events.jsonl"), encoding: .utf8)
            #expect(events.contains(Self.typed))
            #expect(!events.contains(Self.device))
        }
    }

    @Test func pasteboardResultIsLeftOutUnlessTypedTextIsKept() async throws {
        try await inFolder { folder, runs, _ in
            let run = try RunStore.named("run-a", in: runs)
            try run.write(RunManifest(id: "run-a", status: .running, createdAt: RunStore.timestamp(), hostStart: hostNow()))
            _ = try await run.append(RunEvent(kind: "started", command: "pasteboard", args: ["paste"])).get()
            try Paths.writePrivate(Data(#"{"text": "clipboard words"}"#.utf8), to: run.directory.appending(path: "results/1.json"))
            _ = try await run.append(RunEvent(kind: "finished", command: "pasteboard", started: 1, outcome: .ok)).get()
            let summary = try await export(from: runs, to: folder.appending(path: "hidden"))
            #expect(summary.leftOut == ["run-a/results/1.json: pasteboard contents"])
            #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "hidden/run-a/results/1.json").path))
            _ = try await export(from: runs, to: folder.appending(path: "kept"), keepTypedText: true)
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "kept/run-a/results/1.json").path))
        }
    }

    @Test func existingOutputFolderIsRefused() async throws {
        try await inFolder { _, runs, exportFolder in
            try await plantedRun("run-a", in: runs)
            try Paths.ensureDirectory(exportFolder)
            let error = await #expect(throws: DeviceLoopError.self) { try await export(from: runs, to: exportFolder) }
            #expect(error?.code == .badArguments)
            #expect(try FileManager.default.contentsOfDirectory(atPath: exportFolder.path).isEmpty)
        }
    }

    @Test func outputInsideTheRunsFolderIsRefused() async throws {
        try await inFolder { _, runs, _ in
            let run = try await plantedRun("run-a", in: runs)
            let before = try RunStore.inventory(runs)
            let error = await #expect(throws: DeviceLoopError.self) {
                try await export(from: runs, to: run.artifacts.appending(path: "export"))
            }
            #expect(error?.code == .badArguments)
            #expect(try RunStore.inventory(runs) == before)
        }
    }

    @Test(arguments: ["link/new", "RUNS/new"])
    func outputInsideTheRunsFolderThroughALinkOrAnotherCaseIsRefused(path: String) async throws {
        try await inFolder { folder, runs, _ in
            try await plantedRun("run-a", in: runs)
            try FileManager.default.createSymbolicLink(at: folder.appending(path: "link"), withDestinationURL: runs)
            let before = try FileManager.default.contentsOfDirectory(atPath: runs.path)
            let error = await #expect(throws: DeviceLoopError.self) { try await export(from: runs, to: folder.appending(path: path)) }
            #expect(error?.code == .badArguments)
            #expect(try FileManager.default.contentsOfDirectory(atPath: runs.path) == before)
        }
    }

    @Test func tokenLeftInAnImageAbortsWithoutWritingTheFolder() async throws {
        try await inFolder { folder, runs, exportFolder in
            try await plantedRun("run-a", in: runs, image: Data("PNG tEXt Comment \(Self.token)".utf8))
            let error = await #expect(throws: DeviceLoopError.self) { try await export(from: runs, to: exportFolder) }
            #expect(error?.code == .internalError)
            #expect(error?.message.contains("run-a/artifacts/5-shot.png") == true)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["runs"])
        }
    }

    @Test func comparisonExportHoldsBothRunsAndItsLinksResolve() async throws {
        try await inFolder { _, runs, exportFolder in
            try await plantedRun("run-a", in: runs)
            try await plantedRun("run-b", in: runs)
            let id = try RunComparison.write(baseline: "run-a", candidate: "run-b", in: runs).comparison.id
            let summary = try await export(run: nil, comparison: id, from: runs, to: exportFolder)
            #expect(summary.report == "comparisons/\(id)/comparison.html")
            let names = try files(exportFolder)
            #expect(names.contains("run-a/report.html"))
            #expect(names.contains("run-b/report.html"))
            let page = exportFolder.appending(path: summary.report)
            let html = try String(contentsOf: page, encoding: .utf8)
            let links = html.matches(of: /(?:src|href)="([^"]*)"/).map { String($0.1) }
            #expect(links.contains("../../run-b/artifacts/5-shot.png"))
            let root = exportFolder.resolvingSymlinksInPath().path + "/"
            for link in links {
                let file = page.deletingLastPathComponent().appending(path: try #require(link.removingPercentEncoding))
                    .resolvingSymlinksInPath()
                #expect(file.path.hasPrefix(root), "\(link)")
                #expect(FileManager.default.fileExists(atPath: file.path), "\(link)")
            }
        }
    }

    @Test func typedTextInComparisonTreeDifferencesIsHidden() async throws {
        try await inFolder { _, runs, exportFolder in
            let baseline = try await plantedRun("run-a", in: runs)
            let candidate = try await plantedRun("run-b", in: runs)
            let echoed = TreeDiffTests.fixture { nodes in
                nodes[TreeDiffTests.index(of: "fixture.text.echo", in: nodes)].label = Self.typed
            }
            for (run, tree) in [(baseline, TreeDiffTests.fixture()), (candidate, echoed)] {
                try JSONValue(encoding: tree).data().write(to: run.directory.appending(path: "results/3.json"))
            }
            let id = try RunComparison.write(baseline: "run-a", candidate: "run-b", in: runs).comparison.id
            _ = try await export(run: nil, comparison: id, from: runs, to: exportFolder)
            let comparison = try JSONDecoder().decode(
                RunComparison.self, from: Data(contentsOf: exportFolder.appending(path: "comparisons/\(id)/comparison.json")))
            #expect(comparison.steps[1].tree?.changed.map(\.candidate) == ["[hidden]"])
            let html = try String(contentsOf: exportFolder.appending(path: "comparisons/\(id)/comparison.html"), encoding: .utf8)
            #expect(!html.contains(Self.typed))
        }
    }

    @Test func shortUserNameLeavesKeysAndFormatNamesDecodable() async throws {
        try await inFolder { _, runs, exportFolder in
            try await plantedRun("run-a", in: runs)
            try await plantedRun("run-b", in: runs)
            let id = try RunComparison.write(baseline: "run-a", candidate: "run-b", in: runs).comparison.id
            _ = try await export(run: nil, comparison: id, from: runs, to: exportFolder, users: ["ted", "sam"])
            let journal = try RunStore(directory: exportFolder.appending(path: "run-a")).events()
            #expect(journal.warnings.isEmpty)
            #expect(journal.events.filter { $0.kind == "started" }.count == 4)
            let comparison = try JSONDecoder().decode(
                RunComparison.self, from: Data(contentsOf: exportFolder.appending(path: "comparisons/\(id)/comparison.json")))
            #expect(comparison.steps.contains { $0.change == .same })
        }
    }

    @Test func shortUserNameKeepsResultKeysAndTheReportListsTheIssue() async throws {
        try await inFolder { _, runs, exportFolder in
            let run = try RunStore.named("run-a", in: runs)
            try run.write(RunManifest(id: "run-a", status: .running, createdAt: RunStore.timestamp(), hostStart: hostNow()))
            _ = try await run.append(RunEvent(kind: "started", command: "test")).get()
            try Paths.writePrivate(
                Data(#"{"issues": [{"isFailure": true, "message": "Expected sue"}]}"#.utf8),
                to: run.directory.appending(path: "results/1.json"))
            _ = try await run.append(RunEvent(kind: "finished", command: "test", started: 1, outcome: .ok)).get()
            _ = try await export(from: runs, to: exportFolder, users: ["sue"])
            let result = try JSONValue(data: Data(contentsOf: exportFolder.appending(path: "run-a/results/1.json")))
            let message = try #require(result["issues"]?.array?.first?["message"]?.string)
            #expect(message.hasPrefix("Expected user-"))
            let html = try String(contentsOf: exportFolder.appending(path: "run-a/report.html"), encoding: .utf8)
            #expect(html.contains("<li>1 test: failure: \(message)</li>"))
        }
    }

    @Test func shortTypedTextIsHiddenOnlyAsAWholeValue() async throws {
        try await inFolder { _, runs, exportFolder in
            let run = try RunStore.named("run-a", in: runs)
            try run.write(RunManifest(id: "run-a", status: .running, createdAt: RunStore.timestamp(), hostStart: hostNow()))
            _ = try await run.append(RunEvent(kind: "started", command: "ui type", args: ["1"])).get()
            try Paths.writePrivate(
                Data(#"{"typed": "1", "productType": "iPhone16,1"}"#.utf8), to: run.directory.appending(path: "results/1.json"))
            _ = try await run.append(RunEvent(kind: "finished", command: "ui type", started: 1, outcome: .ok)).get()
            let summary = try await export(from: runs, to: exportFolder)
            let result = try JSONValue(data: Data(contentsOf: exportFolder.appending(path: "run-a/results/1.json")))
            #expect(result == ["typed": "[hidden]", "productType": "iPhone16,1"])
            let events = try String(contentsOf: exportFolder.appending(path: "run-a/events.jsonl"), encoding: .utf8)
            #expect(events.contains(#""args":["[hidden]"]"#))
            #expect(summary.hidden == 2)
        }
    }

    @Test func zipHoldsTheExportFolder() async throws {
        try await inFolder { _, runs, exportFolder in
            try await plantedRun("run-a", in: runs)
            let summary = try await export(from: runs, to: exportFolder, zip: true)
            let archive = try #require(summary.zip)
            #expect(archive.lastPathComponent == "export.zip")
            #expect(try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? Int == 0o600)
            let listing = try await Shell.run(["/usr/bin/zipinfo", "-1", archive.path]).stdoutString.split(separator: "\n")
            #expect(listing.contains("export/EXPORT.txt"))
            #expect(listing.contains("export/run-a/report.html"))
            #expect(!listing.contains { $0.contains("/._") })
        }
    }

    @Test func typedTextComesFromTypeSiriPasteboardAndTypeSteps() {
        func typed(_ command: String, _ args: JSONValue) -> [String] {
            RunExport.typedText(RunEvent(kind: "started", command: command, args: args))
        }
        #expect(typed("ui type", ["--into", "id=name", "Avery", "--device", "booted"]) == ["Avery"])
        #expect(typed("siri say", ["-d", "booted", "open Notes"]) == ["open Notes"])
        #expect(typed("pasteboard", ["copy", "code 1234"]) == ["code 1234"])
        #expect(typed("pasteboard", ["paste"]) == [])
        #expect(typed("ui do", ["tap id=name", "type \"Avery\""]) == ["type \"Avery\"", "Avery"])
        #expect(typed("device_siri", ["text": "open Notes", "device": "booted"]) == ["open Notes"])
        #expect(typed("ui tap", ["id=name"]) == [])
    }
}
