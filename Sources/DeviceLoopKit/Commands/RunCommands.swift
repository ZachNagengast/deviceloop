//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// `deviceloop run`: records the commands sent to one device into a run folder.
public enum RunCommands {
    /// Creates a run with the provenance of `target`, `app` and `source`, and records the commands on `target` into it.
    /// `owned` ties the run to this process, so it reads incomplete once the process exits.
    public static func start(
        _ target: Target, name: String?, app: String?, source: URL?, version: String, owned: Bool
    ) async throws -> CommandResult {
        if let run = RunRecorder.active(target.udid) {
            throw DeviceLoopError(
                .badArguments, "Run \(run.id) is already recording \(target.name).", fix: "Stop it with run stop, then start again.",
                device: target.name)
        }
        let provenance = try await RunProvenance.collect(target, version: version, app: app, source: source)
        let run = try RunStore.create(provenance: provenance, name: name, owned: owned)
        try RunRecorder.activate(run, on: target.udid)
        return CommandResult(
            text: "\(target.summary)\nrun \(run.id) started\nsaved \(run.directory.path)",
            json: ["id": .string(run.id), "path": .string(run.directory.path)])
    }

    /// Finalizes the active run of `target`, stops recording and returns its report.
    public static func stop(_ target: Target) async throws -> CommandResult {
        guard let run = RunRecorder.active(target.udid) else {
            throw DeviceLoopError(
                .badArguments, "No run is recording \(target.name).", fix: "Start one with run start.", device: target.name)
        }
        try await run.finalize()
        try? FileManager.default.removeItem(at: RunRecorder.pointer(target.udid))
        let page = Result { try RunReport.write(run) }
        var result = try report(run, header: target.summary, page: try? page.get())
        if case .failure(let error) = page { result.text += "\nwarning: \((error as? DeviceLoopError)?.message ?? "\(error)")" }
        return result
    }

    /// The report of the active run of `target`.
    public static func status(_ target: Target) throws -> CommandResult {
        guard let run = RunRecorder.active(target.udid) else {
            return CommandResult(text: "\(target.summary)\nno run recording", json: ["manifest": .null])
        }
        return try report(run, header: target.summary)
    }

    /// The report of run `id`.
    public static func show(_ id: String) throws -> CommandResult {
        try report(try RunStore.named(id), header: "run \(id)")
    }

    /// Renders `report.html` of run `id` again.
    public static func renderReport(_ id: String) throws -> CommandResult {
        let page = try RunReport.write(try RunStore.named(id))
        return CommandResult(
            text: "run \(id)\nreport \(page.path)", json: ["id": .string(id), "report": .string(page.path)], files: [page])
    }

    /// Every run in `runs`, newest first, with its status, first failure and size.
    public static func list(in runs: URL = Paths.runs) throws -> CommandResult {
        let listing = RunStore.list(in: runs)
        var lines = ["\(listing.runs.count) run\(listing.runs.count == 1 ? "" : "s") in \(runs.path)"]
        for run in listing.runs {
            var line = "\(run.id)\(run.name.map { " \"\($0)\"" } ?? "") \(run.status.rawValue)"
            if let outcome = run.outcome { line += ", \(outcome.rawValue)" }
            if let failure = run.failure { line += ", \(failure)" }
            line += ", \(megabytes(run.bytes)) MB"
            if run.active { line += ", active" }
            lines.append(line)
        }
        lines += listing.warnings.map { "warning: \($0)" }
        return CommandResult(
            text: lines.joined(separator: "\n"),
            json: ["runs": try JSONValue(encoding: listing.runs), "warnings": .array(listing.warnings.map(JSONValue.string))])
    }

    /// Removes the runs in `runs` that `RunStore.prune` selects and reports the bytes it freed.
    public static func prune(keep: Int?, olderThan days: Int?, in runs: URL = Paths.runs) throws -> CommandResult {
        let pruned = try RunStore.prune(keep: keep, olderThan: days, in: runs)
        let freed = pruned.removed.reduce(0) { $0 + $1.bytes }
        var lines = ["pruned \(runs.path)"] + pruned.removed.map { "removed \($0.id), \(megabytes($0.bytes)) MB" }
        lines.append("freed \(megabytes(freed)) MB from \(pruned.removed.count) run\(pruned.removed.count == 1 ? "" : "s")")
        lines += pruned.warnings.map { "warning: \($0)" }
        return CommandResult(
            text: lines.joined(separator: "\n"),
            json: [
                "removed": .array(pruned.removed.map { .string($0.id) }), "freedBytes": .number(Double(freed)),
                "warnings": .array(pruned.warnings.map(JSONValue.string)),
            ])
    }

    /// Compares runs `baseline` and `candidate`, writes the comparison folder and lists the steps that changed.
    /// Each `ignore` is `id=<accessibility id>`, left out of the tree differences. Each `mask` is `x,y,w,h` in points, left
    /// out of the screenshot differences. A screenshot changed when more than `maxDiff` percent of its unmasked pixels
    /// changed, a timing when it differs by more than `minMs` or twice the recording's cadence slot.
    public static func compare(
        _ baseline: String, _ candidate: String, ignore: [String] = [], mask: [String] = [], maxDiff: Double = 0.1,
        minMs: Double = 50, in runs: URL = Paths.runs
    ) throws -> CommandResult {
        let ignoredIDs = try ignore.map { value in
            guard value.hasPrefix("id="), value.count > 3 else {
                throw DeviceLoopError(
                    .badArguments, "ignore takes id=<accessibility id>, got \(value).",
                    fix: "Pass the element's accessibility id after id=, for example id=fixture.counter.value.")
            }
            return String(value.dropFirst(3))
        }
        let masks = try mask.map { value in
            let fields = value.split(separator: ",", omittingEmptySubsequences: false)
            let rect = fields.compactMap { Double($0) }
            guard fields.count == 4, rect.count == 4, rect.allSatisfy(\.isFinite), rect[2] > 0, rect[3] > 0 else {
                throw DeviceLoopError(
                    .badArguments, "mask takes x,y,w,h in points with a positive width and height, got \(value).",
                    fix: "Pass four numbers, for example 0,0,430,54 for the status bar of a 430 pt wide screen.")
            }
            return rect
        }
        guard maxDiff.isFinite, (0 ... 100).contains(maxDiff) else {
            throw DeviceLoopError(.badArguments, "max-diff is a percent from 0 to 100, got \(maxDiff).", fix: "Pass for example 0.1.")
        }
        guard minMs.isFinite, minMs >= 0 else {
            throw DeviceLoopError(.badArguments, "min-ms is milliseconds of at least 0, got \(minMs).", fix: "Pass for example 50.")
        }
        let (comparison, directory) = try RunComparison.write(
            baseline: baseline, candidate: candidate, ignoring: ignoredIDs, masks: masks, maxDiffPercent: maxDiff, minMs: minMs,
            in: runs)
        let steps = comparison.steps
        var changes = [RunComparison.Change.regressed, .fixed, .changed].map { change in
            "\(steps.filter { $0.change == change }.count) \(change.rawValue)"
        }
        let counts = [
            ("tree", steps.filter { $0.tree?.differs == true }.count),
            ("screenshot", steps.filter { $0.screenshot?.verdict == .changed }.count),
            ("timing", steps.filter { $0.timing?.contains { $0.status == .changed } == true }.count),
        ]
        changes += counts.map { noun, count in "\(count) \(noun)\(count == 1 ? "" : "s") changed" }
        var lines = [
            "comparison \(comparison.id) \(comparison.verdict.rawValue), \(steps.count) step\(steps.count == 1 ? "" : "s"): "
                + changes.joined(separator: ", ")
        ]
        for (label, run) in [("baseline", comparison.baseline), ("candidate", comparison.candidate)] {
            var line = "\(label) \(run.id)\(run.name.map { " \"\($0)\"" } ?? "") \(run.status.rawValue)"
            if let outcome = run.outcome { line += ", \(outcome.rawValue)" }
            var values: [String: String] = [:]
            for field in comparison.fields { values[field.name] = label == "baseline" ? field.baseline : field.candidate }
            line += ", app \(values["app", default: ""]) \(values["appVersion", default: ""]) (\(values["appBuild", default: ""]))"
            line += ", source \(values["source", default: ""])"
            lines.append(line)
        }
        lines += comparison.reasons.map { "inconclusive: \($0)" }
        lines += comparison.warnings.map { "warning: \($0)" }
        for step in comparison.steps
        where step.differs || step.argumentsDiffer || step.fragile || step.screenshot?.verdict == .inconclusive || step.timing != nil {
            var line = "step \(step.index) \(step.command)\(words(step.baseline.args)): \(step.change.rawValue)"
            if step.argumentsDiffer { line += ", arguments differ, candidate\(words(step.candidate.args))" }
            if step.fragile { line += ", @eN ref is fragile" }
            if step.tree?.differs == true { line += ", tree changed" }
            if let screenshot = step.screenshot, screenshot.verdict != .same { line += ", screenshot \(screenshot.verdict.rawValue)" }
            if step.timing?.contains(where: { $0.status == .changed }) == true { line += ", timing changed" }
            line += ", baseline event \(step.baseline.seq) \(step.baseline.outcome)"
            line += ", candidate event \(step.candidate.seq) \(step.candidate.outcome)"
            lines.append(line)
            if let tree = step.tree, tree.differs { lines += tree.lines.map { "  " + $0 } }
            if let screenshot = step.screenshot, screenshot.verdict == .changed {
                lines.append("  " + screenshot.line)
                if let image = screenshot.image { lines.append("  diff \(directory.appending(path: image).path)") }
            }
            lines += (step.timing ?? []).map { "  " + $0.line }
        }
        let page = directory.appending(path: "comparison.html")
        lines += ["saved \(directory.path)", "report \(page.path)"]
        var json = try JSONValue(encoding: comparison).object ?? [:]
        json["path"] = .string(directory.path)
        json["report"] = .string(page.path)
        return CommandResult(text: lines.joined(separator: "\n"), json: .object(json), files: [page])
    }

    /// Exports run `id`, or comparison `comparison` and its two runs, into the new folder `out` to attach to a bug report.
    /// Names, UDIDs, teams, tokens and the home path become aliases, and typed text and pasteboard contents are hidden
    /// unless `keepTypedText`. Without `media`, images and videos are left out. With `zip`, also writes `<out>.zip`.
    public static func export(
        _ id: String?, comparison: String?, to out: URL, media: Bool, keepTypedText: Bool, zip: Bool
    ) async throws -> CommandResult {
        try RunExport.checkArguments(run: id, comparison: comparison, to: out, zip: zip)
        async let signing = SigningState.read()
        async let targets = try? Devicectl.listTargets()
        var redactor = SupportExport.redactor(
            home: FileManager.default.homeDirectoryForCurrentUser.path, targets: await targets ?? [], signing: await signing,
            storedTeam: DeviceLoopConfig.team())
        let export = try await RunExport.write(
            run: id, comparison: comparison, to: out, media: media, keepTypedText: keepTypedText, zip: zip, redactor: &redactor)
        let redacted = redactor.counts.values.reduce(0, +)
        let reportPath = out.appending(path: export.report).path
        var lines = [
            comparison.map { "comparison \($0)" } ?? "run \(id ?? "")",
            "exported \(export.files.count + 1) files, redacted \(redacted) values"
                + (keepTypedText ? ", kept typed text" : ", hid \(export.hidden) typed values"),
        ]
        lines += export.leftOut.map { "left out \($0)" }
        lines += [
            (media ? "Screenshots, videos and UI text are included as recorded." : "UI text is included as recorded.")
                + " Review every file before you share it.",
            "saved \(out.path)",
            "report \(reportPath)",
        ]
        if let archive = export.zip { lines.append("zip \(archive.path)") }
        return CommandResult(
            text: lines.joined(separator: "\n"),
            json: [
                "directory": .string(out.path), "report": .string(reportPath),
                "zip": export.zip.map { .string($0.path) } ?? .null, "files": try JSONValue(encoding: export.files),
                "leftOut": .array(export.leftOut.map(JSONValue.string)),
                "redactions": .object(redactor.counts.reduce(into: [:]) { $0[$1.key.rawValue] = .number(Double($1.value)) }),
                "hidden": keepTypedText ? .null : .number(Double(export.hidden)),
            ])
    }

    static func megabytes(_ bytes: Int) -> Double {
        (Double(bytes) / 100_000).rounded() / 10
    }

    /// One line per command with its outcome, error code or artifacts, and the path of `page` when given.
    /// The JSON holds the manifest, every event and `report`.
    static func report(_ run: RunStore, header: String, page: URL? = nil) throws -> CommandResult {
        let manifest = try run.manifest()
        let journal = try run.events()
        let commands = journal.events.filter { $0.kind == "started" }
        var finished: [Int: RunEvent] = [:]
        for event in journal.events { if let seq = event.started { finished[seq] = event } }
        var summary = "run \(manifest.id)\(manifest.name.map { " \"\($0)\"" } ?? "") \(manifest.status.rawValue)"
        if let outcome = manifest.outcome { summary += ", \(outcome.rawValue)" }
        summary += ", \(commands.count) command\(commands.count == 1 ? "" : "s")"
        var lines = [header, summary]
        for command in commands {
            let end = finished[command.seq]
            let outcome =
                switch end?.outcome {
                    case .ok?: (["ok"] + (end?.artifacts ?? [])).joined(separator: " ")
                    case .error?: "error \(end?.error?.code.rawValue ?? "")"
                    case .cancelled?: "cancelled"
                    case nil: "not finished"
                }
            lines.append("\(command.seq) \(command.command)\(words(command.args)): \(outcome)")
        }
        lines.append("saved \(run.directory.path)")
        if let page { lines.append("report \(page.path)") }
        lines += journal.warnings.map { "warning: \($0)" }
        return CommandResult(
            text: lines.joined(separator: "\n"),
            json: [
                "manifest": try JSONValue(encoding: manifest), "events": try JSONValue(encoding: journal.events),
                "warnings": .array(journal.warnings.map(JSONValue.string)), "report": page.map { .string($0.path) } ?? .null,
            ],
            files: page.map { [$0] } ?? [])
    }

    /// CLI words, or MCP arguments as sorted `key=value` pairs, each after a space.
    static func words(_ args: JSONValue) -> String {
        func word(_ value: JSONValue) -> String {
            value.string ?? String(decoding: (try? value.data()) ?? Data(), as: UTF8.self)
        }
        let parts: [String] =
            switch args {
                case .array(let items): items.map(word)
                case .object(let fields): fields.sorted { $0.key < $1.key }.map { "\($0.key)=\(word($0.value))" }
                default: []
            }
        return parts.map { " " + $0 }.joined()
    }
}
