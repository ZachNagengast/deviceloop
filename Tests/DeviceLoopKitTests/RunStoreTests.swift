//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import CryptoKit
import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct RunStoreTests {
    private func fixture(events count: Int, _ body: (RunStore) async throws -> Void) async throws {
        let run = try RunStore.create()
        defer { try? FileManager.default.removeItem(at: run.directory) }
        for index in 0 ..< count {
            _ = try await run.append(RunEvent(kind: "finished", command: "ui tap", args: ["target": .string("id=\(index)")], outcome: .ok))
                .get()
        }
        try await body(run)
    }

    @Test func finalizeRecordsTheSHA256OfEveryFile() async throws {
        try await fixture(events: 3) { run in
            let screenshot = try RunStore.$current.withValue(run) { try Paths.newArtifact("screenshot", extension: "png") }
            try Data("png".utf8).write(to: screenshot)
            let manifest = try await run.finalize()
            let files = try #require(manifest.files)
            #expect(manifest.status == .finished)
            #expect(files.map(\.path) == ["artifacts/\(screenshot.lastPathComponent)", "events.jsonl"])
            for file in files {
                let data = try Data(contentsOf: run.directory.appending(path: file.path))
                #expect(file.sha256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
                #expect(file.bytes == data.count)
            }
        }
    }

    @Test func runningRunWithExitedOwnerReadsIncompleteWithEventsIntact() async throws {
        try await fixture(events: 3) { run in
            var manifest = try run.manifest()
            #expect(manifest.status == .running)
            let pidStart = try #require(manifest.owner?.pidStart)
            manifest.owner?.pidStart = pidStart + 1
            try run.write(manifest)
            #expect(try run.manifest().status == .incomplete)
            #expect(try run.events().events.map(\.seq) == [1, 2, 3])
        }
    }

    @Test func runWithoutAnOwnerStaysRunning() throws {
        let run = try RunStore.create(owned: false)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        #expect(try run.manifest().owner == nil)
        #expect(try run.manifest().status == .running)
    }

    @Test func finalizeMarksACommandWithoutAFinishedEventFailed() async throws {
        try await fixture(events: 0) { run in
            _ = try await run.append(RunEvent(kind: "started", command: "screenshot")).get()
            _ = try await run.append(RunEvent(kind: "finished", command: "screenshot", started: 1, outcome: .ok)).get()
            _ = try await run.append(RunEvent(kind: "started", command: "ui tap")).get()
            #expect(try await run.finalize().outcome == .failed)
        }
    }

    @Test func truncatedLastJournalLineIsSkippedWithAWarning() async throws {
        try await fixture(events: 3) { run in
            let handle = try FileHandle(forWritingTo: run.eventsURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(#"{"seq":4,"ti"#.utf8))
            try handle.close()
            let journal = try run.events()
            #expect(journal.events.map(\.seq) == [1, 2, 3])
            #expect(journal.warnings == ["events.jsonl line 4 is not a complete event and was skipped."])
        }
    }

    @Test func appendAfterATruncatedLineStartsANewLine() async throws {
        try await fixture(events: 1) { run in
            let handle = try FileHandle(forWritingTo: run.eventsURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(#"{"seq":2,"ti"#.utf8))
            try handle.close()
            let written = try await run.append(RunEvent(kind: "finished", command: "screenshot", outcome: .ok)).get()
            #expect(written.seq == 2)
            #expect(try run.events().events.map(\.command) == ["ui tap", "screenshot"])
        }
    }

    @Test func failedJournalWriteReturnsAWarningAndLeavesTheJournal() async throws {
        try await fixture(events: 1) { run in
            let before = try run.events().events
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: run.eventsURL.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: run.eventsURL.path) }
            let error = DeviceLoopError(.elementNotFound, "No element matches id=missing.")
            guard
                case .failure(let warning) = await run.append(RunEvent(kind: "finished", command: "ui tap", outcome: .error, error: error))
            else {
                Issue.record("A read-only journal accepted an event")
                return
            }
            #expect(warning.message == "Could not journal ui tap in run \(run.id).")
            #expect(try run.events().events == before)
        }
    }

    @Test func finishedRunTakesNoMoreEvents() async throws {
        try await fixture(events: 1) { run in
            try await run.finalize()
            guard case .failure(let warning) = await run.append(RunEvent(kind: "finished", command: "screenshot", outcome: .ok)) else {
                Issue.record("A finished run accepted an event")
                return
            }
            #expect(warning.message == "Run \(run.id) is finished, so screenshot was not journaled.")
            #expect(try run.events().events.count == 1)
        }
    }

    @Test func finalizeWhileAnotherCommandHoldsTheJournalLockNamesTheRun() async throws {
        try await fixture(events: 1) { run in
            let lock = try await SessionLock.acquire(at: run.lockURL)
            defer { lock.release() }
            let error = await #expect(throws: DeviceLoopError.self) { try await run.finalize(timeout: .milliseconds(100)) }
            #expect(error?.code == .deviceBusy)
            #expect(error?.message == "Another DeviceLoop command is writing to run \(run.id).")
            #expect(try run.manifest().status == .running)
        }
    }

    @Test func appendWhileAnotherCommandHoldsTheJournalLockWarnsThatTheCommandWasNotJournaled() async throws {
        try await fixture(events: 1) { run in
            let before = try run.events().events
            let lock = try await SessionLock.acquire(at: run.lockURL)
            defer { lock.release() }
            guard case .failure(let warning) = await run.append(RunEvent(kind: "started", command: "ui tap"), timeout: .milliseconds(100))
            else {
                Issue.record("A locked journal accepted an event")
                return
            }
            #expect(warning.code == .deviceBusy)
            #expect(warning.message == "Another DeviceLoop command is writing to run \(run.id), so ui tap was not journaled.")
            #expect(try run.events().events == before)
        }
    }

    @Test func artifactWrittenByAFailingCommandLandsInTheRun() async throws {
        try await fixture(events: 0) { run in
            var screenshot: URL?
            do {
                try await RunStore.$current.withValue(run) {
                    screenshot = try Paths.newArtifact("screenshot", extension: "png")
                    try Data("png".utf8).write(to: screenshot!)
                    throw DeviceLoopError(.elementNotFound, "No element matches id=missing.")
                }
            } catch {
                #expect((error as? DeviceLoopError)?.code == .elementNotFound)
            }
            let path = try #require(screenshot).path
            #expect(path.hasPrefix(run.artifacts.path + "/"))
            #expect(FileManager.default.fileExists(atPath: path))
        }
    }

    @Test func manifestProvenanceHoldsOnlyTheRecordedKeys() throws {
        let provenance = RunProvenance(
            deviceloop: "0.1.0", macOS: "27.2.0", xcode: "Xcode 27.2", xcodeBuild: "27C100",
            device: .init(
                udid: "unit-test", model: "iPhone 17 Pro", productType: "iPhone18,1", osVersion: "27.0", osBuild: "24A434",
                transport: "sameMachine"),
            screen: .init(pointWidth: 402, pointHeight: 874, scale: 3, orientation: "portrait"), locale: "en_US",
            runnerBuild: "17.0", app: .init(bundleID: "com.example.app", version: "1.2", build: "34"),
            source: .init(revision: "0123456789abcdef0123456789abcdef01234567", dirty: true))
        let run = try RunStore.create(provenance: provenance)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        func keys(_ value: JSONValue, _ prefix: String) -> [String] {
            guard case .object(let fields) = value else { return [prefix] }
            return fields.flatMap { keys($0.value, prefix + "." + $0.key) }
        }
        let manifest = try JSONValue(data: Data(contentsOf: run.manifestURL))
        #expect(
            keys(try #require(manifest["provenance"]), "provenance").sorted() == [
                "provenance.app.build", "provenance.app.bundleID", "provenance.app.version", "provenance.device.model",
                "provenance.device.osBuild", "provenance.device.osVersion", "provenance.device.productType", "provenance.device.transport",
                "provenance.device.udid", "provenance.deviceloop", "provenance.locale", "provenance.macOS", "provenance.runnerBuild",
                "provenance.screen.orientation", "provenance.screen.pointHeight", "provenance.screen.pointWidth", "provenance.screen.scale",
                "provenance.source.dirty", "provenance.source.revision", "provenance.xcode", "provenance.xcodeBuild",
            ])
        #expect(try run.manifest().provenance == provenance)
    }

    @Test func runnerBuildIsTheCacheKeyFolderOfTheXctestrun() {
        let key = "sim-" + String(repeating: "0a", count: 32)
        let xctestrun = Paths.runnerBuilds.appending(path: "\(key)/Build/Products/run-\(UUID().uuidString).xctestrun")
        #expect(RunProvenance.runnerBuildKey(xctestrun.path) == key)
        #expect(RunProvenance.runnerBuildKey("/tmp/run.xctestrun") == nil)
        #expect(RunProvenance.runnerBuildKey(nil) == nil)
    }

    @Test func flatDeviceRecordsItsUprightOrientation() {
        let displays = DeviceDisplays(devicectl: [
            "displays": [["nativeSize": [1170, 2532], "pointScale": 3, "primary": true]],
            "orientation": ["currentDeviceNonFlatOrientation": "landscapeLeft", "currentDeviceOrientation": "faceUp"],
        ])
        #expect(RunProvenance.Screen(displays) == .init(pointWidth: 390, pointHeight: 844, scale: 3, orientation: "landscapeLeft"))
    }

    /// Runs `body` with a new git checkout that has `README` committed and the local `config` settings, then removes it.
    private func inCheckout(config: [[String]] = [], _ body: (URL) async throws -> Void) async throws {
        let checkout = FileManager.default.temporaryDirectory.appending(path: "deviceloop-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: checkout) }
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: checkout.appending(path: "README"))
        let isolated = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        for arguments in [
            ["init", "-q"], ["add", "README"],
            ["-c", "user.name=test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "one"],
        ] + config.map({ ["config"] + $0 }) {
            #expect(try await Shell.run(["git", "-C", checkout.path] + arguments, environment: isolated).succeeded)
        }
        try await body(checkout)
    }

    @Test func gitSourceWithChangesRecordsDirty() async throws {
        try await inCheckout { checkout in
            #expect(try await RunProvenance.git(checkout).dirty == false)
            try Data("two".utf8).write(to: checkout.appending(path: "README"))
            let source = try await RunProvenance.git(checkout)
            #expect(source.dirty)
            #expect(source.revision.count == 40)
        }
    }

    @Test func gitSourceDoesNotRunTheCheckoutFsmonitorHook() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "deviceloop-fsmonitor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        try await inCheckout(config: [["core.fsmonitor", "touch '\(marker.path)'; false"]]) { checkout in
            _ = try await RunProvenance.git(checkout)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func untrackedFileIsDirtyWhenStatusHidesUntrackedFiles() async throws {
        try await inCheckout(config: [["status.showUntrackedFiles", "no"]]) { checkout in
            try Data("new".utf8).write(to: checkout.appending(path: "NOTES"))
            #expect(try await RunProvenance.git(checkout).dirty)
        }
    }

    /// Runs `body` with a new temporary runs folder, then removes it.
    private func runsFolder(_ body: (URL) async throws -> Void) async throws {
        let runs = FileManager.default.temporaryDirectory.appending(
            path: "deviceloop-runs-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: runs) }
        try await body(runs)
    }

    /// A run in `runs` created `days` days ago with a 1000 byte screenshot.
    private func makeRun(_ id: String, daysAgo days: Double, in runs: URL, status: RunManifest.Status = .finished) throws -> RunStore {
        let run = try RunStore.named(id, in: runs)
        let created = Date().addingTimeInterval(-days * 86_400).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        try run.write(RunManifest(id: id, status: status, createdAt: created, hostStart: 0))
        try Paths.writePrivate(Data(count: 1000), to: run.artifacts.appending(path: "shot.png"))
        return run
    }

    @Test func listShowsNewestFirstWithTheFirstFailureCode() async throws {
        try await runsFolder { runs in
            let failed = try makeRun("run-a", daysAgo: 2, in: runs, status: .running)
            _ = try await failed.append(RunEvent(kind: "started", command: "ui tap")).get()
            let error = DeviceLoopError(.elementNotFound, "No element matches id=missing.")
            _ = try await failed.append(RunEvent(kind: "finished", command: "ui tap", started: 1, outcome: .error, error: error)).get()
            _ = try makeRun("run-b", daysAgo: 1, in: runs)
            let listed = RunStore.list(in: runs).runs
            #expect(listed.map(\.id) == ["run-b", "run-a"])
            #expect(listed.map(\.failure) == [nil, "element_not_found"])
        }
    }

    @Test func pruneKeepingOneRemovesTheOlderRunsAndKeepsTheActiveOne() async throws {
        try await runsFolder { runs in
            let active = try makeRun("run-active", daysAgo: 9, in: runs, status: .running)
            try RunRecorder.activate(active, on: "unit-test", in: runs)
            for (id, days) in [("run-a", 3.0), ("run-b", 2.0), ("run-c", 1.0)] {
                _ = try makeRun(id, daysAgo: days, in: runs)
            }
            #expect(try RunStore.prune(keep: 1, olderThan: nil, in: runs).removed.map(\.id) == ["run-b", "run-a"])
            #expect(RunStore.list(in: runs).runs.map(\.id) == ["run-c", "run-active"])
        }
    }

    @Test func pruneReportsTheBytesItFreed() async throws {
        try await runsFolder { runs in
            var freed = 0
            for (id, days) in [("run-a", 3.0), ("run-b", 2.0), ("run-c", 1.0)] {
                let run = try makeRun(id, daysAgo: days, in: runs)
                if id != "run-c" { freed += 1000 + (try Data(contentsOf: run.manifestURL)).count }
            }
            let result = try RunCommands.prune(keep: 1, olderThan: nil, in: runs)
            #expect(result.json["freedBytes"] == .number(Double(freed)))
        }
    }

    @Test func pruneOlderThanRemovesOnlyRunsCreatedBeforeTheCutoff() async throws {
        try await runsFolder { runs in
            _ = try makeRun("run-old", daysAgo: 10, in: runs)
            _ = try makeRun("run-new", daysAgo: 1, in: runs)
            #expect(try RunStore.prune(keep: nil, olderThan: 7, in: runs).removed.map(\.id) == ["run-old"])
        }
    }

    @Test func pruneWithBothOptionsRemovesOnlyRunsBothSelect() async throws {
        try await runsFolder { runs in
            for (id, days) in [("run-old", 10.0), ("run-recent", 3.0), ("run-new", 1.0)] {
                _ = try makeRun(id, daysAgo: days, in: runs)
            }
            #expect(try RunStore.prune(keep: 1, olderThan: 7, in: runs).removed.map(\.id) == ["run-old"])
        }
    }

    @Test func pruneWithoutAnOptionIsABadArgument() {
        let error = #expect(throws: DeviceLoopError.self) { try RunStore.prune(keep: nil, olderThan: nil) }
        #expect(error?.code == .badArguments)
    }

    @Test func runsLiveOutsideSessionAndRunnerFolders() {
        let runs = Paths.runs.path + "/"
        #expect(!runs.hasPrefix(Paths.session(for: "udid").deletingLastPathComponent().path + "/"))
        #expect(!runs.hasPrefix(Paths.runnerBuilds.path + "/"))
        #expect(Paths.runs.deletingLastPathComponent().path == Paths.home.path)
    }
}
