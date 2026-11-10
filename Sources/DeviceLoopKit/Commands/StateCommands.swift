//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

public enum StateCommands {
    /// `deviceloop state inspect`: observed values, then the fields not observed and why.
    public static func inspect(_ target: Target) async throws -> CommandResult {
        try inspect(target, state: await DeviceState.capture(target))
    }

    /// Lists the pending changes of an open scope after the fields, and in `pendingChanges`.
    static func inspect(_ target: Target, state: DeviceState) throws -> CommandResult {
        let names = state.fields.keys.sorted()
        let observed = names.filter { state.fields[$0]?.availability == .observed }
        let missing = names.filter { state.fields[$0]?.availability != .observed }
        var lines = [target.summary, "\(observed.count) observed, \(missing.count) not observed"]
        lines += ParityText.table(observed.map { [$0 + ":", text(state.fields[$0]?.value)] })
        if !missing.isEmpty {
            lines.append("not observed:")
            lines += ParityText.table(
                missing.compactMap { name in
                    state.fields[name].map { [name + ":", $0.availability.rawValue + ",", $0.reason ?? "no reason recorded"] }
                })
        }
        var json = try JSONValue(encoding: state)
        let journal = ChangeJournal(udid: target.udid)
        if journal.isOpen {
            let changes = (try? journal.lines()).map { ChangeJournal.pending($0.entries) }
            lines.append(
                changes.map { "\($0.count) pending change\($0.count == 1 ? "" : "s") at \(journal.file.path)" }
                    ?? "Could not read the pending changes at \(journal.file.path)")
            lines += (changes ?? []).map(ChangeJournal.describe)
            if case .object(var payload) = json, let changes {
                payload["pendingChanges"] = try JSONValue(encoding: changes)
                json = .object(payload)
            }
        }
        return CommandResult(text: lines.joined(separator: "\n"), json: json)
    }

    /// `deviceloop state capture`: saves the state with mode 0600 to `output`, by default under `Paths.home/state/<udid>/`.
    /// Refuses an `output` that exists.
    public static func capture(_ target: Target, output: URL?) async throws -> CommandResult {
        if let output, FileManager.default.fileExists(atPath: output.path) { throw exists(output) }
        let state = await DeviceState.capture(target)
        let file =
            output ?? Paths.home.appending(path: "state/\(target.udid)/\(state.capturedAt.replacingOccurrences(of: ":", with: "")).json")
        try write(state, to: file, replace: false)
        let missing = state.fields.keys.sorted().filter { state.fields[$0]?.availability != .observed }
        let saved = "Saved \(state.fields.count) fields, \(missing.count) not observed"
        return CommandResult(
            text: [target.summary, saved + (missing.isEmpty ? "" : ": " + missing.joined(separator: ", ")), file.path]
                .joined(separator: "\n"),
            json: ["path": .string(file.path), "state": try JSONValue(encoding: state)],
            files: [file]
        )
    }

    /// `deviceloop state diff A B`: compares two captures of one target.
    public static func diff(_ before: URL, _ after: URL) throws -> CommandResult {
        let old = try load(before)
        let new = try load(after)
        let name = new.fields["name"]?.value?.string.map { "\($0) " } ?? ""
        return try render(StateDiff.compare(old, new), header: "\(name)(\(new.udid))")
    }

    /// `deviceloop state diff A --live`: compares a capture with a new read of `device`, by default the captured target.
    public static func diff(_ before: URL, live device: String?) async throws -> CommandResult {
        let old = try load(before)
        let target = try await TargetResolver.resolve(device ?? old.udid)
        let new = await DeviceState.capture(target)
        return try render(StateDiff.compare(old, new), header: target.summary)
    }

    /// `deviceloop state scope start`: opens the change journal of `target` with a baseline capture.
    public static func scopeStart(_ target: Target, strict: Bool) async throws -> CommandResult {
        let journal = ChangeJournal(udid: target.udid)
        let scope = try await journal.start(strict: strict) { await DeviceState.capture(target) }
        let missing = scope.baseline.fields.values.filter { $0.availability != .observed }.count
        return CommandResult(
            text: [
                target.summary,
                "Scope open\(strict ? ", strict" : ""), baseline of \(scope.baseline.fields.count) fields, \(missing) not observed",
                journal.file.path,
            ].joined(separator: "\n"),
            json: [
                "path": .string(journal.file.path), "startedAt": .string(scope.at), "strict": .bool(strict),
                "baseline": try JSONValue(encoding: scope.baseline),
            ],
            files: [journal.file]
        )
    }

    /// `deviceloop state scope status`: whether a scope is open on `target`, and each change journaled in it.
    public static func scopeStatus(_ target: Target) throws -> CommandResult {
        let journal = ChangeJournal(udid: target.udid)
        guard journal.isOpen else {
            return CommandResult(text: "\(target.summary)\nNo scope open", json: ["open": false, "path": .string(journal.file.path)])
        }
        let (scope, entries) = try journal.lines()
        let changes = ChangeJournal.changes(entries)
        let changeCount = changes.count
        var lines = [
            target.summary,
            "Scope open since \(scope.at)\(scope.strict ? ", strict" : ""), \(changeCount) change\(changeCount == 1 ? "" : "s"), "
                + journal.file.path,
        ]
        lines += changes.map(ChangeJournal.describe)
        return CommandResult(
            text: lines.joined(separator: "\n"),
            json: [
                "open": true, "path": .string(journal.file.path), "startedAt": .string(scope.at), "strict": .bool(scope.strict),
                "changes": try JSONValue(encoding: changes),
            ]
        )
    }

    /// `deviceloop state restore`: sets the changes of the open scope back, newest first. `clearLocation` clears the simulated
    /// location for each location change an earlier restore did not clear. Throws `cleanup_incomplete` with the per-change
    /// report unless each one is restored, unchanged or cleared, or `acceptResidual` is set.
    public static func restore(
        _ target: Target, dryRun: Bool, overwriteConflicts: Bool, acceptResidual: Bool, clearLocation: Bool
    ) async throws -> CommandResult {
        let clear: (() async throws -> Void)? =
            clearLocation ? { _ = try await Devicectl.run(Devicectl.device(target, "simulate", "location", "clear"), target: target) } : nil
        return try await restore(
            target, journal: ChangeJournal(udid: target.udid), dryRun: dryRun, overwriteConflicts: overwriteConflicts,
            acceptResidual: acceptResidual, clearLocation: clear
        ) { SettingsCommands.inverse($0, on: target) }
    }

    static func restore(
        _ target: Target,
        journal: ChangeJournal,
        dryRun: Bool,
        overwriteConflicts: Bool,
        acceptResidual: Bool,
        clearLocation: (() async throws -> Void)? = nil,
        inverse: (String) -> ChangeJournal.Inverse?
    ) async throws -> CommandResult {
        guard journal.isOpen else {
            return CommandResult(
                text: "\(target.summary)\nNo scope open, nothing to restore", json: ["open": false, "path": .string(journal.file.path)])
        }
        let cleanup = try await journal.restore(
            target, dryRun: dryRun, overwriteConflicts: overwriteConflicts, acceptResidual: acceptResidual,
            clearLocation: clearLocation, inverse: inverse)
        var counts: [ChangeJournal.Cleanup.Outcome: Int] = [:]
        for change in cleanup.changes { counts[change.outcome, default: 0] += 1 }
        let tally = counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.value) \($0.key.rawValue)" }.joined(separator: ", ")
        let report = cleanup.changes.map { "\($0.field): \($0.outcome.rawValue), \($0.reason) (\($0.id))" }
        let changeCount = cleanup.changes.count
        let countLine =
            "\(changeCount) change\(changeCount == 1 ? "" : "s")\(dryRun ? ", dry run" : "")\(tally.isEmpty ? "" : ": " + tally)"
        var lines = [target.summary, countLine]
        lines += report
        lines.append(cleanup.closed ? "Scope closed, journal moved to \(cleanup.journal)" : "Scope open at \(cleanup.journal)")
        if !dryRun { lines.append(journal.cleanupFile.path) }

        guard dryRun || cleanup.clean || acceptResidual else {
            let left = cleanup.changes.filter { !$0.outcome.settled }
            throw DeviceLoopError(
                .cleanupIncomplete,
                "Restore left \(left.count) of \(changeCount) change\(changeCount == 1 ? "" : "s") on \(target.summary), "
                    + "see \(journal.cleanupFile.path).",
                fix: restoreFix(left, on: target), detail: report.joined(separator: "\n"), device: target.name)
        }
        return try CommandResult(
            text: lines.joined(separator: "\n"), json: JSONValue(encoding: cleanup), files: dryRun ? [] : [journal.cleanupFile])
    }

    /// The fix line for a restore that left the `left` changes unsettled.
    private static func restoreFix(_ left: [ChangeJournal.Cleanup.Change], on target: Target) -> String {
        let outcomes = Set(left.map(\.outcome))
        if outcomes.contains(.needsOwnerAction) {
            return "\(target.isSimulator ? "Boot" : "Connect and unlock") \(target.name), then run "
                + "`deviceloop state restore --device \(target.udid)` again."
        }
        if outcomes.contains(.conflict) {
            return "Run it again with --overwrite-conflicts to set them back anyway, or --accept-residual to close the scope as it is."
        }
        guard left.contains(where: { $0.field == "location" && $0.outcome == .unsupported }) else {
            return "Run it again with --accept-residual to close the scope and leave these fields as they are."
        }
        if left.allSatisfy({ $0.field == "location" }) {
            return "Run it again with --clear-location to clear the simulated location, or --accept-residual to leave "
                + "these fields as they are."
        }
        return "Run it again with --clear-location --accept-residual to clear the simulated location and leave the "
            + "other fields as they are, or --accept-residual to leave all of them."
    }

    static func render(_ diff: StateDiff, header: String) throws -> CommandResult {
        let names = diff.fields.keys.sorted()
        let changed = names.filter { diff.fields[$0]?.status == .changed }
        let unknown = names.filter { diff.fields[$0]?.status == .unknown }
        var lines = [
            header,
            "\(diff.beforeCapturedAt) -> \(diff.afterCapturedAt): \(changed.count) changed, "
                + "\(names.count - changed.count - unknown.count) unchanged, \(unknown.count) unknown",
        ]
        for name in changed {
            guard let change = diff.fields[name] else { continue }
            lines.append(
                "\(name): \(text(change.before)) -> \(text(change.after)) (\(change.source) at \(change.observedAt ?? "unknown time"))")
        }
        if !unknown.isEmpty { lines.append("unknown: " + unknown.joined(separator: ", ")) }
        return try CommandResult(text: lines.joined(separator: "\n"), payload: diff)
    }

    static func load(_ file: URL) throws -> DeviceState {
        let state: DeviceState
        do {
            state = try JSONDecoder().decode(DeviceState.self, from: Data(contentsOf: file))
        } catch {
            throw DeviceLoopError(
                .badArguments, "Could not read a state capture at \(file.path).",
                fix: "Pass a file written by `deviceloop state capture`.", detail: error.localizedDescription)
        }
        guard state.schema == "deviceloop.device-state/1" else {
            throw DeviceLoopError(
                .badArguments, "\(file.path) has schema \(state.schema), expected deviceloop.device-state/1.",
                fix: "Capture it again with this version of DeviceLoop.")
        }
        return state
    }

    /// Writes `value` to a 0600 temporary file and renames it into place. Without `replace`, throws if `file` exists.
    static func write(_ value: some Encodable, to file: URL, replace: Bool = true) throws {
        let directory = file.deletingLastPathComponent()
        do {
            let data = try JSONValue(encoding: value).data(pretty: true)
            try Paths.ensureDirectory(directory)
            let temporary = directory.appending(path: ".state-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let renamed = replace ? rename(temporary.path, file.path) : renamex_np(temporary.path, file.path, UInt32(RENAME_EXCL))
            guard renamed == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch POSIXError.EEXIST {
            throw exists(file)
        } catch {
            throw DeviceLoopError(
                .internalError, "Could not save \(file.path).",
                fix: "Check write permissions at \(directory.path).", detail: error.localizedDescription)
        }
    }

    static func exists(_ file: URL) -> DeviceLoopError {
        DeviceLoopError(.badArguments, "\(file.path) already exists.", fix: "Pass a new file name, or move the existing file first.")
    }

    /// Strings as they are, other values as JSON, nil as `none`.
    static func text(_ value: JSONValue?) -> String {
        guard let value else { return "none" }
        return value.string ?? String(decoding: (try? value.data()) ?? Data(), as: UTF8.self)
    }
}
