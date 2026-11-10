//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import CryptoKit
import Darwin
import Foundation

/// The `manifest.json` of a run.
public struct RunManifest: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case running
        case finished
        /// Marked running, but the process that owns the run has exited.
        case incomplete
    }

    public enum Outcome: String, Codable, Sendable {
        case passed
        /// A command failed, was cancelled or has no finished event.
        case failed
    }

    /// The process that created the run.
    public struct Owner: Codable, Sendable, Equatable {
        public var pid: Int32
        /// Start time of `pid` in microseconds since 1970.
        public var pidStart: UInt64?
    }

    public struct File: Codable, Sendable, Equatable {
        /// Relative to the run directory.
        public var path: String
        public var bytes: Int
        public var sha256: String
    }

    public var schema = "deviceloop.run/1"
    public var id: String
    public var name: String?
    public var status: Status
    /// Written by `finalize`.
    public var outcome: Outcome?
    public var createdAt: String
    public var finishedAt: String?
    /// Host clock seconds at creation. Event offsets count from here.
    public var hostStart: Double
    /// Nil for a run that no process owns, which stays running until it is finalized.
    public var owner: Owner?
    public var provenance: RunProvenance?
    /// Every file in the run except `RunStore.unhashed`, written by `finalize`.
    public var files: [File]?
}

/// The tools, target, runner, app and source a run was recorded with. Holds no environment, signing identity or token.
public struct RunProvenance: Codable, Sendable, Equatable {
    public struct Device: Codable, Sendable, Equatable {
        public var udid: String
        public var model: String
        public var productType: String
        public var osVersion: String
        public var osBuild: String?
        public var transport: String?
    }

    public struct App: Codable, Sendable, Equatable {
        public var bundleID: String
        public var version: String?
        public var build: String?
    }

    /// The visible display from `devicectl device info displays`.
    public struct Screen: Codable, Sendable, Equatable {
        public var pointWidth: Int
        public var pointHeight: Int
        public var scale: Double
        /// `currentDeviceNonFlatOrientation`, else `currentDeviceOrientation`, for example `portrait`.
        public var orientation: String?
    }

    public struct Source: Codable, Sendable, Equatable {
        /// `git rev-parse HEAD`.
        public var revision: String
        /// `git status --porcelain --untracked-files=normal` listed changed or untracked files.
        public var dirty: Bool
    }

    public var deviceloop: String
    public var macOS: String
    /// First line of `xcodebuild -version`, for example `Xcode 27.2`.
    public var xcode: String?
    public var xcodeBuild: String?
    public var device: Device
    public var screen: Screen?
    /// `AppleLocale` of a simulator. Nil on devices, which no public tool reads it from.
    public var locale: String?
    /// The runner build cache key, such as `sim-<sha256>`, when a runner was already running.
    public var runnerBuild: String?
    public var app: App?
    public var source: Source?

    /// Reads Xcode, `target`, its screen and locale, its running runner, `app` on `target` and the git state of `source`.
    public static func collect(_ target: Target, version: String, app: String?, source: URL?) async throws -> RunProvenance {
        let system = ProcessInfo.processInfo.operatingSystemVersion
        async let displays = DeviceCommands.optionalDisplays(target)
        async let locale =
            target.isSimulator ? (try? await Simctl.run(["spawn", target.udid, "defaults", "read", "-g", "AppleLocale"])) : nil
        let xcode = try? await Shell.run(["xcodebuild", "-version"], timeout: .seconds(30))
        let xcodeOutput = xcode?.succeeded == true ? xcode?.stdoutString : nil
        let runner = try? await RunnerSession.reattach(target)
        var installed: App?
        if let app {
            guard let found = try await DeviceQueries.installedApp(target, bundleID: app) else {
                throw DeviceQueries.appNotInstalled(app, on: target)
            }
            installed = App(bundleID: found.bundleID, version: found.version, build: found.build)
        }
        var checkout: Source?
        if let source { checkout = try await git(source) }
        return RunProvenance(
            deviceloop: version,
            macOS: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
            xcode: xcodeOutput?.split(whereSeparator: \.isNewline).first.map(String.init),
            xcodeBuild: xcodeOutput.flatMap { try? RunnerBuild.xcodeBuildVersion($0) },
            device: Device(
                udid: target.udid, model: target.model, productType: target.productType, osVersion: target.osVersion,
                osBuild: target.osBuild, transport: target.transport),
            screen: await displays.flatMap(Screen.init),
            locale: await locale.map { $0.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 },
            runnerBuild: runnerBuildKey(runner?.info.xctestrunPath),
            app: installed,
            source: checkout
        )
    }

    /// The `<key>` of an xctestrun at `<runnerBuilds>/<key>/Build/Products/run-*.xctestrun`, nil without one.
    static func runnerBuildKey(_ xctestrunPath: String?) -> String? {
        guard let components = xctestrunPath.map({ URL(filePath: $0).pathComponents }), components.count >= 4,
            components.suffix(3).prefix(2) == ["Build", "Products"]
        else { return nil }
        return components[components.count - 4]
    }

    /// The HEAD commit of the git checkout at `directory` and whether it has changes.
    static func git(_ directory: URL) async throws -> Source {
        let revision = try await Shell.run(["git", "-C", directory.path, "rev-parse", "HEAD"], timeout: .seconds(30))
        let status = try await Shell.run(
            ["git", "--no-optional-locks", "-C", directory.path, "status", "--porcelain", "--untracked-files=normal"],
            timeout: .seconds(30))
        guard revision.succeeded, status.succeeded else {
            throw DeviceLoopError(
                .badArguments, "\(directory.path) is not a git checkout with a commit.", fix: "Pass a git checkout as the source.",
                detail: (revision.succeeded ? status : revision).stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Source(revision: revision.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), dirty: !status.stdout.isEmpty)
    }
}

extension RunProvenance.Screen {
    /// The visible display of `displays`. A device lying flat keeps the orientation it had when last upright.
    init?(_ displays: DeviceDisplays) {
        guard let visible = displays.visible else { return nil }
        self.init(
            pointWidth: visible.pointWidth, pointHeight: visible.pointHeight, scale: visible.pointScale,
            orientation: displays.nonFlatOrientation ?? displays.orientation)
    }
}

/// One line of `events.jsonl`.
public struct RunEvent: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        case ok
        case error
        case cancelled
    }

    /// 1 for the first event of the run.
    public var seq = 0
    /// Wall time in ISO 8601 with milliseconds.
    public var time = ""
    /// Seconds since the run was created, on the host clock.
    public var offset = 0.0
    public var kind: String
    public var command: String
    public var args: JSONValue
    /// On a finished event, the seq of the started event it closes.
    public var started: Int?
    public var outcome: Outcome?
    public var error: DeviceLoopError?
    /// Relative to the run directory.
    public var artifacts: [String]

    /// `RunStore.append` sets `seq`, `time` and `offset`.
    public init(
        kind: String, command: String, args: JSONValue = .null, started: Int? = nil, outcome: Outcome? = nil,
        error: DeviceLoopError? = nil, artifacts: [String] = []
    ) {
        self.kind = kind
        self.command = command
        self.args = args
        self.started = started
        self.outcome = outcome
        self.error = error
        self.artifacts = artifacts
    }
}

/// One run in `run list`.
public struct RunSummary: Codable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var status: RunManifest.Status
    public var outcome: RunManifest.Outcome?
    public var createdAt: String
    /// Bytes of every file in the run.
    public var bytes: Int
    /// The error code of the first failed command, `cancelled`, or `not_finished` for a command without a finished event.
    public var failure: String?
    /// The commands on a device record into it.
    public var active: Bool
}

/// A run directory under `Paths.runs` with `manifest.json`, `events.jsonl` and `artifacts/`.
public struct RunStore: Sendable {
    /// The run the current task records into. `Paths.artifacts` points into it while set.
    @TaskLocal public static var current: RunStore?

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var id: String { directory.lastPathComponent }
    public var artifacts: URL { directory.appending(path: "artifacts", directoryHint: .isDirectory) }
    var manifestURL: URL { directory.appending(path: "manifest.json") }
    var eventsURL: URL { directory.appending(path: "events.jsonl") }
    var lockURL: URL { directory.appending(path: "events.lock") }

    /// The run `id` under `runs`.
    public static func named(_ id: String, in runs: URL = Paths.runs) throws -> RunStore {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else {
            throw DeviceLoopError(.badArguments, "\(id) is not a run ID.", fix: "Pass a run ID such as run-20261108-131927-3f9a2c.")
        }
        return RunStore(directory: runs.appending(path: id, directoryHint: .isDirectory))
    }

    /// `<prefix>-<yyyyMMdd-HHmmss>-<suffix>` for the current time.
    static func newID(_ prefix: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "\(prefix)-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6).lowercased())"
    }

    /// Creates `Paths.runs/run-<yyyyMMdd-HHmmss>-<suffix>` with a running manifest, owned by this process when `owned`.
    public static func create(provenance: RunProvenance? = nil, name: String? = nil, owned: Bool = true) throws -> RunStore {
        let id = newID("run")
        do {
            let run = RunStore(directory: try Paths.ensureDirectory(Paths.runs).appending(path: id, directoryHint: .isDirectory))
            try FileManager.default.createDirectory(
                at: run.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let owner = owned ? RunManifest.Owner(pid: getpid(), pidStart: Recorder.processStart(getpid())) : nil
            try run.write(
                RunManifest(
                    id: id, name: name, status: .running, createdAt: timestamp(), hostStart: hostNow(), owner: owner,
                    provenance: provenance))
            return run
        } catch {
            throw DeviceLoopError(
                .internalError, "Could not create a run.", fix: "Check free space and write permissions at \(Paths.runs.path).",
                detail: error.localizedDescription)
        }
    }

    /// The manifest. A running run whose owner process has exited reads as `incomplete`.
    public func manifest() throws -> RunManifest {
        guard let contents = try? Data(contentsOf: manifestURL), var manifest = try? JSONDecoder().decode(RunManifest.self, from: contents)
        else {
            throw DeviceLoopError(.badArguments, "No readable run manifest at \(manifestURL.path).", fix: "Pass the ID of an existing run.")
        }
        if manifest.status == .running, let owner = manifest.owner,
            owner.pidStart == nil || Recorder.processStart(owner.pid) != owner.pidStart
        {
            manifest.status = .incomplete
        }
        return manifest
    }

    /// The journal in order. A line that does not decode, such as one cut short by a crash, is skipped with a warning.
    public func events() throws -> (events: [RunEvent], warnings: [String]) {
        guard FileManager.default.fileExists(atPath: eventsURL.path) else { return ([], []) }
        do {
            return Self.parse(try Data(contentsOf: eventsURL))
        } catch {
            throw DeviceLoopError(
                .internalError, "Could not read \(eventsURL.path).", fix: "Check its permissions.", detail: error.localizedDescription)
        }
    }

    /// Holds `events.lock`, or throws device_busy naming the run after `timeout`.
    func lockJournal(timeout: Duration = .seconds(10)) async throws -> SessionLock {
        do {
            return try await SessionLock.acquire(at: lockURL, timeout: timeout)
        } catch let error as DeviceLoopError where error.code == .deviceBusy {
            throw DeviceLoopError(
                .deviceBusy, "Another DeviceLoop command is writing to run \(id).", fix: "Wait for it to finish, then retry.")
        }
    }

    /// Appends `event` under the journal lock with the next seq, the wall time and the host clock offset.
    /// Returns the written event, or the failure to report as a warning instead of failing the command.
    /// A finished run takes no more events.
    public func append(_ event: RunEvent, timeout: Duration = .seconds(10)) async -> Result<RunEvent, DeviceLoopError> {
        do {
            let lock = try await lockJournal(timeout: timeout)
            defer { lock.release() }
            let manifest = try manifest()
            guard manifest.status != .finished else {
                return .failure(
                    DeviceLoopError(
                        .badArguments, "Run \(id) is finished, so \(event.command) was not journaled.",
                        fix: "Record into a run that is still running."))
            }
            if !FileManager.default.fileExists(atPath: eventsURL.path) {
                guard FileManager.default.createFile(atPath: eventsURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let existing = try Data(contentsOf: eventsURL)
            var written = event
            written.seq = (Self.parse(existing).events.map(\.seq).max() ?? 0) + 1
            written.time = Self.timestamp()
            written.offset = VideoAnalyzer.seconds(hostNow() - manifest.hostStart)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var line = try encoder.encode(written)
            line.append(UInt8(ascii: "\n"))
            // Starts a new line after one cut short by a crash.
            if let last = existing.last, last != UInt8(ascii: "\n") { line.insert(UInt8(ascii: "\n"), at: 0) }
            let handle = try FileHandle(forWritingTo: eventsURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            return .success(written)
        } catch let error as DeviceLoopError where error.code == .deviceBusy {
            return .failure(
                DeviceLoopError(
                    .deviceBusy, "Another DeviceLoop command is writing to run \(id), so \(event.command) was not journaled.",
                    fix: error.fix))
        } catch {
            return .failure(
                DeviceLoopError(
                    .internalError, "Could not journal \(event.command) in run \(id).",
                    fix: "Check free space and write permissions at \(directory.path).", detail: error.localizedDescription))
        }
    }

    /// Files that `finalize` does not hash.
    static let unhashed = ["manifest.json", "events.lock", "report.html"]

    /// Marks the run finished with its outcome and records the size and SHA256 of every file except `unhashed`.
    @discardableResult
    public func finalize(timeout: Duration = .seconds(10)) async throws -> RunManifest {
        let lock = try await lockJournal(timeout: timeout)
        defer { lock.release() }
        var manifest = try manifest()
        do {
            manifest.files = try Self.inventory(directory, skipping: Self.unhashed)
            manifest.outcome = Self.firstFailure(try events().events) == nil ? .passed : .failed
            manifest.status = .finished
            manifest.finishedAt = Self.timestamp()
            try write(manifest)
            return manifest
        } catch {
            throw DeviceLoopError(
                .internalError, "Could not finalize run \(id).", fix: "Check free space and write permissions at \(directory.path).",
                detail: error.localizedDescription)
        }
    }

    /// Size and SHA256 of every regular file under `directory` except the paths in `skipping`, sorted by relative path.
    static func inventory(_ directory: URL, skipping: [String] = []) throws -> [RunManifest.File] {
        var files: [RunManifest.File] = []
        for path in try FileManager.default.subpathsOfDirectory(atPath: directory.path).sorted() where !skipping.contains(path) {
            let url = directory.appending(path: path)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let contents = try Data(contentsOf: url, options: .alwaysMapped)
            let digest = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
            files.append(RunManifest.File(path: path, bytes: contents.count, sha256: digest))
        }
        return files
    }

    /// Every run under `runs`, newest first, with a warning for each folder without a readable manifest.
    public static func list(in runs: URL = Paths.runs) -> (runs: [RunSummary], warnings: [String]) {
        let active = RunRecorder.activeIDs(in: runs)
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: runs, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        var listed: [(created: Date, summary: RunSummary)] = []
        var warnings: [String] = []
        for folder in folders where !["active", "comparisons"].contains(folder.lastPathComponent) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let run = RunStore(directory: folder)
            guard let manifest = try? run.manifest(), let created = date(manifest.createdAt) else {
                warnings.append("\(folder.lastPathComponent) has no readable manifest and was skipped.")
                continue
            }
            let failure = firstFailure((try? run.events().events) ?? [])
            let code: String? =
                switch failure?.outcome {
                    case .error?: failure?.error?.code.rawValue ?? "error"
                    case .cancelled?: "cancelled"
                    case .ok?, nil: failure != nil && manifest.status != .running ? "not_finished" : nil
                }
            let summary = RunSummary(
                id: run.id, name: manifest.name, status: manifest.status, outcome: manifest.outcome, createdAt: manifest.createdAt,
                bytes: run.bytes(), failure: code, active: active.contains(run.id))
            listed.append((created, summary))
        }
        listed.sort { ($0.created, $0.summary.id) > ($1.created, $1.summary.id) }
        return (listed.map(\.summary), warnings)
    }

    /// Removes the runs under `runs` that are not among the `keep` newest and were created more than `days` days ago.
    /// Active runs stay. Returns the removed runs and a warning for each folder it skipped or could not remove.
    public static func prune(keep: Int?, olderThan days: Int?, in runs: URL = Paths.runs) throws -> (
        removed: [RunSummary], warnings: [String]
    ) {
        guard keep != nil || days != nil else {
            throw DeviceLoopError(.badArguments, "Prune needs --older-than or --keep.", fix: "Pass --older-than DAYS, --keep N or both.")
        }
        guard (keep ?? 0) >= 0, (days ?? 0) >= 0 else {
            throw DeviceLoopError(.badArguments, "--older-than and --keep take 0 or more.", fix: "Pass a count of days or runs.")
        }
        let cutoff = Date().addingTimeInterval(-Double(days ?? 0) * 86_400)
        let listing = list(in: runs)
        var warnings = listing.warnings
        var removed: [RunSummary] = []
        for (index, run) in listing.runs.enumerated() where !run.active && index >= (keep ?? 0) {
            if days != nil, let created = date(run.createdAt), created >= cutoff { continue }
            do {
                try FileManager.default.removeItem(at: runs.appending(path: run.id, directoryHint: .isDirectory))
                removed.append(run)
            } catch {
                warnings.append("Could not remove \(run.id): \(error.localizedDescription)")
            }
        }
        return (removed, warnings)
    }

    /// Bytes of every file in the run.
    func bytes() -> Int {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        return (files?.allObjects as? [URL] ?? []).reduce(0) { total, file in
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return total + (values?.isRegularFile == true ? values?.fileSize ?? 0 : 0)
        }
    }

    /// The first finished event that is not ok, or the first started event without a finished event.
    static func firstFailure(_ events: [RunEvent]) -> RunEvent? {
        let closed = Set(events.compactMap(\.started))
        return events.first { $0.kind == "finished" ? $0.outcome != .ok : $0.kind == "started" && !closed.contains($0.seq) }
    }

    func write(_ manifest: RunManifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try Paths.writePrivate(try encoder.encode(manifest), to: manifestURL)
    }

    static func parse(_ journal: Data) -> (events: [RunEvent], warnings: [String]) {
        var events: [RunEvent] = []
        var warnings: [String] = []
        let lines = journal.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() where !line.isEmpty {
            if let event = try? JSONDecoder().decode(RunEvent.self, from: Data(line)) {
                events.append(event)
            } else {
                warnings.append("events.jsonl line \(index + 1) is not a complete event and was skipped.")
            }
        }
        return (events, warnings)
    }

    static func timestamp() -> String {
        Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    /// Parses a `timestamp()`.
    static func date(_ timestamp: String) -> Date? {
        try? Date(timestamp, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}
