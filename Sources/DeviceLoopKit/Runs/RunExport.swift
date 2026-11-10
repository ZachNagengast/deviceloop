//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// A copy of a run, or of a comparison and its two runs, to attach to a bug report. Personal values become aliases, typed
/// text is hidden and the reports are rendered again from the redacted copy. The source folders are only read.
enum RunExport {
    struct Summary {
        /// The rendered report, relative to the export folder.
        var report: String
        /// Every exported file except EXPORT.txt, relative to the export folder.
        var files: [RunManifest.File]
        /// Files and journal lines that were not exported, each with the reason.
        var leftOut: [String]
        /// Typed and pasteboard texts replaced with `[hidden]`.
        var hidden: Int
        var zip: URL?
    }

    /// Extensions of the images and videos that are copied as they are, or left out without `media`.
    static let mediaExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "mp4", "mov", "m4v"]

    /// Keys whose string values in manifests, journals and comparisons are names or hashes of the format.
    static let formatKeys: Set<String> = ["kind", "outcome", "code", "actor", "status", "verdict", "change", "property", "sha256"]

    /// Writes run `id`, or comparison `comparison` and its two runs, into the new folder `out` as `<run id>/` and
    /// `comparisons/<id>/` folders with EXPORT.txt, and with `zip` also `<out>.zip`. Fails without writing `out` when a
    /// token pattern is left in any exported file.
    static func write(
        run id: String?, comparison: String?, to out: URL, media: Bool = true, keepTypedText: Bool = false, zip: Bool = false,
        redactor: inout Redactor, in runs: URL = Paths.runs
    ) async throws -> Summary {
        try checkArguments(run: id, comparison: comparison, to: out, zip: zip, in: runs)
        let archive = out.appendingPathExtension("zip")
        var compared: (comparison: RunComparison, folder: URL)?
        if let comparison {
            let folder = try RunStore.named(comparison, in: runs.appending(path: "comparisons")).directory
            guard let contents = try? Data(contentsOf: folder.appending(path: "comparison.json")),
                let decoded = try? JSONDecoder().decode(RunComparison.self, from: contents)
            else {
                throw DeviceLoopError(
                    .badArguments, "No readable comparison at \(folder.path).", fix: "Pass a comparison ID that run compare printed.")
            }
            guard decoded.id == comparison else {
                throw DeviceLoopError(
                    .badArguments, "comparison.json in \(folder.path) names another comparison.",
                    fix: "Pass a comparison ID that run compare printed.")
            }
            compared = (decoded, folder)
        }
        let runIDs = compared.map { [$0.comparison.baseline.id, $0.comparison.candidate.id] } ?? [id ?? ""]
        let sources = try Array(Set(runIDs)).sorted().map { try RunStore.named($0, in: runs) }
        let journals = try sources.map { (manifest: try $0.manifest(), journal: try $0.events()) }

        var typed: Set<String> = []
        for (manifest, journal) in journals {
            redactor.add(manifest.provenance?.device.udid, as: .udid)
            for event in journal.events {
                redactor.add(event.error?.device, as: .device)
                for device in devices(event.args) { redactor.add(device, as: .device) }
                if !keepTypedText { typed.formUnion(typedText(event)) }
            }
        }
        typed.remove("[hidden]")
        typed.remove("")
        let substrings = typed.filter { $0.count >= 3 }.sorted { $0.count > $1.count }
        var hidden = 0
        /// `text` as `[hidden]` when it is a typed text, else with each typed text of three or more characters hidden.
        func hide(_ text: String) -> String {
            if typed.contains(text) {
                hidden += 1
                return "[hidden]"
            }
            guard !substrings.isEmpty else { return text }
            let replaced = RunRecorder.hide(substrings, in: text)
            hidden += replaced.components(separatedBy: "[hidden]").count - text.components(separatedBy: "[hidden]").count
            return replaced
        }
        func hide(_ json: JSONValue) -> JSONValue {
            switch json {
                case .string(let text): .string(hide(text))
                case .array(let items): .array(items.map(hide))
                case .object(let fields): .object(fields.mapValues(hide))
                default: json
            }
        }
        func hide(_ element: TreeDiff.Element) -> TreeDiff.Element {
            var element = element
            element.label = element.label.map(hide)
            return element
        }
        /// `json` redacted except its keys and the values of `formatKeys`, so it still decodes. `args` is redacted with its keys.
        func redactRecord(_ json: JSONValue) -> JSONValue {
            switch json {
                case .string(let text): return .string(redactor.redact(text))
                case .array(let items): return .array(items.map(redactRecord))
                case .object(let fields):
                    var redacted: [String: JSONValue] = [:]
                    for (key, value) in fields {
                        if key == "args" {
                            redacted[key] = redactor.redact(value)
                        } else if value.string != nil, formatKeys.contains(key) {
                            redacted[key] = value
                        } else {
                            redacted[key] = redactRecord(value)
                        }
                    }
                    return .object(redacted)
                default: return json
            }
        }
        /// `json` with its string values redacted and its keys kept.
        func redactValues(_ json: JSONValue) -> JSONValue {
            switch json {
                case .string(let text): .string(redactor.redact(text))
                case .array(let items): .array(items.map(redactValues))
                case .object(let fields): .object(fields.mapValues(redactValues))
                default: json
            }
        }
        var leftOut: [String] = []
        var omitted: Set<String> = []
        /// Lists `path`, relative to `out`, as left out for `reason` in the summary and the reports.
        func leaveOut(_ path: String, _ reason: String) {
            leftOut.append("\(path): \(reason)")
            omitted.insert(path)
        }
        /// Writes the redacted copy of `path` under `root` to `target`, or adds it to `leftOut`.
        func copy(_ path: String, from root: URL, to target: URL, prefix: String) throws {
            let file = root.appending(path: path)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { return leaveOut("\(prefix)\(redactor.redact(path))", "a link") }
            guard values.isRegularFile == true else { return }
            let name = redactor.redact(path)
            let destination = target.appending(path: name)
            if mediaExtensions.contains(file.pathExtension.lowercased()) {
                guard media else { return leaveOut("\(prefix)\(name)", "image or video, --no-media") }
                _ = try Paths.ensureDirectory(destination.deletingLastPathComponent())
                try FileManager.default.copyItem(at: file, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                return
            }
            let contents = try Data(contentsOf: file)
            if file.pathExtension == "json", let json = try? JSONValue(data: contents) {
                try Paths.writePrivate(try redactValues(hide(json)).data(pretty: true), to: destination)
            } else if let text = String(data: contents, encoding: .utf8) {
                try Paths.writePrivate(Data(redactor.redact(hide(text)).utf8), to: destination)
            } else {
                leaveOut("\(prefix)\(name)", "not text, an image or a video")
            }
        }

        let staging = out.deletingLastPathComponent().appending(
            path: ".\(out.lastPathComponent)-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        var report = ""
        do {
            for (run, (manifest, journal)) in Swift.zip(sources, journals) {
                let target = try Paths.ensureDirectory(staging.appending(path: run.id, directoryHint: .isDirectory))
                var lines: [String] = []
                for var event in journal.events {
                    event.args = hide(event.args)
                    if var error = event.error {
                        error.message = hide(error.message)
                        error.fix = error.fix.map(hide)
                        error.detail = error.detail.map(hide)
                        event.error = error
                    }
                    lines.append(String(decoding: try redactRecord(JSONValue(encoding: event)).data(), as: UTF8.self) + "\n")
                }
                try Paths.writePrivate(Data(lines.joined().utf8), to: target.appending(path: "events.jsonl"))
                leftOut += journal.warnings.map { "\(run.id)/\($0)" }

                let pasteboard = journal.events.filter { $0.kind == "started" && $0.command == "pasteboard" }
                let pasteboardResults = Set(pasteboard.map { "results/\($0.seq).json" })
                let paths = try FileManager.default.subpathsOfDirectory(atPath: run.directory.path).sorted()
                for path in paths where path.hasPrefix("results/") || path.hasPrefix("artifacts/") {
                    if !keepTypedText && pasteboardResults.contains(path) {
                        leaveOut("\(run.id)/\(path)", "pasteboard contents")
                        continue
                    }
                    try copy(path, from: run.directory, to: target, prefix: "\(run.id)/")
                }

                var copied = manifest
                copied.owner = nil
                if copied.files != nil { copied.files = try RunStore.inventory(target) }
                try Paths.writePrivate(
                    try redactRecord(JSONValue(encoding: copied)).data(pretty: true), to: target.appending(path: "manifest.json"))
                try RunReport.write(RunStore(directory: target), leftOut: omitted)
                report = "\(run.id)/report.html"
            }

            if case (let comparison, let folder)? = compared {
                let target = try Paths.ensureDirectory(staging.appending(path: "comparisons/\(comparison.id)", directoryHint: .isDirectory))
                var copied = comparison
                for index in copied.steps.indices {
                    copied.steps[index].baseline.args = hide(copied.steps[index].baseline.args)
                    copied.steps[index].candidate.args = hide(copied.steps[index].candidate.args)
                    guard var tree = copied.steps[index].tree else { continue }
                    tree.added = tree.added.map(hide)
                    tree.removed = tree.removed.map(hide)
                    for change in tree.changed.indices {
                        tree.changed[change].element = hide(tree.changed[change].element)
                        tree.changed[change].baseline = hide(tree.changed[change].baseline)
                        tree.changed[change].candidate = hide(tree.changed[change].candidate)
                    }
                    for group in tree.ambiguous.indices { tree.ambiguous[group].label = tree.ambiguous[group].label.map(hide) }
                    copied.steps[index].tree = tree
                }
                let json = redactRecord(try JSONValue(encoding: copied))
                try Paths.writePrivate(try json.data(pretty: true), to: target.appending(path: "comparison.json"))
                for path in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
                where !["comparison.json", "comparison.html"].contains(path) {
                    try copy(path, from: folder, to: target, prefix: "comparisons/\(comparison.id)/")
                }
                let page = RunComparison.html(
                    try json.decode(RunComparison.self), RunStore(directory: staging.appending(path: comparison.baseline.id)),
                    RunStore(directory: staging.appending(path: comparison.candidate.id)), leftOut: omitted)
                try Paths.writePrivate(Data(page.utf8), to: target.appending(path: "comparison.html"))
                report = "comparisons/\(comparison.id)/comparison.html"
            }

            let files = try RunStore.inventory(staging)
            let tokens = try files.map(\.path).filter {
                hasToken(try Data(contentsOf: staging.appending(path: $0), options: .alwaysMapped))
            }
            guard tokens.isEmpty else {
                throw DeviceLoopError(
                    .internalError, "A token pattern is left in \(tokens.joined(separator: ", ")), so nothing was exported.",
                    fix: "Export with --no-media when it is an image or video. Otherwise report it as a DeviceLoop bug.")
            }
            let title = compared.map { "comparison \($0.comparison.id) of runs \(runIDs.joined(separator: " and "))" } ?? "run \(runIDs[0])"
            let text = notes(
                title: title, files: files, counts: redactor.counts, hidden: keepTypedText ? nil : hidden, media: media, leftOut: leftOut)
            try Paths.writePrivate(Data(text.utf8), to: staging.appending(path: "EXPORT.txt"))
            try FileManager.default.moveItem(at: staging, to: out)
            var summary = Summary(report: report, files: files, leftOut: leftOut, hidden: hidden)
            if zip {
                let result = try await Shell.run(
                    ["/usr/bin/ditto", "-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent", out.path, archive.path])
                guard result.succeeded else {
                    throw DeviceLoopError(
                        .internalError, "Could not zip \(out.path).", fix: "The folder is complete. Zip it yourself or attach it.",
                        detail: result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
                summary.zip = archive
            }
            return summary
        } catch let error as DeviceLoopError {
            throw error
        } catch {
            throw DeviceLoopError(
                .internalError, "Could not write the export.",
                fix: "Check free space and write permissions at \(out.deletingLastPathComponent().path).",
                detail: error.localizedDescription)
        }
    }

    /// Throws bad_arguments unless exactly one of `id` and `comparison` is given and `out`, and with `zip` also `<out>.zip`,
    /// is a new path outside `runs`, also through a link or in another letter case.
    static func checkArguments(run id: String?, comparison: String?, to out: URL, zip: Bool, in runs: URL = Paths.runs) throws {
        guard (id == nil) != (comparison == nil) else {
            throw DeviceLoopError(
                .badArguments, "Export takes a run ID or a comparison ID.", fix: "Pass a run ID, or --comparison with a comparison ID.")
        }
        let folder = resolved(out)
        let root = resolved(runs)
        if folder == root || folder.hasPrefix(root + "/") {
            throw DeviceLoopError(
                .badArguments, "\(out.path) is inside \(runs.path).", fix: "Pass an --out folder outside the runs folder.")
        }
        for path in [out] + (zip ? [out.appendingPathExtension("zip")] : []) where FileManager.default.fileExists(atPath: path.path) {
            throw DeviceLoopError(.badArguments, "\(path.path) already exists.", fix: "Pass an --out folder that does not exist yet.")
        }
    }

    /// The lowercased path of `url` with the links resolved up to its deepest existing folder.
    static func resolved(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return rest.reduce(existing.resolvingSymlinksInPath()) { $0.appending(path: $1) }.path.lowercased()
    }

    /// Text that a started event typed or sent: the text of `ui type`, `siri say` and `pasteboard copy`, the MCP `text`
    /// argument, and every type step with its text.
    static func typedText(_ event: RunEvent) -> [String] {
        var typed = [event.args["text"]?.string].compactMap { $0 }
        if let words = event.args.array?.compactMap(\.string) {
            var positional: [String] = []
            var index = 0
            while index < words.count {
                if words[index] == "--" {
                    positional += words[(index + 1)...]
                    break
                }
                if ["--into", "--app", "--device", "-d"].contains(words[index]) {
                    index += 2
                    continue
                }
                if !words[index].hasPrefix("-") { positional.append(words[index]) }
                index += 1
            }
            switch event.command {
                case "ui type", "siri say": typed += positional.prefix(1)
                case "pasteboard" where positional.first == "copy": typed += positional.dropFirst().prefix(1)
                default: break
            }
        }
        for text in strings(event.args) {
            if let step = (try? UIStep.parse(text))?.typedText { typed += [text, step] }
        }
        return typed
    }

    /// Every string in `json`.
    static func strings(_ json: JSONValue) -> [String] {
        switch json {
            case .string(let text): [text]
            case .array(let items): items.flatMap(strings)
            case .object(let fields): fields.values.flatMap(strings)
            default: []
        }
    }

    /// The `--device`, `-d` and `--device=` values of CLI arguments and the MCP `device` argument, except `booted` and `usb`.
    static func devices(_ args: JSONValue) -> [String] {
        var values = [args["device"]?.string].compactMap { $0 }
        let words = args.array?.compactMap(\.string) ?? []
        for (index, word) in words.enumerated() {
            if ["--device", "-d"].contains(word), index + 1 < words.count { values.append(words[index + 1]) }
            if word.hasPrefix("--device=") { values.append(String(word.dropFirst("--device=".count))) }
        }
        return values.filter { !["booted", "usb"].contains($0.lowercased()) }
    }

    /// Whether `data` holds a token pattern of `Redactor`: 43 base64 characters and `=`, or `Bearer`, whitespace and a token
    /// that is not a `token-` alias.
    static func hasToken(_ data: Data) -> Bool {
        let base64 = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        let tokenBytes = base64.union("=._~-".utf8)
        var base64Length = 0
        for byte in data {
            if byte == UInt8(ascii: "="), base64Length >= 43 { return true }
            base64Length = base64.contains(byte) ? base64Length + 1 : 0
        }
        var start = data.startIndex
        while let match = data.range(of: Data("Bearer".utf8), in: start ..< data.endIndex) {
            start = match.upperBound
            let rest = data[match.upperBound...]
            let token = rest.drop { [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20].contains($0) }
            guard token.count < rest.count, let first = token.first, tokenBytes.contains(first) else { continue }
            if !token.starts(with: Data("token-".utf8)) { return true }
        }
        return false
    }

    /// EXPORT.txt: what was exported, the SHA256 of each file in `shasum -a 256` format, the replacements, what was left
    /// out and what to review. `hidden` is nil when typed text was kept.
    static func notes(
        title: String, files: [RunManifest.File], counts: [Redactor.Kind: Int], hidden: Int?, media: Bool, leftOut: [String]
    ) -> String {
        var lines = ["DeviceLoop export of \(title)", "", "SHA256 of each file, check with shasum -a 256 -c EXPORT.txt in this folder:"]
        lines += files.map { "\($0.sha256)  \($0.path)" }
        lines += ["", "Replacements by rule:"] + Redactor.Kind.allCases.map { "- \($0.rule): \(counts[$0] ?? 0)" }
        lines.append(
            hidden.map { "- [hidden] for typed text and pasteboard text in arguments, results, errors and text files: \($0)" }
                ?? "- typed text and pasteboard contents: kept, --keep-typed-text")
        lines += [
            "",
            "Aliases are salted per export. A value has one alias in this folder and a different one in the next export.",
            "Left out: events.lock and the original reports, which were rendered again from the redacted copy.",
        ]
        lines += leftOut.map { "Left out \($0)" }
        lines += [
            "",
            media
                ? "Screenshots, videos and UI text, such as the labels and values in ui tree results, are included as recorded."
                : "Screenshots and videos are left out. UI text, such as the labels and values in ui tree results, is included "
                    + "as recorded.",
            "Review every file before you share it. Redaction replaces known values and patterns and can miss others.",
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}
