//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import DeviceLoopProtocol
import Foundation

/// `comparison.json`: whether two runs have the same target, app and commands, and how each command's outcome changed.
public struct RunComparison: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable {
        case same
        /// A step regressed, was fixed or changed, or its UI trees, screenshots or timings differ.
        case different
        /// A gate field or the command sequence differs, see `reasons`.
        case inconclusive
    }

    public enum Change: String, Codable, Sendable {
        case same
        /// ok in the baseline, not ok in the candidate.
        case regressed
        /// Not ok in the baseline, ok in the candidate.
        case fixed
        /// Not ok on both sides with a different outcome.
        case changed
    }

    public struct Run: Codable, Sendable, Equatable {
        public var id: String
        public var name: String?
        public var status: RunManifest.Status
        public var outcome: RunManifest.Outcome?
    }

    /// One recorded property of both runs, `unknown` when a run did not record it.
    public struct Field: Codable, Sendable, Equatable {
        public var name: String
        public var baseline: String
        public var candidate: String
        /// A difference makes the comparison inconclusive.
        public var gate: Bool
    }

    /// One command of one run.
    public struct Command: Codable, Sendable, Equatable {
        /// Seq of the started event.
        public var seq: Int
        public var args: JSONValue
        /// `ok`, the error code, `cancelled` or `not_finished`.
        public var outcome: String
        /// Relative to the run: `results/<seq>.json` when it exists, then the artifacts of the finished event.
        public var files: [String]
    }

    /// One timing of two recordings of a step. Visual estimates from one capture per run, not calibrated.
    public struct Timing: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable {
            /// The values differ by more than `floorMs`, or only one recording has a value.
            case changed
            case withinDetectionFloor = "within_detection_floor"
        }

        public static let label = "visual estimate, single trial, capture not calibrated"

        /// `latency`, `animation`, `last change` or `visual gaps`, the total of the visual gap candidates.
        public var metric: String
        public var baselineMs: Double?
        public var candidateMs: Double?
        /// The larger of the minimum and twice the larger cadence slot of the two recordings.
        public var floorMs: Double
        public var status: Status
        public var note = Timing.label

        /// `animation 300 ms vs 600 ms, delta +300 ms, floor 50 ms: changed (visual estimate, ...)`.
        public var line: String {
            let values = [baselineMs, candidateMs].map { $0.map { "\(Self.ms($0)) ms" } ?? "none" }
            var line = "\(metric) \(values[0]) vs \(values[1])"
            if let baselineMs, let candidateMs {
                line += ", delta \(candidateMs >= baselineMs ? "+" : "")\(Self.ms(candidateMs - baselineMs)) ms"
            }
            let result = status == .changed ? "changed" : "within detection floor"
            return line + ", floor \(Self.ms(floorMs)) ms: \(result) (\(note))"
        }

        /// Latency, animation, last change and visual gap time of two animation reports. Values missing from both are left out.
        static func compare(_ baseline: AnimationReport, _ candidate: AnimationReport, minMs: Double) -> [Timing] {
            let floor = max(minMs, 2 * max(baseline.cadence.slotMs, candidate.cadence.slotMs))
            let metrics: [(name: String, value: (AnimationReport) -> Double?)] = [
                ("latency", { $0.response?.latencyMs }), ("animation", { $0.response?.animationMs }),
                ("last change", { $0.response?.lastChangeMs }), ("visual gaps", { $0.candidates.totalMs }),
            ]
            return metrics.compactMap { metric in
                let baselineMs = metric.value(baseline)
                let candidateMs = metric.value(candidate)
                if baselineMs == nil && candidateMs == nil { return nil }
                var status = Status.changed
                if let baselineMs, let candidateMs, abs(candidateMs - baselineMs) <= floor { status = .withinDetectionFloor }
                return Timing(metric: metric.name, baselineMs: baselineMs, candidateMs: candidateMs, floorMs: floor, status: status)
            }
        }

        static func ms(_ value: Double) -> String {
            ParityText.number((value * 10).rounded() / 10)
        }
    }

    public struct Step: Codable, Sendable, Equatable {
        /// 1 for the first command.
        public var index: Int
        public var command: String
        public var change: Change
        /// The arguments differ, leaving out the device and `--json`.
        public var argumentsDiffer: Bool
        /// An argument holds an `@eN` ref, which names whatever the latest `ui tree` numbered N.
        public var fragile: Bool
        public var baseline: Command
        public var candidate: Command
        /// The differences between the two UI trees, when both commands saved a `ui tree` result.
        public var tree: TreeDiff?
        /// The differences between the two screenshots, when both commands saved a `screenshot` result.
        public var screenshot: ImageDiff?
        /// The timings of the two recordings, when both commands saved an animation report.
        public var timing: [Timing]?

        /// The outcome, the tree, the screenshot or a timing changed.
        public var differs: Bool {
            change != .same || tree?.differs == true || screenshot?.verdict == .changed
                || timing?.contains { $0.status == .changed } == true
        }
    }

    public var schema = "deviceloop.comparison/1"
    public var id: String
    public var createdAt: String
    public var verdict: Verdict
    public var baseline: Run
    public var candidate: Run
    public var fields: [Field]
    public var reasons: [String]
    public var warnings: [String]
    /// Accessibility ids left out of the tree differences, with the elements inside them.
    public var ignoredIDs: [String]
    /// x, y, width and height in points, left out of the screenshot differences.
    public var masks: [[Double]]
    /// A screenshot changed when more than this percent of its unmasked pixels changed.
    public var maxDiffPercent: Double
    /// A timing changed when it differs by more than this, or by more than twice the cadence slot when that is larger.
    public var minMs: Double
    /// Empty when the command sequences differ.
    public var steps: [Step]

    /// Compares runs `baseline` and `candidate` under `runs` and writes `comparison.json`, `comparison.html` and the
    /// screenshot diff images into a new `comparisons/<id>` folder there. Reads the runs and writes nothing into them.
    public static func write(
        baseline: String, candidate: String, ignoring ignoredIDs: [String] = [], masks: [[Double]] = [],
        maxDiffPercent: Double = 0.1, minMs: Double = 50, in runs: URL = Paths.runs
    ) throws -> (comparison: RunComparison, directory: URL) {
        let baselineRun = try RunStore.named(baseline, in: runs)
        let candidateRun = try RunStore.named(candidate, in: runs)
        let (comparison, images) = try compare(
            baselineRun, candidateRun, id: RunStore.newID("cmp"), ignoring: ignoredIDs, masks: masks, maxDiffPercent: maxDiffPercent,
            minMs: minMs)
        let directory = runs.appending(path: "comparisons/\(comparison.id)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (name, png) in images { try Paths.writePrivate(png, to: directory.appending(path: name)) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try Paths.writePrivate(try encoder.encode(comparison), to: directory.appending(path: "comparison.json"))
            try Paths.writePrivate(
                Data(html(comparison, baselineRun, candidateRun).utf8), to: directory.appending(path: "comparison.html"))
        } catch {
            throw DeviceLoopError(
                .internalError, "Could not write comparison \(comparison.id).",
                fix: "Check free space and write permissions at \(runs.path).",
                detail: error.localizedDescription)
        }
        return (comparison, directory)
    }

    /// The comparison and the diff images to write into its folder, by name.
    static func compare(
        _ baseline: RunStore, _ candidate: RunStore, id: String, ignoring ignoredIDs: [String] = [], masks: [[Double]] = [],
        maxDiffPercent: Double = 0.1, minMs: Double = 50
    ) throws -> (comparison: RunComparison, images: [(name: String, png: Data)]) {
        let sides = [("baseline", baseline), ("candidate", candidate)]
        let manifests = try sides.map { try $0.1.manifest() }
        let journals = try sides.map { try $0.1.events() }
        var reasons: [String] = []
        var warnings: [String] = []
        for ((side, run), (manifest, journal)) in zip(sides, zip(manifests, journals)) {
            if manifest.provenance == nil { reasons.append("\(side) \(run.id) has no provenance, so its target and app are unknown.") }
            if manifest.status != .finished { warnings.append("\(side) \(run.id) is \(manifest.status.rawValue), not finished.") }
            if let source = manifest.provenance?.source, source.dirty {
                warnings.append("\(side) source \(source.revision) has uncommitted changes.")
            }
            warnings += journal.warnings.map { "\(side) \(run.id): \($0)" }
        }

        let values = manifests.map { properties($0.provenance) }
        let fields = zip(values[0], values[1]).map { base, other in
            Field(name: base.name, baseline: base.value ?? "unknown", candidate: other.value ?? "unknown", gate: base.gate)
        }
        for field in fields where field.baseline != field.candidate {
            if field.gate {
                reasons.append("\(field.name) differs: \(field.baseline) vs \(field.candidate).")
            } else if field.name == "locale", field.baseline != "unknown", field.candidate != "unknown" {
                warnings.append("locale differs: \(field.baseline) vs \(field.candidate).")
            }
        }
        if reasons.isEmpty {
            for field in fields where field.gate && field.baseline == "unknown" && field.candidate == "unknown" {
                warnings.append("\(field.name) is unknown on both runs.")
            }
        }

        let commands = [commandList(baseline, journals[0].events), commandList(candidate, journals[1].events)]
        var steps: [Step] = []
        var images: [(name: String, png: Data)] = []
        let names = commands.map { $0.map(\.name) }
        if names[0] == names[1] {
            for (offset, (base, other)) in zip(commands[0], commands[1]).enumerated() {
                let index = offset + 1
                let change: Change =
                    switch (base.command.outcome, other.command.outcome) {
                        case (let baselineOutcome, let candidateOutcome) where baselineOutcome == candidateOutcome: .same
                        case ("ok", _): .regressed
                        case (_, "ok"): .fixed
                        default: .changed
                    }
                var diff: TreeDiff?
                if let baseTree = saved(TreeResult.self, baseline, base.command),
                    let otherTree = saved(TreeResult.self, candidate, other.command)
                {
                    diff = TreeDiff(baseTree, otherTree, ignoring: Set(ignoredIDs))
                    if baseTree.app != otherTree.app {
                        warnings.append("step \(index): the baseline tree is of \(baseTree.app), the candidate tree of \(otherTree.app).")
                    }
                    for (side, tree) in [("baseline", baseTree), ("candidate", otherTree)] where tree.partial == true {
                        warnings.append("step \(index): the \(side) tree is partial.")
                    }
                }
                var screenshot: ImageDiff?
                if let baseShot = saved(Screenshot.self, baseline, base.command), saved(Screenshot.self, candidate, other.command) != nil {
                    let missing = ImageDiff(verdict: .inconclusive, reason: "a run kept no PNG of its screenshot.")
                    var compared = (diff: missing, png: Data?.none)
                    if let basePNG = png(baseline, base.command), let otherPNG = png(candidate, other.command) {
                        compared = try ImageDiff.compare(
                            basePNG, otherPNG, pointScale: baseShot.pointScale, masks: masks, maxDiffPercent: maxDiffPercent)
                    }
                    if let image = compared.png {
                        let name = "step-\(index)-diff.png"
                        compared.diff.image = name
                        images.append((name, image))
                    }
                    if compared.diff.verdict == .inconclusive { reasons.append("step \(index): \(compared.diff.line)") }
                    screenshot = compared.diff
                }
                var timing: [Timing]?
                if let baseReport = saved(AnimationReport.self, baseline, base.command),
                    let otherReport = saved(AnimationReport.self, candidate, other.command)
                {
                    timing = Timing.compare(baseReport, otherReport, minMs: minMs)
                }
                steps.append(
                    Step(
                        index: index, command: base.name, change: change,
                        argumentsDiffer: withoutTargetAndOutput(base.command.args) != withoutTargetAndOutput(other.command.args),
                        fragile: hasRef(base.command.args) || hasRef(other.command.args), baseline: base.command,
                        candidate: other.command, tree: diff, screenshot: screenshot, timing: timing))
            }
        } else if let index = zip(names[0], names[1]).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            reasons.append("Command sequences differ at step \(index + 1): \(names[0][index]) vs \(names[1][index]).")
        } else {
            reasons.append("Command sequences differ: the baseline has \(names[0].count) commands, the candidate \(names[1].count).")
        }

        let verdict: Verdict = !reasons.isEmpty ? .inconclusive : steps.contains(where: \.differs) ? .different : .same
        let comparison = RunComparison(
            id: id, createdAt: RunStore.timestamp(), verdict: verdict,
            baseline: Run(id: baseline.id, name: manifests[0].name, status: manifests[0].status, outcome: manifests[0].outcome),
            candidate: Run(id: candidate.id, name: manifests[1].name, status: manifests[1].status, outcome: manifests[1].outcome),
            fields: fields, reasons: reasons, warnings: warnings, ignoredIDs: ignoredIDs, masks: masks,
            maxDiffPercent: maxDiffPercent, minMs: minMs, steps: steps)
        return (comparison, images)
    }

    /// The field of a saved `screenshot` result that converts masks to pixels.
    struct Screenshot: Decodable {
        var pointScale: Double
    }

    /// The result that `command` saved in `run` as `type`, nil when it failed or saved another result.
    static func saved<T: Decodable>(_ type: T.Type, _ run: RunStore, _ command: Command) -> T? {
        guard command.outcome == "ok",
            let data = try? Data(contentsOf: run.directory.appending(path: "results/\(command.seq).json"))
        else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// The first PNG that `command` kept inside `run`.
    static func png(_ run: RunStore, _ command: Command) -> URL? {
        command.files.first { $0.lowercased().hasSuffix(".png") && RunReport.href($0, in: run) != nil }
            .map { run.directory.appending(path: $0) }
    }

    /// The compared properties of a run, in display order.
    static func properties(_ provenance: RunProvenance?) -> [(name: String, value: String?, gate: Bool)] {
        let device = provenance?.device
        let screen = provenance?.screen
        let app = provenance?.app
        return [
            ("model", device?.model, false),
            ("productType", device?.productType, true),
            ("osVersion", device?.osVersion, false),
            ("osBuild", device?.osBuild, true),
            ("screen", screen.map { "\($0.pointWidth)x\($0.pointHeight) pt @\(ParityText.number($0.scale))x" }, true),
            ("orientation", screen?.orientation, true),
            ("locale", provenance?.locale, false),
            ("app", app?.bundleID, true),
            ("appVersion", app?.version, false),
            ("appBuild", app?.build, false),
            ("source", provenance?.source.map { $0.revision + ($0.dirty ? " with changes" : "") }, false),
        ]
    }

    /// The started events of `events` in order, each with its outcome and files.
    static func commandList(_ run: RunStore, _ events: [RunEvent]) -> [(name: String, command: Command)] {
        var finished: [Int: RunEvent] = [:]
        for event in events { if let seq = event.started { finished[seq] = event } }
        return events.filter { $0.kind == "started" }.map { started in
            let end = finished[started.seq]
            let outcome =
                switch end?.outcome {
                    case .ok?: "ok"
                    case .error?: end?.error?.code.rawValue ?? "error"
                    case .cancelled?: "cancelled"
                    case nil: "not_finished"
                }
            let result = "results/\(started.seq).json"
            let hasResult = FileManager.default.fileExists(atPath: run.directory.appending(path: result).path)
            let files = (hasResult ? [result] : []) + (end?.artifacts ?? [])
            return (started.command, Command(seq: started.seq, args: started.args, outcome: outcome, files: files))
        }
    }

    /// `args` without `--device X`, `-d X`, `--device=X`, `--json` or a `device` key.
    static func withoutTargetAndOutput(_ args: JSONValue) -> JSONValue {
        switch args {
            case .array(let words):
                var kept: [JSONValue] = []
                var skipping = false
                for word in words {
                    if skipping {
                        skipping = false
                    } else if word.string == "--device" || word.string == "-d" {
                        skipping = true
                    } else if word.string?.hasPrefix("--device=") != true, word.string != "--json" {
                        kept.append(word)
                    }
                }
                return .array(kept)
            case .object(var fields):
                fields["device"] = nil
                return .object(fields)
            default: return args
        }
    }

    /// Whether a string in `args` holds an `@eN` ref.
    static func hasRef(_ args: JSONValue) -> Bool {
        switch args {
            case .string(let text): text.contains(/@e[0-9]+/)
            case .array(let items): items.contains(where: hasRef)
            case .object(let fields): fields.values.contains(where: hasRef)
            default: false
        }
    }

    /// Static HTML with inline CSS and no script. Links point into the two runs, two folders up. `leftOut` holds the paths
    /// that an export left out, relative to the folder that holds the runs.
    static func html(_ comparison: RunComparison, _ baseline: RunStore, _ candidate: RunStore, leftOut: Set<String> = []) -> String {
        func link(_ path: String, in run: RunStore) -> String? {
            guard let href = RunReport.href(path, in: run),
                let id = run.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            else { return nil }
            return "../../\(id)/\(href.dropFirst(2))"
        }
        func runCell(_ side: Run, _ run: RunStore) -> String {
            var text = side.id + (side.name.map { " \"\($0)\"" } ?? "") + " \(side.status.rawValue)"
            if let outcome = side.outcome { text += ", \(outcome.rawValue)" }
            guard let report = link("report.html", in: run) else { return RunReport.escape(text) }
            return "<a href=\"\(RunReport.escape(report))\">\(RunReport.escape(text))</a>"
        }
        func commandCell(_ command: Command, _ run: RunStore) -> String {
            let event = RunReport.escape("event \(command.seq)\(RunCommands.words(command.args)): \(command.outcome)")
            let files = command.files.map { file in
                guard let href = link(file, in: run) else {
                    return RunReport.note(leftOut.contains("\(run.id)/\(file)") ? "\(file) left out of this export" : "missing \(file)")
                }
                return RunReport.media(href, name: URL(filePath: file).lastPathComponent)
            }
            return "<p><code>\(event)</code></p>" + RunReport.evidenceList(files)
        }

        var fields = [
            "<tr><th>Run</th><td>\(runCell(comparison.baseline, baseline))</td><td>\(runCell(comparison.candidate, candidate))</td></tr>"
        ]
        for field in comparison.fields {
            let style = field.baseline == field.candidate ? "" : field.gate ? " class=\"bad\"" : " class=\"warn\""
            fields.append(
                "<tr\(style)><th>\(RunReport.escape(field.name))</th><td>\(RunReport.escape(field.baseline))</td>"
                    + "<td>\(RunReport.escape(field.candidate))</td></tr>")
        }
        let steps = comparison.steps.map { step in
            var notes: [String] = []
            if step.argumentsDiffer { notes.append("arguments differ") }
            if step.fragile { notes.append("@eN ref, fragile") }
            if step.tree?.differs == true { notes.append("tree changed") }
            if let screenshot = step.screenshot, screenshot.verdict != .same { notes.append("screenshot \(screenshot.verdict.rawValue)") }
            if step.timing?.contains(where: { $0.status == .changed }) == true { notes.append("timing changed") }
            let style =
                if step.change == .fixed {
                    "warn"
                } else if step.change != .same || step.tree?.differs == true || step.screenshot?.verdict == .changed {
                    "bad"
                } else if step.differs || step.screenshot?.verdict == .inconclusive {
                    "warn"
                } else {
                    "ok"
                }
            var details = step.tree.map { RunReport.list($0.lines, empty: "Trees match.") } ?? ""
            if let screenshot = step.screenshot {
                details += RunReport.list([screenshot.line], empty: "")
                if let image = screenshot.image, !leftOut.contains("comparisons/\(comparison.id)/\(image)") {
                    details += RunReport.media("./" + image, name: image)
                }
            }
            details += step.timing.map { RunReport.list($0.map(\.line), empty: "No timings.") } ?? ""
            let heading =
                "<h3><span class=\"index\">\(step.index)</span><code>\(RunReport.escape(step.command))</code>"
                + RunReport.pill(([step.change.rawValue] + notes).joined(separator: ", "), style: style) + "</h3>"
            let sides =
                "<div class=\"sides\"><div><h4>Baseline</h4>\(commandCell(step.baseline, baseline))</div>"
                + "<div><h4>Candidate</h4>\(commandCell(step.candidate, candidate))</div></div>"
            return "<section class=\"step \(style)\">\n\(heading)\(details)\n\(sides)\n</section>"
        }
        let verdictStyle =
            switch comparison.verdict {
                case .same: "ok"
                case .different: "bad"
                case .inconclusive: "warn"
            }
        let reasons =
            comparison.reasons.isEmpty ? "" : "<h2>Inconclusive because</h2>\n\(RunReport.list(comparison.reasons, empty: ""))\n"
        return RunReport.page(
            title: "comparison \(comparison.id)", kind: "run comparison", status: comparison.verdict.rawValue, statusStyle: verdictStyle,
            body: """
                \(RunReport.table(["", "Baseline", "Candidate"], rows: fields, style: "fields"))
                \(reasons)<h2>Warnings</h2>
                \(RunReport.list(comparison.warnings, empty: "None."))
                <h2>Steps</h2>
                \(steps.isEmpty ? "<p class=\"empty\">No steps compared.</p>" : steps.joined(separator: "\n"))
                """)
    }
}
