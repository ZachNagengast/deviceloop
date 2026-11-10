//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// Write-ahead log of the setting changes DeviceLoop makes on one target while a state scope is open.
struct ChangeJournal: Sendable {
    let directory: URL

    /// `Paths.home/state/<udid>`.
    init(udid: String) {
        self.init(directory: Paths.home.appending(path: "state/\(udid)", directoryHint: .isDirectory))
    }

    init(directory: URL) {
        self.directory = directory
    }

    var file: URL { directory.appending(path: "changes.jsonl") }

    /// A scope is open while `changes.jsonl` exists.
    var isOpen: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// The first line of `changes.jsonl`.
    struct Scope: Codable, Sendable {
        var kind = "scope"
        var at: String
        var strict: Bool
        var baseline: DeviceState
    }

    /// Every later line of `changes.jsonl`. `change` and `applied` lines with the same `id` form one entry.
    struct Entry: Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            /// Written and fsynced before the setter runs.
            case change
            /// Written after the setter returns, with a re-read of the field. `state restore` appends another after setting
            /// the field back.
            case applied
        }

        var kind: Kind
        var id: String
        /// The `DeviceState` field name, for example `userInterfaceStyle`.
        var field: String
        var at: String
        /// `change` only.
        var original: Observation?
        /// `change` only.
        var requested: JSONValue?
        /// `applied` lines, and `change` lines returned by `changes(_:)` once their entry has one.
        var applied: Observation?

        /// A location change that `state restore --clear-location` cleared.
        var isClearedLocation: Bool { field == "location" && applied?.value == ["cleared": true] }
    }

    /// One read of a field. `value` is nil unless observed.
    struct Observation: Codable, Sendable, Equatable {
        var value: JSONValue?
        var availability: StateField.Availability
        var reason: String?
        var source: String
        var observedAt: String?
    }

    /// Writes the scope line with `baseline()` under the scope lock. Fails when a scope is already open.
    func start(strict: Bool, baseline: () async -> DeviceState) async throws -> Scope {
        let lock = try await lock()
        defer { lock.release() }
        guard !isOpen else {
            throw DeviceLoopError(
                .badArguments, "A state scope is already open at \(file.path).",
                fix: "Run `deviceloop state scope status` to see its changes.")
        }
        let scope = Scope(at: DeviceState.timestamp(), strict: strict, baseline: await baseline())
        try write {
            let temporary = directory.appending(path: ".changes-\(UUID().uuidString).jsonl")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try append(scope, to: temporary)
            guard rename(temporary.path, file.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return scope
    }

    /// Runs `dispatch`. While a scope is open, first appends a `change` line with `read()` as the original, and after
    /// `dispatch` returns, an `applied` line with a second `read()`. A strict scope refuses a change that is not `restorable`
    /// before `dispatch`.
    func record(
        field: String,
        requested: JSONValue,
        source: String,
        restorable: Bool = true,
        read: () async throws -> JSONValue?,
        dispatch: () async throws -> CommandResult
    ) async throws -> CommandResult {
        guard isOpen else { return try await dispatch() }
        let lock = try await lock()
        defer { lock.release() }
        guard isOpen else { return try await dispatch() }
        if !restorable {
            let scope = try lines().scope
            guard !scope.strict else {
                throw DeviceLoopError(
                    .unsupportedOnTarget,
                    "The strict state scope at \(file.path) refuses \(field) changes, which DeviceLoop cannot set back.",
                    fix:
                        "Run `deviceloop state restore --device \(scope.baseline.udid)` to close the scope, then start one without --strict."
                )
            }
        }

        let id = UUID().uuidString
        let original = await Self.observe(source, read)
        try write {
            try append(Entry(kind: .change, id: id, field: field, at: DeviceState.timestamp(), original: original, requested: requested))
        }
        var result = try await dispatch()
        let applied = await Self.observe(source, read)
        try write { try append(Entry(kind: .applied, id: id, field: field, at: DeviceState.timestamp(), applied: applied)) }

        result.text += "\nJournaled \(id): \(field) \(Self.text(original)) -> \(Self.text(applied)), \(file.path)"
        if case .object(var payload) = result.json {
            payload["journal"] = ["id": .string(id), "path": .string(file.path)]
            result.json = .object(payload)
        }
        result.files.append(file)
        return result
    }

    /// `record` for a field DeviceLoop cannot read, so restore cannot set it back. A permissive scope journals the original and
    /// applied values as unknown with `reason`.
    func record(
        field: String,
        requested: JSONValue,
        unreadable reason: String,
        dispatch: () async throws -> CommandResult
    ) async throws -> CommandResult {
        try await record(
            field: field, requested: requested, source: "none", restorable: false,
            read: { throw DeviceLoopError(.unsupportedOnTarget, reason) }, dispatch: dispatch)
    }

    var cleanupFile: URL { directory.appending(path: "cleanup.json") }

    /// Reads a journaled field and sets it back.
    struct Inverse {
        var read: () async throws -> JSONValue?
        var set: (JSONValue) async throws -> Void
    }

    /// `cleanup.json`: what `deviceloop state restore` did with each change, newest first.
    struct Cleanup: Codable, Sendable {
        enum Outcome: String, Codable, Sendable {
            case restored
            case unchanged
            case conflict
            case unknown
            case unsupported
            case needsOwnerAction
            case failed
            /// `--dry-run` only: restore would run the inverse setter.
            case wouldRestore
            /// `--clear-location` cleared the simulated location in this or an earlier restore. Its value before the scope is unknown.
            case cleared

            /// Restored, unchanged, or cleared on request.
            var settled: Bool { self == .restored || self == .unchanged || self == .cleared }
        }

        struct Change: Codable, Sendable {
            var id: String
            var field: String
            var outcome: Outcome
            var reason: String
            var original: JSONValue?
            /// The observed value of the `applied` line.
            var applied: JSONValue?
            /// Read before acting.
            var current: JSONValue?
            /// Read after the inverse setter.
            var verified: JSONValue?
        }

        var udid: String
        var startedAt: String
        var restoredAt: String
        var dryRun: Bool
        var closed: Bool
        /// `changes.jsonl`, or where it moved when the scope closed.
        var journal: String
        var changes: [Change]

        var clean: Bool { changes.allSatisfy(\.outcome.settled) }
    }

    /// Walks the changes newest first under the scope lock and sets each field back where it still holds the value DeviceLoop
    /// set, appending an `applied` line with the re-read. `clearLocation`, when given, runs for each location change not
    /// cleared yet and is journaled as an `applied` line of `["cleared": true]`. Writes `cleanup.json` and, when every change
    /// is settled or `acceptResidual` is set, closes the scope by moving `changes.jsonl` to `changes-<startedAt>.jsonl`.
    /// `dryRun` reads only and writes nothing.
    func restore(
        _ target: Target,
        dryRun: Bool,
        overwriteConflicts: Bool,
        acceptResidual: Bool,
        clearLocation: (() async throws -> Void)? = nil,
        inverse: (String) -> Inverse?
    ) async throws -> Cleanup {
        let lock = try await lock()
        defer { lock.release() }
        let (scope, entries) = try lines()
        guard scope.baseline.udid == target.udid else {
            throw DeviceLoopError(
                .badArguments, "The change journal at \(file.path) belongs to \(scope.baseline.udid), not \(target.udid).",
                fix: "Run `deviceloop state restore --device \(scope.baseline.udid)`.")
        }

        var simulated: [String: JSONValue] = [:]
        var conflicted: Set<String> = []
        func setBack(_ change: Entry, _ result: inout Cleanup.Change) async throws -> (Cleanup.Outcome, String) {
            if change.isClearedLocation { return (.cleared, "cleared by an earlier restore") }
            if change.field == "location", let clearLocation {
                guard target.isReady else { return (.needsOwnerAction, "\(target.name) is \(DeviceCommands.state(target))") }
                guard !dryRun else { return (.wouldRestore, "would clear the simulated location") }
                do {
                    try await clearLocation()
                } catch {
                    return Self.outcome(of: error, otherwise: .failed)
                }
                let cleared = Observation(
                    value: ["cleared": true], availability: .observed, source: "devicectl device simulate location clear",
                    observedAt: DeviceState.timestamp())
                let line = Entry(kind: .applied, id: change.id, field: change.field, at: DeviceState.timestamp(), applied: cleared)
                try write { try append(line) }
                return (.cleared, "cleared the simulated location, its value before the scope was not observed")
            }
            guard let inverse = inverse(change.field) else { return (.unsupported, "DeviceLoop cannot set \(change.field) back") }
            guard let original = change.original?.value else {
                return (.unknown, "the original was not observed: \(change.original?.reason ?? "no reading")")
            }
            guard target.isReady else { return (.needsOwnerAction, "\(target.name) is \(DeviceCommands.state(target))") }
            guard !conflicted.contains(change.field) else { return (.conflict, "a newer change of \(change.field) was left in place") }
            var reading = simulated[change.field]
            do {
                if reading == nil { reading = try await inverse.read() }
            } catch {
                return Self.outcome(of: error, otherwise: .unknown)
            }
            guard let current = reading else { return (.unknown, "\(change.original?.source ?? "the source") did not report it") }
            result.current = current
            let expected = change.applied?.value ?? change.requested
            if current == original && (change.applied?.value ?? original) == original {
                return (.unchanged, "already \(Self.text(change.original))")
            }
            if current != expected && !overwriteConflicts {
                conflicted.insert(change.field)
                return (.conflict, "now \(StateCommands.text(current)), DeviceLoop set \(StateCommands.text(expected))")
            }
            if dryRun {
                simulated[change.field] = original
                return (.wouldRestore, "would set \(StateCommands.text(current)) back to \(StateCommands.text(original))")
            }
            var setError: Error?
            do {
                try await inverse.set(original)
            } catch {
                setError = error
            }
            let verified = await Self.observe(change.original?.source ?? "the source", inverse.read)
            let line = Entry(kind: .applied, id: change.id, field: change.field, at: DeviceState.timestamp(), applied: verified)
            try write { try append(line) }
            result.verified = verified.value
            if let setError { return Self.outcome(of: setError, otherwise: .failed) }
            if verified.value == original {
                return (.restored, "set \(StateCommands.text(current)) back to \(StateCommands.text(original))")
            }
            return (.failed, "set \(StateCommands.text(original)), then read \(Self.text(verified))")
        }

        var results: [Cleanup.Change] = []
        for change in Self.changes(entries).reversed() {
            var result = Cleanup.Change(
                id: change.id, field: change.field, outcome: .unknown, reason: "", original: change.original?.value,
                applied: change.applied?.value)
            let (outcome, reason) = try await setBack(change, &result)
            result.outcome = outcome
            result.reason = reason
            results.append(result)
        }

        var cleanup = Cleanup(
            udid: target.udid, startedAt: scope.at, restoredAt: DeviceState.timestamp(), dryRun: dryRun, closed: false,
            journal: file.path, changes: results)
        guard !dryRun else { return cleanup }
        let closed = directory.appending(path: "changes-\(scope.at.replacingOccurrences(of: ":", with: "")).jsonl")
        if cleanup.clean || acceptResidual {
            cleanup.closed = true
            cleanup.journal = closed.path
        }
        try StateCommands.write(cleanup, to: cleanupFile)
        if cleanup.closed {
            try write { try FileManager.default.moveItem(at: file, to: closed) }
        }
        return cleanup
    }

    func lines() throws -> (scope: Scope, entries: [Entry]) {
        do {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            guard let first = lines.first else { throw CocoaError(.fileReadCorruptFile) }
            let decoder = JSONDecoder()
            return (
                try decoder.decode(Scope.self, from: Data(first.utf8)),
                try lines.dropFirst().map { try decoder.decode(Entry.self, from: Data($0.utf8)) }
            )
        } catch {
            throw DeviceLoopError(
                .internalError, "Could not read the change journal at \(file.path).",
                fix: "Move the file away to close the scope. Its changes are not restored.", detail: error.localizedDescription)
        }
    }

    /// `change` entries in order, each with the observation of its last `applied` line when there is one.
    static func changes(_ entries: [Entry]) -> [Entry] {
        var applied: [String: Observation] = [:]
        for entry in entries where entry.kind == .applied {
            applied[entry.id] = entry.applied
        }
        return entries.filter { $0.kind == .change }.map { entry in
            var change = entry
            change.applied = applied[entry.id]
            return change
        }
    }

    /// The changes whose last applied value is not their observed original, except cleared locations.
    static func pending(_ entries: [Entry]) -> [Entry] {
        changes(entries).filter { !$0.isClearedLocation && ($0.original?.value == nil || $0.applied?.value != $0.original?.value) }
    }

    /// `field: original -> requested, applied value (id)`, with `no applied line` when the setter failed or was interrupted.
    static func describe(_ change: Entry) -> String {
        let applied = change.applied.map { "applied \(text($0))" } ?? "no applied line"
        return "\(change.field): \(text(change.original)) -> \(StateCommands.text(change.requested)), \(applied) (\(change.id))"
    }

    /// The observed value, or `unknown`.
    static func text(_ observation: Observation?) -> String {
        observation?.value.map(StateCommands.text) ?? "unknown"
    }

    /// `needsOwnerAction` for an offline or locked target, `unsupported` for a missing capability, else `otherwise`, with the
    /// error message as the reason.
    private static func outcome(of error: Error, otherwise: Cleanup.Outcome) -> (Cleanup.Outcome, String) {
        guard let error = error as? DeviceLoopError else { return (otherwise, "\(error)") }
        switch error.code {
            case .deviceOffline, .deviceLocked: return (.needsOwnerAction, error.message)
            case .unsupportedOnTarget: return (.unsupported, error.message)
            default: return (otherwise, error.message)
        }
    }

    static func observe(_ source: String, _ read: () async throws -> JSONValue?) async -> Observation {
        do {
            guard let value = try await read() else {
                return Observation(availability: .unknown, reason: "\(source) did not report it", source: source)
            }
            return Observation(value: value, availability: .observed, source: source, observedAt: DeviceState.timestamp())
        } catch {
            return Observation(availability: .unknown, reason: (error as? DeviceLoopError)?.message ?? "\(error)", source: source)
        }
    }

    private func lock() async throws -> SessionLock {
        do {
            return try await SessionLock.acquire(at: directory.appending(path: "scope.lock"))
        } catch let error as DeviceLoopError where error.code == .deviceBusy {
            throw DeviceLoopError(
                .deviceBusy, "Another DeviceLoop command is using the state scope of this target.",
                fix: "Wait for it to finish, then retry.")
        }
    }

    /// Appends `line` and a newline to `url`, then fsyncs.
    private func append(_ line: some Encodable, to url: URL? = nil) throws {
        let handle = try FileHandle(forWritingTo: url ?? file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: try JSONValue(encoding: line).data() + Data("\n".utf8))
        try handle.synchronize()
    }

    private func write(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            throw DeviceLoopError(
                .internalError, "Could not write the change journal at \(file.path).",
                fix: "Check write permissions at \(directory.path).", detail: error.localizedDescription)
        }
    }
}
