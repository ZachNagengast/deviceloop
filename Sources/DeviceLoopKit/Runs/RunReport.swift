//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// `report.html` of a run: static HTML with inline CSS, no script, and links only to files inside the run.
public enum RunReport {
    /// Renders the report of `run` into its `report.html`. `leftOut` holds the paths that an export left out, relative to
    /// the folder that holds the run.
    @discardableResult
    public static func write(_ run: RunStore, leftOut: Set<String> = []) throws -> URL {
        let page = try html(run, leftOut: leftOut)
        let url = run.directory.appending(path: "report.html")
        do {
            try Paths.writePrivate(Data(page.utf8), to: url)
        } catch {
            throw DeviceLoopError(
                .internalError, "Could not write \(url.path).", fix: "Check free space and write permissions at \(run.directory.path).",
                detail: error.localizedDescription)
        }
        return url
    }

    static func html(_ run: RunStore, leftOut: Set<String> = []) throws -> String {
        let manifest = try run.manifest()
        let journal = try run.events()
        let events = journal.events
        var finished: [Int: RunEvent] = [:]
        for event in events { if let seq = event.started { finished[seq] = event } }
        let startedSeqs = Set(events.filter { $0.kind == "started" }.map(\.seq))
        let commands = events.filter { $0.kind == "started" || !startedSeqs.contains($0.started ?? 0) }
        var notes = journal.warnings
        var issues: [String] = []
        var rows: [String] = []
        for command in commands {
            let end = command.kind == "started" ? finished[command.seq] : command
            let label = command.command + RunCommands.words(command.args)
            let outcome =
                switch end?.outcome {
                    case .ok?: (text: "ok", style: "ok")
                    case .error?: (text: "error \(end?.error?.code.rawValue ?? "")", style: "bad")
                    case .cancelled?: (text: "cancelled", style: "bad")
                    case nil: (text: "not finished", style: "warn")
                }
            if end == nil { notes.append("\(command.seq) \(command.command) has no finished event.") }
            var evidence: [String] = []
            let result = "results/\(command.seq).json"
            if let link = href(result, in: run) {
                evidence.append(media(link, name: "result.json"))
                let json = try? JSONValue(data: Data(contentsOf: run.directory.appending(path: result)))
                for issue in json?["issues"]?.array ?? [] {
                    let kind = issue["isFailure"]?.bool == true ? "failure" : "warning"
                    let type = issue["type"]?.number.flatMap { Int(exactly: $0) }.map { " type \($0)" } ?? ""
                    issues.append("\(command.seq) \(command.command): \(kind)\(type): \(issue["message"]?.string ?? "")")
                }
            }
            for artifact in end?.artifacts ?? [] {
                if let link = href(artifact, in: run) {
                    evidence.append(media(link, name: URL(filePath: artifact).lastPathComponent))
                } else if leftOut.contains("\(run.id)/\(artifact)") {
                    evidence.append(note("\(artifact) left out of this export"))
                } else {
                    evidence.append(note("missing \(artifact)"))
                    notes.append("\(command.seq) \(command.command) lists \(artifact), which is not a file in the run.")
                }
            }
            let duration = end.map { String(format: "%.3f s", $0.offset - command.offset) } ?? ""
            rows.append(
                "<tr><td>\(command.seq)</td><td data-label=\"Start\" title=\"\(escape(command.time))\">"
                    + "\(String(format: "%.3f s", command.offset))</td><td data-label=\"Duration\">\(duration)</td>"
                    + "<td><code>\(escape(label))</code></td><td>\(pill(outcome.text, style: outcome.style))</td>"
                    + "<td>\(evidenceList(evidence))</td></tr>")
        }

        var status = manifest.status.rawValue
        if let outcome = manifest.outcome { status += ", \(outcome.rawValue)" }
        status += ", \(commands.count) command\(commands.count == 1 ? "" : "s")"
        let statusStyle =
            switch manifest.outcome {
                case .passed?: "ok"
                case .failed?: "bad"
                case nil: "warn"
            }
        var header = [("Created", manifest.createdAt), ("Finished", manifest.finishedAt ?? "not finished")]
        if let provenance = manifest.provenance {
            let device = provenance.device
            header += [
                ("Target", "\(device.model) (\(device.productType)) \(device.osVersion)\(device.osBuild.map { " (\($0))" } ?? "")"),
                ("UDID", device.udid + (device.transport.map { ", \($0)" } ?? "")),
                ("DeviceLoop", provenance.deviceloop),
                ("macOS", provenance.macOS),
                ("Xcode", provenance.xcode.map { $0 + (provenance.xcodeBuild.map { " (\($0))" } ?? "") } ?? "not recorded"),
                ("Runner build", provenance.runnerBuild ?? "not recorded"),
                ("App", provenance.app.map { "\($0.bundleID) \($0.version ?? "?") (\($0.build ?? "?"))" } ?? "not recorded"),
                ("Source", provenance.source.map { $0.revision + ($0.dirty ? " with changes" : "") } ?? "not recorded"),
            ]
        } else {
            header.append(("Provenance", "not recorded"))
        }

        var failing = ""
        if let failure = RunStore.firstFailure(events) {
            let start = failure.kind == "started" ? failure : events.first { $0.seq == failure.started } ?? failure
            var lines = [("Step", "\(start.seq) \(start.command)\(RunCommands.words(start.args))")]
            switch failure.outcome {
                case .error?:
                    if let error = failure.error {
                        lines += [("Code", error.code.rawValue), ("Message", error.message)]
                        if let fix = error.fix { lines.append(("Fix", fix)) }
                        if let detail = error.detail { lines.append(("Detail", detail)) }
                    }
                case .cancelled?: lines.append(("Outcome", "cancelled"))
                default: lines.append(("Outcome", "no finished event"))
            }
            failing = "<h2>Failing step</h2>\n\(facts(lines, style: "failure"))\n"
        }

        let inventory = Dictionary((manifest.files ?? []).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        if manifest.files == nil { notes.append("No hash inventory: run stop records the size and SHA256 of every file.") }
        let onDisk = ((try? FileManager.default.subpathsOfDirectory(atPath: run.directory.path)) ?? [])
            .filter { !RunStore.unhashed.contains($0) && href($0, in: run) != nil }
        var files: [String] = []
        for path in Set(onDisk).union(inventory.keys).sorted() {
            let link = href(path, in: run)
            if link == nil { notes.append("\(path) is in the hash inventory but not in the run.") }
            let name = link.map { "<a href=\"\(escape($0))\">\(escape(path))</a>" } ?? escape(path)
            let file = inventory[path]
            files.append(
                "<tr><td>\(name)</td><td>\(file.map { "\($0.bytes)" } ?? "")</td>"
                    + "<td class=\"hash\">\(escape(file?.sha256 ?? "not recorded"))</td></tr>")
        }

        let title = "run \(run.id)" + (manifest.name.map { " \"\($0)\"" } ?? "")
        let timeline =
            rows.isEmpty
            ? "<p class=\"empty\">No commands recorded.</p>"
            : table(["#", "Start", "Duration", "Command", "Outcome", "Evidence"], rows: rows, style: "timeline")
        return page(
            title: title, kind: "run report", status: status, statusStyle: statusStyle,
            body: """
                \(facts(header, style: "facts"))
                \(failing)<h2>Timeline</h2>
                \(timeline)
                <h2>XCTest issues</h2>
                \(list(issues, empty: "None recorded."))
                <h2>Missing evidence</h2>
                \(list(notes, empty: "None."))
                <h2>Files</h2>
                \(table(["Path", "Bytes", "SHA256"], rows: files, style: "files"))
                """)
    }

    /// A page with the inline CSS and a header naming `title` with `status` as a pill.
    static func page(title: String, kind: String, status: String, statusStyle: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'">
        <title>\(escape(title))</title>
        <style>
        \(style)
        </style>
        </head>
        <body>
        <main>
        <header>
        <p class="kind">DeviceLoop \(kind)</p>
        <h1>\(escape(title))</h1>
        <p class="pill \(statusStyle)">\(escape(status))</p>
        </header>
        \(body)
        </main>
        </body>
        </html>

        """
    }

    /// The inline CSS of `report.html` and `comparison.html`.
    static let style = """
        :root {
            color-scheme: light dark;
            --bg: #f6f7f9;
            --surface: #ffffff;
            --text: #1f2328;
            --muted: #656d76;
            --line: #d8dee4;
            --link: #0969da;
            --ok: #1a7f37;
            --ok-tint: #dafbe1;
            --bad: #cf222e;
            --bad-tint: #ffebe9;
            --warn: #9a6700;
            --warn-tint: #fff8c5;
            --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg: #0d1117;
                --surface: #161b22;
                --text: #e6edf3;
                --muted: #8d96a0;
                --line: #30363d;
                --link: #58a6ff;
                --ok: #3fb950;
                --ok-tint: #11291b;
                --bad: #ff7b72;
                --bad-tint: #3a1618;
                --warn: #e3b341;
                --warn-tint: #33280f;
            }
        }
        * { box-sizing: border-box; }
        body {
            margin: 0;
            background: var(--bg);
            color: var(--text);
            font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
            -webkit-text-size-adjust: 100%;
        }
        main { max-width: 1200px; margin: 0 auto; padding: 32px 24px 64px; }
        a { color: var(--link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        header { margin-bottom: 16px; }
        h1 { margin: 2px 0 12px; font-size: 22px; line-height: 1.3; overflow-wrap: anywhere; }
        h2 { margin: 32px 0 10px; font-size: 15px; }
        h3 { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin: 0; font-size: 15px; }
        h4 { margin: 0 0 6px; color: var(--muted); font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.04em; }
        p { margin: 0; }
        code { font: 12.5px/1.5 var(--mono); white-space: pre-wrap; overflow-wrap: anywhere; }
        .kind { color: var(--muted); font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; }
        .ok { --tone: var(--ok); --tint: var(--ok-tint); }
        .bad { --tone: var(--bad); --tint: var(--bad-tint); }
        .warn { --tone: var(--warn); --tint: var(--warn-tint); }
        .pill {
            display: inline-block;
            padding: 1px 10px;
            border-radius: 11px;
            background: var(--tint);
            color: var(--tone);
            font-size: 12px;
            font-weight: 600;
            line-height: 20px;
        }
        .empty, .note { color: var(--muted); }
        .card, dl, main > ul, .step { background: var(--surface); border: 1px solid var(--line); border-radius: 10px; }
        .card { overflow-x: auto; }
        dl { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 6px 24px; margin: 0; padding: 16px 20px; }
        dt { color: var(--muted); }
        dd { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; }
        .facts dd { font: 12.5px/1.6 var(--mono); }
        .failure { border-left: 4px solid var(--bad); }
        .failure dt { color: var(--bad); font-weight: 600; }
        ul { margin: 0; padding-left: 20px; }
        li { overflow-wrap: anywhere; }
        main > ul { padding: 12px 20px 12px 36px; }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 8px 12px; border-top: 1px solid var(--line); text-align: left; vertical-align: top; white-space: pre-wrap; }
        thead th { border-top: 0; color: var(--muted); font-size: 12px; font-weight: 600; white-space: nowrap; }
        tbody th { color: var(--muted); font-weight: 500; white-space: nowrap; width: 1%; }
        .timeline td:nth-child(-n+3) { color: var(--muted); font-variant-numeric: tabular-nums; white-space: nowrap; }
        .timeline .pill { white-space: nowrap; }
        .files td:nth-child(2), .files th:nth-child(2) { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
        .files a { font: 12.5px/1.5 var(--mono); overflow-wrap: anywhere; }
        .hash { color: var(--muted); font: 12px/1.5 var(--mono); overflow-wrap: anywhere; }
        .fields td { width: 50%; overflow-wrap: anywhere; }
        .fields .bad > *, .fields .warn > * { background: var(--tint); }
        .fields .bad > th, .fields .warn > th { color: var(--tone); font-weight: 600; }
        .evidence { display: flex; flex-wrap: wrap; align-items: flex-start; gap: 8px; }
        .evidence > a:not(.thumb) { padding: 2px 8px; border: 1px solid var(--line); border-radius: 6px; font: 12px/1.5 var(--mono); }
        .thumb { display: block; line-height: 0; }
        .thumb img { display: block; max-width: 180px; max-height: 220px; border: 1px solid var(--line); border-radius: 8px; }
        figure { display: flex; flex-direction: column; gap: 4px; width: 220px; max-width: 100%; margin: 0; }
        figure a { font: 12px/1.5 var(--mono); overflow-wrap: anywhere; }
        video { display: block; width: 100%; max-height: 360px; border-radius: 8px; background: #000; }
        .step { margin-bottom: 12px; padding: 16px 20px; border-left: 4px solid var(--tone); }
        .step > ul, .step > .empty { margin-top: 10px; }
        .step > ul { font: 12.5px/1.6 var(--mono); white-space: pre-wrap; }
        .step > .thumb { margin-top: 12px; }
        .step > .thumb img { max-width: 100%; max-height: 560px; }
        .index { color: var(--muted); font-variant-numeric: tabular-nums; }
        .sides { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; margin-top: 14px; }
        .sides > div { padding: 12px; border-radius: 8px; background: var(--bg); }
        .sides p { margin-bottom: 8px; }
        @media (max-width: 640px) {
            main { padding: 20px 16px 48px; }
            dl { gap: 4px 12px; padding: 12px 16px; }
            .fields th, .fields td { padding: 6px 10px; }
            .step { padding: 14px; }
            .sides { grid-template-columns: minmax(0, 1fr); }
        }
        @media (max-width: 900px) {
            .timeline, .timeline tbody, .files, .files thead, .files tbody { display: block; }
            .timeline thead { display: none; }
            .timeline tr { position: relative; display: flex; flex-wrap: wrap; align-items: center; gap: 6px 12px; padding: 12px 16px 12px 48px; }
            .files tr { display: grid; grid-template-columns: minmax(0, 1fr) auto; column-gap: 12px; padding: 8px 16px; }
            .timeline tr + tr, .files tr + tr, .files tbody { border-top: 1px solid var(--line); }
            .timeline td, .files th, .files td { padding: 0; border: 0; }
            .timeline td:empty { display: none; }
            .timeline td:nth-child(1) { position: absolute; top: 12px; left: 16px; }
            .timeline td:nth-child(4), .timeline td:nth-child(6) { flex-basis: 100%; }
            .timeline td:nth-child(5) { order: 1; }
            .timeline td:nth-child(2) { order: 2; }
            .timeline td:nth-child(3) { order: 3; }
            .timeline td:nth-child(6) { order: 4; }
            .timeline td[data-label]::before { content: attr(data-label) " "; }
            .files td:nth-child(3), .files th:nth-child(3) { grid-column: 1 / -1; }
        }
        """

    /// Escapes `text` for HTML text and quoted attribute values, one Unicode scalar at a time.
    static func escape(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
                case "&": escaped += "&amp;"
                case "<": escaped += "&lt;"
                case ">": escaped += "&gt;"
                case "\"": escaped += "&quot;"
                case "'": escaped += "&#39;"
                default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    /// `./<path>` percent-encoded, when `path` names a regular file inside `run`.
    static func href(_ path: String, in run: RunStore) -> String? {
        let root = run.directory.resolvingSymlinksInPath().path + "/"
        let file = run.directory.appending(path: path).resolvingSymlinksInPath()
        guard file.path.hasPrefix(root), (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
            let encoded = String(file.path.dropFirst(root.count)).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return "./" + encoded
    }

    /// A thumbnail, a video player or a link for the file at `link`.
    static func media(_ link: String, name: String) -> String {
        let anchor = "<a href=\"\(escape(link))\">\(escape(name))</a>"
        switch URL(filePath: name).pathExtension.lowercased() {
            case "png", "jpg", "jpeg", "heic", "gif":
                let image = "<img src=\"\(escape(link))\" alt=\"\(escape(name))\" loading=\"lazy\">"
                return "<a class=\"thumb\" href=\"\(escape(link))\">\(image)</a>"
            case "mp4", "mov", "m4v":
                return "<figure><video src=\"\(escape(link))\" controls preload=\"metadata\"></video>\(anchor)</figure>"
            default: return anchor
        }
    }

    /// `text` in the muted style of a file that is not shown.
    static func note(_ text: String) -> String {
        "<span class=\"note\">\(escape(text))</span>"
    }

    /// The media and notes of one command in a wrapping row, empty without any.
    static func evidenceList(_ items: [String]) -> String {
        items.isEmpty ? "" : "<div class=\"evidence\">\(items.joined())</div>"
    }

    /// `text` in a rounded label tinted by `style`: ok, bad or warn.
    static func pill(_ text: String, style: String) -> String {
        "<span class=\"pill \(style)\">\(escape(text))</span>"
    }

    static func facts(_ rows: [(String, String)], style: String) -> String {
        "<dl class=\"\(style)\">" + rows.map { "<dt>\(escape($0.0))</dt><dd>\(escape($0.1))</dd>" }.joined() + "</dl>"
    }

    /// A table in a card with one header cell per name in `columns` and the `rows` markup.
    static func table(_ columns: [String], rows: [String], style: String) -> String {
        """
        <div class="card"><table class="\(style)">
        <thead><tr>\(columns.map { "<th>\(escape($0))</th>" }.joined())</tr></thead>
        <tbody>
        \(rows.joined(separator: "\n"))
        </tbody>
        </table></div>
        """
    }

    static func list(_ items: [String], empty: String) -> String {
        items.isEmpty ? "<p class=\"empty\">\(escape(empty))</p>" : "<ul>" + items.map { "<li>\(escape($0))</li>" }.joined() + "</ul>"
    }
}
