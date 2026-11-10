//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct TraceCommandsTests {
    private let target = Target(
        udid: "00000000-0000-0000-0000-00000000F00D", identifier: "00000000-0000-0000-0000-00000000F00D", name: "Trace Simulator",
        kind: .simulator, deviceType: "iPhone", platform: "iOS", model: "fixture", productType: "fixture", osVersion: "27.0",
        connectionState: "connected", bootState: "booted"
    )

    /// An executable xctrace stand-in in a new directory. `record` runs `body` with `$out` set to the --output path,
    /// `$notify` to the --notify-tracing-started name and `$dir` to the directory. `export` prints a TOC naming `device`,
    /// pid 42 and Example.
    private func stub(_ body: String, device: String? = nil) throws -> (xctrace: [String], directory: URL) {
        let directory = try Paths.ensureDirectory(Paths.home.appending(path: "trace-tests/\(UUID().uuidString)"))
        try """
        <?xml version="1.0"?>
        <trace-toc><run number="1"><info><target>
        <device platform="iOS Simulator" uuid="\(device ?? target.udid)"/><process type="attached" name="Example" pid="42"/>
        </target><summary><duration>1.0</duration><end-reason>Time limit reached</end-reason>
        <template-name>Time Profiler</template-name></summary></info>
        <data><table schema="time-profile"/></data></run></trace-toc>
        """.write(to: directory.appending(path: "toc.xml"), atomically: true, encoding: .utf8)
        let script = directory.appending(path: "xctrace")
        try """
        #!/bin/bash
        if [ "$1" = export ]; then cat "$(dirname "$0")/toc.xml"; exit 0; fi
        while [ $# -gt 0 ]; do [ "$1" = --output ] && out="$2"; [ "$1" = --notify-tracing-started ] && notify="$2"; shift; done
        dir="$(dirname "$0")"
        \(body)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return ([script.path], directory)
    }

    private func record(
        _ stub: (xctrace: [String], directory: URL), output: String = "run.trace", timeout: Duration? = nil,
        freeBytes: @escaping (URL) -> Int64? = { _ in nil }
    ) async throws -> CommandResult {
        try await TraceCommands.record(
            target, app: "com.example.app", pid: 42, names: ["Example"], template: "Time Profiler", limitMs: 1000,
            output: stub.directory.appending(path: output), xctrace: stub.xctrace, timeout: timeout, grace: .seconds(2),
            freeBytes: freeBytes)
    }

    private func waitForFile(_ file: URL) async throws {
        for _ in 0 ..< 100 where !FileManager.default.fileExists(atPath: file.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func argumentsNameTheDeviceAndNeverAllProcesses() throws {
        let arguments = TraceCommands.arguments(
            udid: target.udid, pid: 42, template: "Time Profiler", limitMs: 5000, output: URL(filePath: "/tmp/run.trace"))
        let device = try #require(arguments.firstIndex(of: "--device"))
        #expect(arguments[device + 1] == target.udid)
        #expect(!arguments.contains("--all-processes"))
    }

    @Test func timeLimitIsCappedAt60Seconds() throws {
        #expect(try TraceCommands.timeLimitMs(600_000) == 60_000)
    }

    @Test func nonPositiveDurationIsRejected() {
        #expect(throws: DeviceLoopError.self) { try TraceCommands.timeLimitMs(0) }
    }

    @Test func processNamesAddTheBundleName() throws {
        let entry: JSONValue = [
            "bundleIdentifier": "com.apple.Preferences", "name": "Settings", "url": "file:///Applications/Preferences.app/",
        ]
        let settings = try #require(InstalledApp(devicectl: entry))
        #expect(TraceCommands.processNames(settings) == ["Settings", "Preferences"])
    }

    @Test func templateNamesSkipSectionHeaders() {
        let listing = "== Standard Templates ==\nActivity Monitor\nTime Profiler\n\n== User Templates ==\nMine\n"
        #expect(TraceCommands.templateNames(listing) == ["Activity Monitor", "Time Profiler", "Mine"])
    }

    @Test func cancelForwardsSIGINTAndKeepsTheSavedTrace() async throws {
        let stub = try stub(
            """
            trap 'touch "$dir/interrupted"; mkdir "$out"; exit 0' INT
            echo "Ctrl-C to stop the recording"
            touch "$dir/recording"
            while true; do sleep 0.05; done
            """)
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        let task = Task { try await record(stub) }
        try await waitForFile(stub.directory.appending(path: "recording"))
        task.cancel()
        let result = try await task.value
        #expect(result.json["stoppedEarly"]?.bool == true)
        #expect(FileManager.default.fileExists(atPath: stub.directory.appending(path: "interrupted").path))
    }

    @Test func cancelBeforeRecordingStartsIsCancellation() async throws {
        let stub = try stub(
            """
            trap 'exit 1' INT
            touch "$dir/attaching"
            while true; do sleep 0.05; done
            """)
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        let task = Task { try await record(stub) }
        try await waitForFile(stub.directory.appending(path: "attaching"))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func timeoutKillsXctrace() async throws {
        let stub = try stub(
            """
            echo $$ > "$dir/pid"
            trap '' INT
            echo "Ctrl-C to stop the recording"
            while true; do sleep 0.05; done
            """)
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        await #expect {
            try await record(stub, timeout: .seconds(5))
        } throws: {
            ($0 as? DeviceLoopError)?.code == .timeout
        }
        let pid = try String(contentsOf: stub.directory.appending(path: "pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!Shell.isRunning(try #require(Int32(pid))))
    }

    @Test func tempDirectoryIsRemovedAfterRecording() async throws {
        let stub = try stub(
            """
            echo "$TMPDIR" > "$dir/tmpdir"
            touch "$TMPDIR/scratch"
            mkdir "$out"
            """)
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        _ = try await record(stub)
        let temp = try String(contentsOf: stub.directory.appending(path: "tmpdir"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(temp.hasPrefix(Paths.home.path))
        #expect(!FileManager.default.fileExists(atPath: temp))
    }

    @Test func missingOutputDirectoryIsCreated() async throws {
        let stub = try stub("mkdir \"$out\"")
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        let result = try await record(stub, output: "new/run.trace")
        #expect(result.json["trace"]?.string == stub.directory.appending(path: "new/run.trace").path)
    }

    @Test func recordWritesTheTOCAndSummaryNextToTheTrace() async throws {
        let stub = try stub("mkdir \"$out\"")
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        let result = try await record(stub)
        let summary = try JSONValue(data: Data(contentsOf: stub.directory.appending(path: "run.summary.json")))
        #expect(summary["schema"] == "deviceloop.trace/1")
        #expect(summary["partial"] == true)
        #expect(result.json.value(at: "summary.toc")?.string == stub.directory.appending(path: "run.toc.xml").path)
        #expect(FileManager.default.fileExists(atPath: stub.directory.appending(path: "run.toc.xml").path))
    }

    @Test func traceOfAnotherDeviceFailsAndIsKept() async throws {
        let stub = try stub("mkdir \"$out\"", device: "00000000-0000-0000-0000-00000000BEEF")
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        await #expect {
            try await record(stub)
        } throws: {
            ($0 as? DeviceLoopError)?.code == .deviceError
        }
        #expect(FileManager.default.fileExists(atPath: stub.directory.appending(path: "run.trace").path))
    }

    @Test func animationHitchesOnASimulatorIsRefusedBeforeWriting() async throws {
        let output = Paths.home.appending(path: "trace-tests/\(UUID().uuidString)/hitches.trace")
        let error = await #expect(throws: DeviceLoopError.self) {
            try await TraceCommands.record(
                target, app: "com.example.app", template: TraceSummary.hitchesTemplate, durationMs: nil, output: output)
        }
        #expect(error?.code == .unsupportedOnTarget)
        #expect(!FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path))
    }

    @Test func failureBeforeRecordingIsUnsupportedOnTarget() async throws {
        let stub = try stub(
            """
            echo "Cannot find process for provided pid: 42" >&2
            exit 19
            """)
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        await #expect {
            try await record(stub)
        } throws: {
            let error = $0 as? DeviceLoopError
            return error?.code == .unsupportedOnTarget && error?.message.contains("Cannot find process") == true
        }
    }

    @Test func unsupportedTemplateErrorIsUnsupportedOnTarget() async throws {
        let stub = try stub(
            """
            echo "Ctrl-C to stop the recording"
            echo "* [Error] Hitches is not supported on this platform."
            mkdir "$out"
            exit 2
            """)
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        await #expect {
            try await record(stub)
        } throws: {
            let error = $0 as? DeviceLoopError
            return error?.code == .unsupportedOnTarget && error?.message.hasSuffix(": Hitches is not supported on this platform.") == true
        }
    }

    /// Posts the tracing-started notification after touching `$dir/started`, then records until SIGINT.
    private let tracingStub = """
        trap 'touch "$dir/interrupted"; mkdir "$out"; exit 0' INT
        echo "Ctrl-C to stop the recording"
        touch "$dir/started"
        notifyutil -p "$notify"
        while true; do sleep 0.05; done
        """

    private func run(
        _ stub: (xctrace: [String], directory: URL), freeBytes: @escaping (URL) -> Int64? = { _ in nil },
        during: @escaping () async throws -> Void
    ) async throws -> Bool {
        try await TraceCommands.run(
            target, app: "com.example.app", pid: 42, template: "Animation Hitches", limitMs: 5000,
            output: stub.directory.appending(path: "run.trace"), xctrace: stub.xctrace, grace: .seconds(2), freeBytes: freeBytes,
            during: during)
    }

    @Test func duringRunsOnceTracingStartsAndThenStopsXctrace() async throws {
        let stub = try stub(tracingStub)
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        var startedBeforeDuring = false
        let stopped = try await run(stub) {
            startedBeforeDuring = FileManager.default.fileExists(atPath: stub.directory.appending(path: "started").path)
        }
        #expect(startedBeforeDuring)
        #expect(stopped)
        #expect(FileManager.default.fileExists(atPath: stub.directory.appending(path: "interrupted").path))
    }

    @Test func failureBeforeTracingStartsSkipsDuring() async throws {
        let stub = try stub(
            """
            echo "Cannot find process for provided pid: 42" >&2
            exit 21
            """)
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        var ran = false
        await #expect {
            _ = try await run(stub) { ran = true }
        } throws: {
            ($0 as? DeviceLoopError)?.code == .unsupportedOnTarget
        }
        #expect(!ran)
    }

    @Test func captureThatXctraceCannotRecordSuggestsDroppingInstruments() async throws {
        let stub = try stub(
            """
            echo "Cannot find process for provided pid: 42" >&2
            exit 21
            """)
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        await #expect {
            _ = try await run(stub) {}
        } throws: {
            ($0 as? DeviceLoopError)?.fix?.contains("drop --instruments") == true
        }
    }

    @Test func duringErrorIsThrownAfterXctraceStops() async throws {
        let stub = try stub(tracingStub)
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        await #expect {
            _ = try await run(stub) { throw DeviceLoopError(.elementNotFound, "step failed") }
        } throws: {
            ($0 as? DeviceLoopError)?.message == "step failed"
        }
        #expect(FileManager.default.fileExists(atPath: stub.directory.appending(path: "interrupted").path))
    }

    @Test func failureAfterTheTracingNotificationIsNotCancellation() async throws {
        let stub = try stub(
            """
            trap 'exit 1' INT
            notifyutil -p "$notify"
            while true; do sleep 0.05; done
            """)
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        await #expect {
            _ = try await run(stub) {}
        } throws: {
            ($0 as? DeviceLoopError)?.code == .deviceError
        }
    }

    @Test func lowDiskBeforeACaptureNamesWaitMs() async throws {
        let stub = try stub("mkdir \"$out\"")
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        await #expect {
            _ = try await run(stub, freeBytes: { _ in 1_000_000_000 }, during: {})
        } throws: {
            ($0 as? DeviceLoopError)?.fix?.contains("--wait-ms") == true
        }
    }

    @Test func capturedTraceAndTOCAreDeletedAfterExport() async throws {
        let stub = try stub(tracingStub)
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        let exported = try await VideoCommands.traced(
            target, app: "com.example.app", pid: 42, names: ["Example"], limitMs: 1000, keepTrace: false, xctrace: stub.xctrace
        ) {}
        #expect(exported.toc.pid == 42)
        #expect(!FileManager.default.fileExists(atPath: exported.summary.trace))
        #expect(!FileManager.default.fileExists(atPath: exported.summary.toc))
    }

    @Test func capturedTraceOfAnotherDeviceIsKeptAndNamed() async throws {
        let stub = try stub(tracingStub, device: "00000000-0000-0000-0000-00000000BEEF")
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        do {
            _ = try await VideoCommands.traced(
                target, app: "com.example.app", pid: 42, names: ["Example"], limitMs: 1000, keepTrace: false, xctrace: stub.xctrace
            ) {}
            Issue.record("A trace of another device exported")
        } catch {
            let failure = try #require(error as? DeviceLoopError)
            let trace = try #require(failure.detail?.components(separatedBy: "trace kept at ").last)
            defer {
                try? FileManager.default.removeItem(atPath: trace)
                try? FileManager.default.removeItem(at: TraceCommands.sibling(URL(filePath: trace), "toc.xml"))
            }
            #expect(failure.code == .deviceError)
            #expect(failure.message.hasPrefix("The trace at \(trace) records Example"))
            #expect(FileManager.default.fileExists(atPath: trace))
        }
    }

    @Test func keepTraceKeepsTheCapturedTraceAndTOC() async throws {
        let stub = try stub(tracingStub)
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        let exported = try await VideoCommands.traced(
            target, app: "com.example.app", pid: 42, names: ["Example"], limitMs: 1000, keepTrace: true, xctrace: stub.xctrace
        ) {}
        defer {
            try? FileManager.default.removeItem(atPath: exported.summary.trace)
            try? FileManager.default.removeItem(atPath: exported.summary.toc)
        }
        #expect(FileManager.default.fileExists(atPath: exported.summary.trace))
        #expect(FileManager.default.fileExists(atPath: exported.summary.toc))
    }

    @Test func lowDiskRefusesBeforeSpawning() async throws {
        let stub = try stub("touch \"$dir/ran\"")
        defer { try? FileManager.default.removeItem(at: stub.directory) }
        await #expect {
            try await record(stub, freeBytes: { _ in 1_000_000_000 })
        } throws: {
            ($0 as? DeviceLoopError)?.code == .badArguments
        }
        #expect(!FileManager.default.fileExists(atPath: stub.directory.appending(path: "ran").path))
    }
}
