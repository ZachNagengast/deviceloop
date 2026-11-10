//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// Journals the commands sent to a device into the run that is active on it.
public enum RunRecorder {
    struct Pointer: Codable {
        var id: String
    }

    /// `runs/active/<udid>.json`, which names the run that commands on `udid` record into.
    static func pointer(_ udid: String, in runs: URL = Paths.runs) -> URL {
        runs.appending(path: "active/\(udid).json")
    }

    /// The run that commands on `udid` record into, or nil when there is none or it is finished.
    public static func active(_ udid: String, in runs: URL = Paths.runs) -> RunStore? {
        guard let data = try? Data(contentsOf: pointer(udid, in: runs)), let id = try? JSONDecoder().decode(Pointer.self, from: data).id,
            let run = try? RunStore.named(id, in: runs), let manifest = try? run.manifest(), manifest.status != .finished
        else { return nil }
        return run
    }

    /// IDs of the runs that commands on any device record into.
    static func activeIDs(in runs: URL) -> Set<String> {
        let pointers =
            (try? FileManager.default.contentsOfDirectory(
                at: runs.appending(path: "active", directoryHint: .isDirectory), includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles)) ?? []
        let udids = pointers.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }
        return Set(udids.compactMap { active($0, in: runs)?.id })
    }

    /// Points the commands on `udid` at `run`.
    static func activate(_ run: RunStore, on udid: String, in runs: URL = Paths.runs) throws {
        do {
            try Paths.writePrivate(try JSONEncoder().encode(Pointer(id: run.id)), to: pointer(udid, in: runs))
        } catch {
            throw DeviceLoopError(
                .internalError, "Could not make run \(run.id) active.", fix: "Check write permissions at \(runs.path).",
                detail: error.localizedDescription)
        }
    }

    /// Runs `body` inside the active run of `udid`, between a started event n and a finished event, saves the result JSON
    /// as `results/<n>.json`, copies result files from outside the run, and ends the text or error with `run <id> event <n>`.
    /// A returned flow-result that did not pass is journaled as an error or cancelled, and another result for which `failed`
    /// is true as an error. The strings in `hiding` are journaled as `[hidden]`. With `savingResult` false, `results/<n>.json`
    /// is not written.
    public static func record(
        _ udid: String?, command: String, args: JSONValue, hiding: [String] = [], savingResult: Bool = true,
        failed: (CommandResult) -> Bool = { _ in false }, _ body: () async throws -> CommandResult
    ) async throws -> CommandResult {
        guard let udid, let run = active(udid) else { return try await body() }
        let hidden = hiding.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        let started: RunEvent
        switch await run.append(RunEvent(kind: "started", command: command, args: hide(hidden, in: args))) {
            case .success(let event): started = event
            case .failure(let warning):
                do {
                    var result = try await body()
                    result.text += "\nwarning: \(warning.message)"
                    return result
                } catch {
                    throw DeviceLoopError.adding(detail: "warning: \(warning.message)", to: error)
                }
        }
        let tag = "run \(run.id) event \(started.seq)"
        var finished = RunEvent(kind: "finished", command: command, started: started.seq)
        do {
            var result = try await RunStore.$current.withValue(run) { try await body() }
            var lines = [tag]
            if savingResult {
                do {
                    let json = try hide(hidden, in: result.json).data(pretty: true)
                    try Paths.writePrivate(json, to: run.directory.appending(path: "results/\(started.seq).json"))
                } catch {
                    lines.append("warning: Could not save results/\(started.seq).json in run \(run.id): \(error.localizedDescription)")
                }
            }
            for file in result.files {
                do {
                    finished.artifacts.append(try keep(file, in: run, seq: started.seq))
                } catch {
                    lines.append("warning: Could not copy \(file.path) into run \(run.id): \(error.localizedDescription)")
                }
            }
            let (journaled, stopError) = outcome(of: result.json)
            finished.outcome = journaled == .ok && failed(result) ? .error : journaled
            finished.error = stopError.map { hide(hidden, in: $0) }
            if case .failure(let warning) = await close(finished, in: run) { lines.append("warning: \(warning.message)") }
            result.text = ([result.text] + lines).filter { !$0.isEmpty }.joined(separator: "\n")
            return result
        } catch is CancellationError {
            finished.outcome = .cancelled
            _ = await close(finished, in: run)
            throw CancellationError()
        } catch {
            let failure = error as? DeviceLoopError ?? DeviceLoopError(.internalError, "\(error)")
            finished.outcome = .error
            finished.error = hide(hidden, in: failure)
            var lines = [tag]
            if case .failure(let warning) = await close(finished, in: run) { lines.append("warning: \(warning.message)") }
            throw DeviceLoopError.adding(detail: lines.joined(separator: "\n"), to: failure)
        }
    }

    /// Error with the error of the first step that did not pass for a failed or cleanup_failed flow-result, cancelled for a
    /// cancelled one, otherwise ok.
    static func outcome(of result: JSONValue) -> (RunEvent.Outcome, DeviceLoopError?) {
        guard result["schema"] == "deviceloop.flow-result/1", let status = result["status"]?.string.flatMap(FlowResult.Status.init) else {
            return (.ok, nil)
        }
        switch status {
            case .passed: return (.ok, nil)
            case .cancelled: return (.cancelled, nil)
            case .failed, .cleanupFailed:
                let steps = (result["steps"]?.array ?? []) + (result["cleanup"]?.array ?? [])
                let stop = steps.first { $0["status"] != "passed" }
                return (.error, try? stop?["error"]?.decode(DeviceLoopError.self))
        }
    }

    /// Appends `event` from a new task, which is not cancelled when the caller is.
    static func close(_ event: RunEvent, in run: RunStore) async -> Result<RunEvent, DeviceLoopError> {
        await Task { await run.append(event) }.value
    }

    /// The path of `file` relative to `run`, after copying it into the run's artifacts as `<seq>-<name>` when it lives elsewhere.
    static func keep(_ file: URL, in run: RunStore, seq: Int) throws -> String {
        let root = run.directory.standardizedFileURL.path + "/"
        let path = file.standardizedFileURL.path
        if path.hasPrefix(root) { return String(path.dropFirst(root.count)) }
        let copy = try Paths.ensureDirectory(run.artifacts).appending(path: "\(seq)-\(file.lastPathComponent)")
        try FileManager.default.copyItem(at: file, to: copy)
        return "artifacts/\(copy.lastPathComponent)"
    }

    static func hide(_ hidden: [String], in error: DeviceLoopError) -> DeviceLoopError {
        var error = error
        error.message = hide(hidden, in: error.message)
        error.fix = error.fix.map { hide(hidden, in: $0) }
        error.detail = error.detail.map { hide(hidden, in: $0) }
        return error
    }

    static func hide(_ hidden: [String], in value: JSONValue) -> JSONValue {
        guard !hidden.isEmpty else { return value }
        switch value {
            case .string(let text): return .string(hide(hidden, in: text))
            case .array(let items): return .array(items.map { hide(hidden, in: $0) })
            case .object(let fields): return .object(fields.mapValues { hide(hidden, in: $0) })
            default: return value
        }
    }

    /// Replaces each occurrence of the strings in `hidden`, longest first, with `[hidden]` in one pass.
    static func hide(_ hidden: [String], in text: String) -> String {
        var output = ""
        var rest = Substring(text)
        while let first = rest.first {
            if let match = hidden.first(where: { rest.hasPrefix($0) }) {
                output += "[hidden]"
                rest = rest.dropFirst(match.count)
            } else {
                output.append(first)
                rest = rest.dropFirst()
            }
        }
        return output
    }
}
