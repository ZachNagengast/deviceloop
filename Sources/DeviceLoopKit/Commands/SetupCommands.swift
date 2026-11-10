//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import CryptoKit
import DeviceLoopProtocol
import Foundation
import Security

public enum SetupCommands {
    /// Picks the signing team and stores it in `config.json`, prints the MCP registration for installed
    /// agents (runs it when `apply` is set), and finishes with `doctor`. `dryRun` changes nothing.
    public static func setup(
        team: String?,
        registerAgents: Bool,
        target: Target?,
        apply: Bool = false,
        dryRun: Bool = false
    ) async throws -> CommandResult {
        let signing = await SigningState.read()
        let choice = try TeamChoice.pick(team: team, stored: DeviceLoopConfig.team(), signing: signing)
        var lines = [target?.summary ?? hostSummary, choice.line]

        if let picked = choice.team {
            if dryRun {
                lines.append("would store team \(picked) in \(DeviceLoopConfig.url.path)")
            } else {
                try DeviceLoopConfig.store(team: picked, at: DeviceLoopConfig.url)
                lines.append("stored team \(picked) in \(DeviceLoopConfig.url.path)")
            }
        }

        var agents: [AgentRegistration] = []
        if registerAgents {
            let home = FileManager.default.homeDirectoryForCurrentUser
            agents = AgentRegistration.plan(binary: executablePath, home: home, installed: AgentRegistration.installedAgents(home: home))
            for index in agents.indices where agents[index].installed {
                if dryRun {
                    agents[index].status = "dry run"
                } else if apply {
                    agents[index] = await agents[index].applied()
                }
            }
            lines += AgentRegistration.lines(agents)
            if !apply && !dryRun && agents.contains(where: \.installed) {
                lines.append("Not registered yet. Run `deviceloop setup --yes` to run these, or run them yourself.")
            }
        }
        if dryRun { lines.append("Dry run: nothing was changed.") }

        let doctor = await DoctorReport.run(target)
        lines += doctor.text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().map(String.init)

        let report = SetupReport(
            team: choice.team,
            teamSource: choice.source,
            config: DeviceLoopConfig.url.path,
            dryRun: dryRun,
            agents: agents,
            doctor: doctor
        )
        return try CommandResult(text: lines.joined(separator: "\n"), payload: report)
    }

    /// Checks Xcode, devicectl, the license, signing teams and identities, the capture helper, the runner project, and per target
    /// pairing, Developer Mode, connection, tunnel, lock state, DDI services and the runner session. One fix line per problem.
    /// With no target it checks every iPhone and iPad device plus the booted simulators.
    public static func doctor(_ target: Target?) async throws -> CommandResult {
        let report = await DoctorReport.run(target)
        return try CommandResult(text: report.text, payload: report)
    }

    /// Runs `doctor` and writes a support folder to `directory` with personal values replaced by aliases:
    /// doctor.json, version.txt, runs.json, REDACTIONS.txt and, with `includeRunnerLogs`, runner startup log tails.
    public static func export(_ target: Target?, to directory: URL, includeRunnerLogs: Bool, version: String) async throws
        -> CommandResult
    {
        async let doctor = DoctorReport.run(target)
        async let signing = SigningState.read()
        async let targets = try? Devicectl.listTargets()
        async let xcode = try? Shell.run(["xcodebuild", "-version"], timeout: .seconds(30))

        var redactor = SupportExport.redactor(
            home: FileManager.default.homeDirectoryForCurrentUser.path, targets: [target].compactMap { $0 } + (await targets ?? []),
            signing: await signing, storedTeam: DeviceLoopConfig.team())
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let macOSBuild = ProcessInfo.processInfo.operatingSystemVersionString.firstMatch(of: /Build ([^)]+)/).map { " (\($0.1))" } ?? ""
        let xcodeOutput = await xcode.flatMap { $0.succeeded ? $0.stdoutString : nil }
        let xcodeBuild = xcodeOutput.flatMap { try? RunnerBuild.xcodeBuildVersion($0) }.map { " (\($0))" } ?? ""
        let versions = [
            "DeviceLoop \(version)",
            "macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)\(macOSBuild)",
            (xcodeOutput?.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Xcode not found") + xcodeBuild,
        ]

        let report = await doctor
        let files = try SupportExport.write(
            doctor: report, versions: versions, home: Paths.home, includeRunnerLogs: includeRunnerLogs, redactor: &redactor,
            to: directory)
        let lines = [
            target?.summary ?? hostSummary,
            "exported \(files.joined(separator: ", ")) to \(directory.path)",
            "doctor: \(report.totals)",
            "redacted \(redactor.counts.values.reduce(0, +)) values. Review every file before you share it.",
            "Apple diagnostics, optional and not redacted: xcrun devicectl diagnose, xcrun simctl diagnose",
        ]
        let json: JSONValue = [
            "directory": .string(directory.path),
            "files": .array(files.map(JSONValue.string)),
            "redactions": .object(redactor.counts.reduce(into: [:]) { $0[$1.key.rawValue] = .number(Double($1.value)) }),
            "failures": .number(Double(report.failures)),
            "warnings": .number(Double(report.warnings)),
        ]
        return CommandResult(text: lines.joined(separator: "\n"), json: json)
    }

    /// `This Mac (macOS 27.0.1)`, the header when no target is selected.
    static var hostSummary: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "This Mac (macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion))"
    }

    /// Absolute path of the running binary, with symlinks such as `/opt/homebrew/bin/deviceloop` left unresolved.
    static var executablePath: String {
        let invoked = CommandLine.arguments.first ?? "deviceloop"
        if invoked.contains("/") {
            return URL(filePath: invoked, relativeTo: URL.currentDirectory()).standardizedFileURL.path
        }
        return which(invoked) ?? Bundle.main.executablePath ?? invoked
    }

    /// First executable named `command` on `PATH`.
    static func which(_ command: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return path.split(separator: ":")
            .map { "\($0)/\(command)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

struct SetupReport: Encodable {
    var team: String?
    var teamSource: String?
    var config: String
    var dryRun: Bool
    var agents: [AgentRegistration]
    var doctor: DoctorReport
}

/// The files of `doctor --export`. Reads the doctor report, run manifests and journals, and with runner logs the
/// newest `startup-*/xcodebuild.log` of each runner session. Every string passes through the redactor.
enum SupportExport {
    struct Run: Encodable {
        struct Command: Encodable {
            var command: String
            var outcome: RunEvent.Outcome?
            var code: DeviceLoopError.Code?
            var seconds: Double?
        }

        var id: String
        var status: RunManifest.Status
        var outcome: RunManifest.Outcome?
        var seconds: Double?
        var commands: [Command]
    }

    /// A redactor that knows the home path, the user names, each target's name, UDID, CoreDevice identifier and
    /// tunnel address, the teams and identities in `signing`, and the team in config.json.
    static func redactor(home: String, targets: [Target], signing: SigningState, storedTeam: String?) -> Redactor {
        var redactor = Redactor()
        redactor.add(home, as: .home)
        redactor.add(NSUserName(), as: .user)
        redactor.add(NSFullUserName(), as: .user)
        for target in targets {
            redactor.add(target.name, as: .device)
            redactor.add(target.udid, as: .udid)
            redactor.add(target.identifier, as: .coredevice)
            redactor.add(target.tunnelAddress, as: .tunnel)
        }
        for team in signing.teams {
            redactor.add(team.id, as: .team)
            redactor.add(team.name, as: .teamName)
        }
        for identity in signing.identities {
            redactor.add(identity.name, as: .identity)
            redactor.add(identity.team, as: .team)
        }
        redactor.add(storedTeam, as: .team)
        return redactor
    }

    /// Writes the files to `directory`, which must be new or empty, and returns their names.
    static func write(
        doctor: DoctorReport, versions: [String], home: URL, includeRunnerLogs: Bool, redactor: inout Redactor, to directory: URL
    ) throws -> [String] {
        if FileManager.default.fileExists(atPath: directory.path),
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty != true
        {
            throw DeviceLoopError(
                .badArguments, "\(directory.path) is not an empty folder.", fix: "Pass a new or empty folder to --export.")
        }
        let sessions = home.appending(path: "sessions", directoryHint: .isDirectory)
        let udids = ((try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        for udid in udids { redactor.add(udid, as: .udid) }

        var files = [
            ("doctor.json", try redactor.redact(JSONValue(encoding: doctor)).data(pretty: true)),
            ("version.txt", Data(redactor.redact(versions.joined(separator: "\n") + "\n").utf8)),
            ("runs.json", try redactor.redact(JSONValue(encoding: runs(in: home.appending(path: "runs")))).data(pretty: true)),
        ]
        if includeRunnerLogs {
            for udid in udids {
                guard let tail = logTail(sessions.appending(path: udid, directoryHint: .isDirectory)) else { continue }
                files.append(("runner-\(redactor.redact(udid)).log", Data(redactor.redact(tail).utf8)))
            }
        }
        files.append(("REDACTIONS.txt", Data(notes(redactor.counts).utf8)))
        do {
            try Paths.ensureDirectory(directory)
            for (name, data) in files { try Paths.writePrivate(data, to: directory.appending(path: name)) }
        } catch {
            throw DeviceLoopError(
                .internalError, "Could not write the export.", fix: "Check write permissions at \(directory.path).",
                detail: error.localizedDescription)
        }
        return files.map(\.0)
    }

    /// ID, status, outcome and seconds of every run, and the name, outcome, error code and seconds of each command.
    static func runs(in runs: URL) -> [Run] {
        RunStore.list(in: runs).runs.compactMap { summary in
            let run = RunStore(directory: runs.appending(path: summary.id, directoryHint: .isDirectory))
            guard let manifest = try? run.manifest() else { return nil }
            let events = (try? run.events().events) ?? []
            let finished = Dictionary(
                events.compactMap { event in event.started.map { ($0, event) } }, uniquingKeysWith: { first, _ in first })
            let commands = events.filter { $0.kind == "started" }.map { started in
                let end = finished[started.seq]
                return Run.Command(
                    command: started.command, outcome: end?.outcome, code: end?.error?.code,
                    seconds: end.map { rounded($0.offset - started.offset) })
            }
            let start = RunStore.date(manifest.createdAt)
            let end = manifest.finishedAt.flatMap(RunStore.date)
            let seconds = start.flatMap { start in end.map { rounded($0.timeIntervalSince(start)) } }
            return Run(id: summary.id, status: summary.status, outcome: summary.outcome, seconds: seconds, commands: commands)
        }
    }

    /// The last 200 lines of the newest `startup-*/xcodebuild.log` in a runner session folder.
    static func logTail(_ session: URL) -> String? {
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let startups = (try? FileManager.default.contentsOfDirectory(at: session, includingPropertiesForKeys: nil)) ?? []
        let logs = startups.filter { $0.lastPathComponent.hasPrefix("startup-") }.map { $0.appending(path: "xcodebuild.log") }
        guard let newest = logs.max(by: { modified($0) < modified($1) }), let data = try? Data(contentsOf: newest) else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).suffix(200)
            .joined(separator: "\n")
    }

    /// REDACTIONS.txt: the count for each rule and what to check before sharing.
    static func notes(_ counts: [Redactor.Kind: Int]) -> String {
        let rules = Redactor.Kind.allCases.map { "- \($0.rule): \(counts[$0] ?? 0)" }
        let lines =
            ["DeviceLoop support export", "", "Replacements by rule:"] + rules + [
                "",
                "Aliases are salted per export. A value has one alias in this folder and a different one in the next export.",
                "Left out: session.json, xctestrun files, config.json, screenshots, videos, UI trees, pasteboard contents, "
                    + "typed text and crash reports.",
                "Review every file before you share it. Redaction replaces known values and patterns and can miss others, "
                    + "such as screen text in runner logs.",
            ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// `seconds` rounded to the millisecond.
    static func rounded(_ seconds: Double) -> Double {
        (seconds * 1000).rounded() / 1000
    }
}

/// `Paths.home/config.json`, shared settings such as the signing team.
enum DeviceLoopConfig {
    static var url: URL { Paths.home.appending(path: "config.json") }

    static func team(at url: URL = url) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONValue(data: data))?["team"]?.string
    }

    /// Sets `team` and keeps every other key already in the file.
    static func store(team: String, at url: URL) throws {
        var object = (try? JSONValue(data: Data(contentsOf: url)))?.object ?? [:]
        object["team"] = .string(team)
        try Paths.ensureDirectory(url.deletingLastPathComponent())
        try JSONValue.object(object).data(pretty: true).write(to: url, options: .atomic)
    }
}

struct SigningTeam: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var type: String
    var isFree: Bool

    /// `ABCDE12345 (Example, Inc., Company)`.
    var label: String { "\(id) (\(name), \(isFree ? "free" : type))" }
}

struct SigningIdentity: Codable, Equatable, Sendable {
    var sha1: String
    var name: String
    /// Certificate OU, the team the identity signs for.
    var team: String?

    /// `Apple Development`, `Apple Distribution`, `Developer ID Application` and so on.
    var kind: String { String(name.prefix { $0 != ":" }) }
    var isDevelopment: Bool { kind == "Apple Development" || kind == "iPhone Developer" }
}

/// Teams signed in to Xcode and the code signing identities in the keychain.
struct SigningState: Sendable {
    var teams: [SigningTeam]
    var identities: [SigningIdentity]

    var developmentTeams: Set<String> { Set(identities.filter(\.isDevelopment).compactMap(\.team)) }

    static func read() async -> SigningState {
        async let defaults = try? Shell.run(["defaults", "read", "com.apple.dt.Xcode", "IDEProvisioningTeams"], timeout: .seconds(10))
        async let security = try? Shell.run(["security", "find-identity", "-v", "-p", "codesigning"], timeout: .seconds(10))
        let teams = await defaults.flatMap { $0.succeeded ? parseTeams($0.stdoutString) : nil } ?? []
        var identities = await security.map { parseIdentities($0.stdoutString) } ?? []
        let owners = certificateTeams(for: Set(identities.map(\.sha1)))
        for index in identities.indices {
            identities[index].team = owners[identities[index].sha1]
        }
        return SigningState(teams: teams, identities: identities)
    }

    /// Parses `defaults read com.apple.dt.Xcode IDEProvisioningTeams`: account to list of team dictionaries.
    static func parseTeams(_ text: String) -> [SigningTeam] {
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil),
            let accounts = plist as? [String: [[String: Any]]]
        else { return [] }
        var teams: [SigningTeam] = []
        for entry in accounts.keys.sorted().flatMap({ accounts[$0] ?? [] }) {
            guard let id = entry["teamID"] as? String, !teams.contains(where: { $0.id == id }) else { continue }
            let free = entry["isFreeProvisioningTeam"]
            teams.append(
                SigningTeam(
                    id: id,
                    name: entry["teamName"] as? String ?? id,
                    type: entry["teamType"] as? String ?? "unknown",
                    isFree: (free as? String) == "1" || (free as? Bool) == true
                )
            )
        }
        return teams
    }

    /// Parses `security find-identity -v -p codesigning` lines such as `1) <SHA-1> "Apple Development: Name (ID)"`.
    static func parseIdentities(_ text: String) -> [SigningIdentity] {
        let line = /^\s*\d+\)\s+([0-9A-F]{40})\s+"(.+)"\s*$/
        var identities: [SigningIdentity] = []
        for match in text.split(separator: "\n").compactMap({ try? line.wholeMatch(in: $0) }) {
            let sha1 = String(match.1)
            if !identities.contains(where: { $0.sha1 == sha1 }) {
                identities.append(SigningIdentity(sha1: sha1, name: String(match.2)))
            }
        }
        return identities
    }

    /// Team IDs (certificate OU) of keychain certificates whose SHA-1 is in `hashes`.
    static func certificateTeams(for hashes: Set<String>) -> [String: String] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true,
        ]
        var items: CFTypeRef?
        guard !hashes.isEmpty, SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
            let certificates = items as? [SecCertificate]
        else { return [:] }

        var teams: [String: String] = [:]
        for certificate in certificates {
            let data = SecCertificateCopyData(certificate) as Data
            let sha1 = Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
            guard hashes.contains(sha1),
                let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1SubjectName] as CFArray, nil) as? [String: Any],
                let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
                let fields = subject[kSecPropertyKeyValue as String] as? [[String: Any]],
                let unit = fields.first(where: { $0[kSecPropertyKeyLabel as String] as? String == kSecOIDOrganizationalUnitName as String })
            else { continue }
            teams[sha1] = unit[kSecPropertyKeyValue as String] as? String
        }
        return teams
    }
}

/// The team setup stores, and where it came from.
struct TeamChoice: Equatable {
    var team: String?
    /// `--team`, `config.json` or `Xcode`. Nil when nothing was found.
    var source: String?
    var line: String

    /// `--team`, then the stored team, then an Xcode team. Among Xcode teams, ones with an Apple Development
    /// identity come first, then paid teams.
    static func pick(team requested: String?, stored: String?, signing: SigningState) throws -> TeamChoice {
        func label(_ id: String) -> String { signing.teams.first { $0.id == id }?.label ?? id }
        func rank(_ team: SigningTeam) -> (Int, Int, String) {
            (signing.developmentTeams.contains(team.id) ? 0 : 1, team.isFree ? 1 : 0, team.id)
        }

        if let requested {
            let id = requested.uppercased()
            guard id.wholeMatch(of: /[A-Z0-9]{10}/) != nil else {
                throw DeviceLoopError(
                    .badArguments,
                    "\(requested) is not a team ID.",
                    fix: "Pass the 10-character ID from Xcode > Settings > Accounts, for example --team ABCDE12345."
                )
            }
            let known = signing.teams.contains { $0.id == id }
            return TeamChoice(team: id, source: "--team", line: "team: \(label(id)) from --team\(known ? "" : ", not signed in to Xcode")")
        }
        if let stored {
            return TeamChoice(
                team: stored,
                source: "config.json",
                line: "team: \(label(stored)) from config.json. Pass --team to change it."
            )
        }
        let ranked = signing.teams.sorted { rank($0) < rank($1) }
        guard let first = ranked.first else {
            return TeamChoice(
                team: nil,
                source: nil,
                line: "team: none found. Sign in to Xcode > Settings > Accounts, then run `deviceloop setup --team <ID>`."
            )
        }
        let others = ranked.dropFirst().map(\.id)
        let rest = others.isEmpty ? "" : ". Other teams: \(others.joined(separator: ", ")). Pass --team to pick one."
        return TeamChoice(team: first.id, source: "Xcode", line: "team: \(first.label) from Xcode\(rest)")
    }
}

/// One agent's MCP registration: a command to run, or (Cursor) a JSON file to merge into.
struct AgentRegistration: Encodable, Equatable, Sendable {
    var agent: String
    var installed: Bool
    /// The server command line the agent will start: the absolute binary path and `mcp`.
    var server: [String]
    var command: [String]?
    var configFile: String?
    /// `not installed`, `printed`, `dry run`, `registered` or `failed: <reason>`.
    var status: String

    /// Agents whose CLI is on `PATH`, plus Cursor when `~/.cursor` exists.
    static func installedAgents(home: URL) -> Set<String> {
        var installed = Set(["claude", "codex", "gemini"].filter { SetupCommands.which($0) != nil })
        if FileManager.default.fileExists(atPath: home.appending(path: ".cursor").path) { installed.insert("cursor") }
        return installed
    }

    static func plan(binary: String, home: URL, installed: Set<String>) -> [AgentRegistration] {
        let server = [binary, "mcp"]
        func registration(_ agent: String, command: [String]? = nil, configFile: String? = nil) -> AgentRegistration {
            let isInstalled = installed.contains(agent)
            return AgentRegistration(
                agent: agent,
                installed: isInstalled,
                server: server,
                command: command,
                configFile: configFile,
                status: isInstalled ? "printed" : "not installed"
            )
        }
        return [
            registration("claude", command: ["claude", "mcp", "add", "-s", "user", "deviceloop", "--"] + server),
            registration("codex", command: ["codex", "mcp", "add", "deviceloop", "--"] + server),
            registration("cursor", configFile: home.appending(path: ".cursor/mcp.json").path),
            registration("gemini", command: ["gemini", "mcp", "add", "-s", "user", "deviceloop"] + server),
        ]
    }

    /// One line per installed agent with what runs (or ran), then the agents that were not found.
    static func lines(_ registrations: [AgentRegistration]) -> [String] {
        var lines: [String] = []
        for registration in registrations where registration.installed {
            let action: String
            if let command = registration.command {
                action = command.map(shellQuoted).joined(separator: " ")
            } else {
                let entry = try? JSONValue.object(["deviceloop": registration.cursorEntry]).data()
                let snippet = entry.map { String(decoding: $0, as: UTF8.self) } ?? ""
                action = "add \(snippet) under mcpServers in \(registration.configFile ?? "")"
            }
            switch registration.status {
                case "printed", "dry run": lines.append("\(registration.agent): \(action)")
                default: lines.append("\(registration.agent): \(registration.status), \(action)")
            }
        }
        let missing = registrations.filter { !$0.installed }.map(\.agent)
        if !missing.isEmpty { lines.append("not installed: \(missing.joined(separator: ", "))") }
        return lines
    }

    var cursorEntry: JSONValue {
        ["command": .string(server[0]), "args": .array(server.dropFirst().map { .string($0) })]
    }

    /// Runs the command, or merges the entry into the config file.
    func applied() async -> AgentRegistration {
        var result = self
        do {
            if let command {
                let shell = try await Shell.run(command, timeout: .seconds(60))
                let output = (shell.stderrString + shell.stdoutString).trimmingCharacters(in: .whitespacesAndNewlines)
                result.status = shell.succeeded ? "registered" : "failed: \(output.split(separator: "\n").first ?? "exit \(shell.status)")"
            } else if let configFile {
                let url = URL(filePath: configFile)
                let merged = try Self.mergeServer(cursorEntry, into: try? Data(contentsOf: url), file: configFile)
                try merged.write(to: url, options: .atomic)
                result.status = "registered"
            }
        } catch let error as DeviceLoopError {
            result.status = "failed: \(error.message)"
        } catch {
            result.status = "failed: \(error)"
        }
        return result
    }

    /// Sets `mcpServers.deviceloop` in an `mcp.json` document and keeps everything else.
    static func mergeServer(_ entry: JSONValue, into existing: Data?, file: String) throws -> Data {
        var root: [String: JSONValue] = [:]
        if let existing, !existing.isEmpty {
            guard let object = (try? JSONValue(data: existing))?.object else {
                throw DeviceLoopError(.badArguments, "\(file) is not a JSON object, so it was left unchanged.")
            }
            root = object
        }
        var servers = root["mcpServers"]?.object ?? [:]
        servers["deviceloop"] = entry
        root["mcpServers"] = .object(servers)
        return try JSONValue.object(root).data(pretty: true)
    }

    /// Quotes `argument` for a POSIX shell when it has anything beyond safe characters.
    static func shellQuoted(_ argument: String) -> String {
        if !argument.isEmpty, argument.wholeMatch(of: /[A-Za-z0-9_@%+=:,.\/-]+/) != nil { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct DoctorCheck: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case ok
        case warn
        case fail
    }

    var name: String
    var status: Status
    var detail: String
    var fix: String?
    /// The error code a command would fail with, for warnings and failures.
    var code: DeviceLoopError.Code?

    init(_ name: String, _ status: Status, _ detail: String, fix: String? = nil, code: DeviceLoopError.Code? = nil) {
        self.name = name
        self.status = status
        self.detail = detail
        self.fix = fix
        self.code = code
    }

    /// A check that could not run, with the error's message and fix.
    init(_ name: String, failedWith error: Error, status: Status = .warn) {
        let error = error as? DeviceLoopError ?? DeviceLoopError(.internalError, "\(error)")
        self.init(name, status, error.message, fix: error.fix, code: error.code)
    }

    /// `ok   xcode: Xcode 27.1 (27A9275)`, plus an indented fix line.
    var lines: [String] {
        let label = status.rawValue.padding(toLength: 4, withPad: " ", startingAt: 0)
        return ["\(label) \(name): \(detail)"] + (fix.map { ["     fix: \($0)"] } ?? [])
    }
}

struct DoctorReport: Encodable, Sendable {
    struct Section: Encodable, Sendable {
        var udid: String
        var name: String
        var kind: Target.Kind
        var summary: String
        var checks: [DoctorCheck]

        init(_ target: Target, checks: [DoctorCheck]) {
            udid = target.udid
            name = target.name
            kind = target.kind
            summary = target.summary
            self.checks = checks
        }
    }

    /// First line of the text: the selected target, or this Mac.
    var header: String
    var host: [DoctorCheck]
    var targets: [Section]

    var failures: Int { (host + targets.flatMap(\.checks)).filter { $0.status == .fail }.count }
    var warnings: Int { (host + targets.flatMap(\.checks)).filter { $0.status == .warn }.count }

    /// `all checks passed`, or the failure and warning counts.
    var totals: String { failures + warnings == 0 ? "all checks passed" : "\(failures) failed, \(warnings) warnings" }

    var text: String {
        var lines = [header] + host.flatMap(\.lines)
        for section in targets {
            if section.summary != header { lines.append(section.summary) }
            lines += section.checks.flatMap(\.lines)
        }
        lines.append(totals)
        return lines.joined(separator: "\n")
    }

    private enum CodingKeys: String, CodingKey {
        case ok, failures, warnings, host, targets
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(failures == 0, forKey: .ok)
        try container.encode(failures, forKey: .failures)
        try container.encode(warnings, forKey: .warnings)
        try container.encode(host, forKey: .host)
        try container.encode(targets, forKey: .targets)
    }

    static func run(_ target: Target?) async -> DoctorReport {
        async let hostChecks = Self.hostChecks()
        async let preferredDDI = Self.hostDDICheck()
        var extra: [DoctorCheck] = []
        var targets: [Target] = []
        if let target {
            targets = [target]
        } else {
            do {
                targets = try await Devicectl.listTargets()
                    .filter(listed)
                    .sorted { ($0.kind == .device ? 0 : 1, $0.name) < ($1.kind == .device ? 0 : 1, $1.name) }
                if targets.isEmpty {
                    extra.append(
                        DoctorCheck(
                            "targets",
                            .warn,
                            "no iPhone or iPad paired and no booted simulator",
                            fix: TargetResolver.noTargetsFix,
                            code: .deviceNotFound
                        )
                    )
                }
            } catch {
                extra.append(DoctorCheck("targets", failedWith: error, status: .fail))
            }
        }

        let hostDDI = await preferredDDI
        let selected = target != nil
        let sections = await withTaskGroup(of: (Int, Section).self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask { (index, Section(target, checks: await Self.checks(for: target, hostDDI: hostDDI, selected: selected))) }
            }
            var collected: [(Int, Section)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }

        var host = await hostChecks
        if host.contains(where: { $0.name == "devicectl" && $0.status == .fail }) {
            extra.removeAll { $0.name == "targets" }
        } else {
            host.append(hostDDI)
        }
        return DoctorReport(header: target?.summary ?? SetupCommands.hostSummary, host: host + extra, targets: sections)
    }

    /// Devices and booted simulators, the targets `prepare --all` prepares.
    static func checked(_ target: Target) -> Bool {
        target.isDrivable && (target.kind == .device || target.isReady)
    }

    /// The targets doctor checks when none is selected: the `checked` ones and targets with an open state scope.
    static func listed(_ target: Target) -> Bool {
        checked(target) || target.isDrivable && ChangeJournal(udid: target.udid).isOpen
    }

    static func hostChecks() async -> [DoctorCheck] {
        async let developerDir = try? Shell.run(["xcode-select", "-p"], timeout: .seconds(10))
        async let xcodeVersion = try? Shell.run(["xcodebuild", "-version"], timeout: .seconds(30))
        async let devicectl = try? Shell.run(["xcrun", "devicectl", "--version"], timeout: .seconds(30))
        async let license = try? Shell.run(["xcodebuild", "-license", "check"], timeout: .seconds(30))
        async let firstLaunch = try? Shell.run(["xcodebuild", "-checkFirstLaunchStatus"], timeout: .seconds(30))
        async let signing = SigningState.read()

        let selected = await developerDir.flatMap { $0.succeeded ? $0.stdoutString : nil }
        let version = await xcodeVersion.flatMap { $0.succeeded ? $0.stdoutString : nil }
        let xcode = xcodeCheck(developerDir: selected, versionOutput: version)
        var checks = [xcode, devicectlCheck(versionOutput: await devicectl.flatMap { $0.succeeded ? $0.stdoutString : nil })]
        if xcode.status != .fail {
            if await license?.succeeded == true {
                checks.append(DoctorCheck("license", .ok, "accepted"))
            } else {
                checks.append(DoctorCheck("license", .fail, "not accepted", fix: "sudo xcodebuild -license accept", code: .xcodeMissing))
            }
            if await firstLaunch?.succeeded == true {
                checks.append(DoctorCheck("first launch", .ok, "done"))
            } else {
                let fix = "sudo xcodebuild -runFirstLaunch"
                checks.append(DoctorCheck("first launch", .fail, "tasks pending", fix: fix, code: .xcodeMissing))
            }
        }
        checks += signingChecks(await signing, stored: DeviceLoopConfig.team())
        let bundled = Paths.bundledCaptureApp()
        let bundledProblem: String? = if let bundled { await CaptureApp.signatureProblem(bundled) } else { nil }
        checks.append(captureHelperCheck(home: Paths.home, bundled: bundled, bundledProblem: bundledProblem))
        checks.append(runnerProjectCheck(Paths.runnerProject))
        return checks
    }

    /// From `xcode-select -p` and `xcodebuild -version` output. Nil means the command failed.
    static func xcodeCheck(developerDir: String?, versionOutput: String?) -> DoctorCheck {
        let select = "sudo xcode-select -s /Applications/Xcode.app"
        let install = "Install Xcode, then run: \(select)"
        guard let path = developerDir?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return DoctorCheck("xcode", .fail, "no developer directory selected", fix: install, code: .xcodeMissing)
        }
        guard !path.contains("CommandLineTools"), let versionOutput else {
            return DoctorCheck("xcode", .fail, "\(path) is not a full Xcode", fix: install, code: .xcodeMissing)
        }
        let lines = versionOutput.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let name = lines.first ?? "Xcode"
        let build = lines.first { $0.hasPrefix("Build version ") }?.dropFirst("Build version ".count)
        let detail = "\(name)\(build.map { " (\($0))" } ?? "") at \(path)"
        let major = Int(name.split(separator: " ").last?.split(separator: ".").first ?? "") ?? 0
        if major < 27 {
            return DoctorCheck("xcode", .warn, detail, fix: "DeviceLoop is tested with Xcode 27. Install it, then run: \(select)")
        }
        return DoctorCheck("xcode", .ok, detail)
    }

    static func devicectlCheck(versionOutput: String?) -> DoctorCheck {
        guard let version = versionOutput?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else {
            return DoctorCheck(
                "devicectl",
                .fail,
                "not found in the selected Xcode",
                fix: "Install Xcode 27 or later and run: sudo xcode-select -s /Applications/Xcode.app",
                code: .xcodeMissing
            )
        }
        return DoctorCheck("devicectl", .ok, version)
    }

    /// Teams in Xcode, Apple Development identities, and the team DeviceLoop stored.
    static func signingChecks(_ signing: SigningState, stored: String?) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        if signing.teams.isEmpty {
            checks.append(
                DoctorCheck(
                    "teams",
                    .warn,
                    "no team signed in to Xcode. UI commands on devices will need one",
                    fix: "Add your Apple ID in Xcode > Settings > Accounts.",
                    code: .signingNoTeam
                )
            )
        } else {
            checks.append(DoctorCheck("teams", .ok, signing.teams.map(\.label).joined(separator: ", ")))
        }

        let development = signing.developmentTeams.sorted()
        let count = "\(signing.identities.count) valid identit\(signing.identities.count == 1 ? "y" : "ies")"
        if development.isEmpty {
            checks.append(
                DoctorCheck(
                    "identities",
                    .warn,
                    "no Apple Development identity (\(count))",
                    fix: "Xcode creates one on the first signed build, or add one in Xcode > Settings > Accounts > Manage Certificates."
                )
            )
        } else {
            checks.append(DoctorCheck("identities", .ok, "Apple Development for \(development.joined(separator: ", ")) (\(count))"))
        }

        let suggestion = (try? TeamChoice.pick(team: nil, stored: nil, signing: signing))?.team ?? "<ID>"
        if let stored {
            if !signing.teams.isEmpty && !signing.teams.contains(where: { $0.id == stored }) {
                checks.append(
                    DoctorCheck(
                        "deviceloop team",
                        .warn,
                        "\(stored) is not signed in to Xcode",
                        fix: "deviceloop setup --team \(suggestion)",
                        code: .signingNoTeam
                    )
                )
            } else {
                checks.append(DoctorCheck("deviceloop team", .ok, "\(stored) in \(DeviceLoopConfig.url.path)"))
            }
        } else {
            checks.append(DoctorCheck("deviceloop team", .warn, "none stored", fix: "deviceloop setup", code: .signingNoTeam))
        }
        return checks
    }

    /// The `bundled` helper when its signature verifies, else `home/DeviceLoopCapture.app`, which `video record` builds
    /// on the first USB device recording. Its camera permission belongs to the helper, so DeviceLoop cannot read it from here.
    static func captureHelperCheck(home: URL, bundled: URL?, bundledProblem: String?) -> DoctorCheck {
        let built = home.appending(path: "DeviceLoopCapture.app")
        if let bundled {
            guard let bundledProblem else {
                return DoctorCheck("capture helper", .ok, "bundled \(bundled.path), camera permission not readable")
            }
            return DoctorCheck(
                "capture helper",
                .warn,
                "bundled \(bundled.path) fails codesign --verify --strict: \(bundledProblem). video record uses \(built.path)",
                fix: "Reinstall DeviceLoop, for example with `brew reinstall deviceloop`."
            )
        }
        guard FileManager.default.fileExists(atPath: built.appending(path: "Contents/Info.plist").path) else {
            return DoctorCheck(
                "capture helper",
                .warn,
                "not built yet. Screen video from USB devices needs it",
                fix: "Run `deviceloop video record` on a USB device once, then click Allow when macOS asks for camera access."
            )
        }
        return DoctorCheck("capture helper", .ok, "built \(built.path), camera permission not readable")
    }

    /// The runner project UI commands build from, or a failure when there is none.
    static func runnerProjectCheck(_ project: URL?) -> DoctorCheck {
        guard let project else { return DoctorCheck("runner project", failedWith: RunnerBuild.missingProject, status: .fail) }
        return DoctorCheck("runner project", .ok, project.path)
    }

    /// The iOS developer disk image on this Mac that CoreDevice would mount.
    static func hostDDICheck() async -> DoctorCheck {
        do {
            return hostDDICheck(try await Devicectl.run(["list", "preferredDDI", "--platform", "iOS"], timeout: .seconds(30)))
        } catch {
            return DoctorCheck("host ddi", failedWith: error)
        }
    }

    /// From `devicectl list preferredDDI --platform iOS`: `ddiMetadata.isUsable`, `contentIsCompatible` and `buildUpdate`,
    /// and `hostDDI`.
    static func hostDDICheck(_ result: JSONValue) -> DoctorCheck {
        let preferred = result.value(at: "platforms.iOS")?[0]
        let metadata = preferred?["ddiMetadata"]
        let build = metadata?["buildUpdate"]?.string ?? "unknown build"
        let path = preferred?["hostDDI"]?.string.flatMap(URL.init(string:))?.path ?? "an unknown path"
        let image = "iOS \(build) at \(path)"
        var problem: String?
        if preferred == nil {
            problem = "no iOS developer disk image on this Mac"
        } else if metadata?["isUsable"]?.bool != true {
            problem = "\(image) is not usable"
        } else if metadata?["contentIsCompatible"]?.bool != true {
            problem = "\(image) has incompatible content"
        }
        guard let problem else { return DoctorCheck("host ddi", .ok, image) }
        return DoctorCheck(
            "host ddi",
            .warn,
            problem,
            fix: "Run `sudo xcodebuild -runFirstLaunch -checkForNewerComponents` or `xcrun devicectl manage ddis update`.",
            code: .ddiUnavailable
        )
    }

    static func checks(for target: Target, hostDDI: DoctorCheck, selected: Bool = true) async -> [DoctorCheck] {
        var checks = stateChecks(target, selected: selected)
        if let scope = scopeCheck(target) { checks.append(scope) }
        let session = SessionFile.read(for: target.udid)
        var answered: Bool?
        if !target.isSimulator, target.connectionState == "connected" {
            async let lock: DoctorCheck? = target.supports(Capability.lockState) ? Self.lockCheck(target) : nil
            async let ddi = Self.ddiCheck(target, host: hostDDI)
            async let live = RunnerSession.liveHealth(target)
            if let lock = await lock { checks.append(lock) }
            checks.append(await ddi)
            let health = await live
            answered = health != nil
            checks.append(
                automationCheck(
                    health, enabledAt: RunnerSession.automationEnabledAt(for: target.udid), deviceLoopVersion: session?.deviceLoopVersion,
                    target: target))
        }
        checks.append(runnerCheck(target, session: session, answered: answered))
        return checks
    }

    /// From the session file and the process table. `answered` is whether the runner answered doctor's health check, nil
    /// when doctor did not ask. Warns when the device tunnel moved away from the session's address, and when a running host
    /// process has a runner that does not answer, or was not asked on a device with no tunnel address.
    static func runnerCheck(
        _ target: Target,
        session: SessionFile?,
        answered: Bool? = nil,
        process: (SessionFile) -> RunnerProcess.State = { RunnerProcess.state(of: $0.pid, matching: $0.processIdentity) }
    ) -> DoctorCheck {
        guard let session else { return DoctorCheck("runner", .ok, "no session") }
        let state = process(session)
        if session.stopping == true, state != .exited {
            return DoctorCheck("runner", failedWith: RunnerSession.teardownIncomplete(target))
        }
        let address = "\(session.host):\(session.port)"
        guard let current = session.movedTunnel(on: target) else {
            var problem: String?
            if answered == false {
                problem = "runner does not answer"
            } else if answered == nil, !target.isSimulator, target.tunnelAddress == nil {
                problem = "device has no tunnel address"
            }
            guard state == .running, let problem else {
                return DoctorCheck("runner", .ok, "session at \(address), host process \(state)")
            }
            return DoctorCheck(
                "runner",
                .warn,
                "session at \(address), host process running, \(problem)",
                fix: "deviceloop runner stop --device \(target.udid), then run the UI command again.",
                code: .runnerUnreachable
            )
        }
        let detail = "session at \(address), but the device tunnel moved to \(current), host process \(state)"
        guard state == .exited else {
            return DoctorCheck(
                "runner",
                .warn,
                detail,
                fix: "deviceloop runner stop --device \(target.udid), then wait for teardown before the next UI command.",
                code: .runnerUnreachable
            )
        }
        return DoctorCheck(
            "runner",
            .warn,
            detail,
            fix: "The next UI command starts a new runner. To start it now: deviceloop runner start --device \(target.udid)"
        )
    }

    /// Ok while a runner that this DeviceLoop version started answers its health check. `deviceLoopVersion` is the version in
    /// the session file. Without a live runner, starting one may ask for the passcode, and `enabledAt` from
    /// `automation.json` says when a runner last became ready.
    static func automationCheck(
        _ health: HealthResult?, enabledAt: String?, deviceLoopVersion: String?, target: Target, now: Date = Date()
    ) -> DoctorCheck {
        guard let health else {
            return DoctorCheck(
                "ui automation",
                .warn,
                "no live runner. Starting one may ask for the passcode on \(target.name)"
                    + (enabledAt.map { ", last enabled \($0)" } ?? ""),
                fix: "Run `deviceloop prepare --device \(target.udid)` while you can enter the passcode on \(target.name).",
                code: .uiAutomationPasscode
            )
        }
        do {
            try RunnerSession.validateHealth(health)
        } catch {
            return DoctorCheck("ui automation", failedWith: error)
        }
        guard deviceLoopVersion == version else {
            return DoctorCheck(
                "ui automation",
                .warn,
                "runner started by another DeviceLoop version. The next UI command replaces it",
                fix: "deviceloop prepare --device \(target.udid)"
            )
        }
        return DoctorCheck("ui automation", .ok, "runner live since \(now.addingTimeInterval(-health.uptimeS).formatted(.iso8601))")
    }

    /// Checks read from `devicectl list devices`: boot state for simulators, pairing, Developer Mode,
    /// connection, transport and tunnel for devices. A simulator that is not booted fails when `selected`, else warns.
    static func stateChecks(_ target: Target, selected: Bool = true) -> [DoctorCheck] {
        if target.isSimulator {
            guard target.isReady else {
                let boot = "xcrun simctl boot \(target.udid)"
                let status: DoctorCheck.Status = selected ? .fail : .warn
                return [DoctorCheck("boot", status, target.bootState ?? "not booted", fix: boot, code: .deviceOffline)]
            }
            return [DoctorCheck("boot", .ok, "booted")]
        }

        var checks: [DoctorCheck] = []
        checks.append(
            target.paired
                ? DoctorCheck("pairing", .ok, "paired")
                : DoctorCheck(
                    "pairing",
                    .fail,
                    "not paired with this Mac",
                    fix: "Unlock \(target.name), tap Trust and enter the passcode, then run deviceloop doctor again.",
                    code: .trustRequired
                )
        )

        switch target.developerModeEnabled {
            case true?:
                checks.append(DoctorCheck("developer mode", .ok, "enabled"))
            case false?:
                checks.append(
                    DoctorCheck(
                        "developer mode",
                        .fail,
                        "off",
                        fix: "On \(target.name): Settings > Privacy & Security > Developer Mode, then restart. "
                            + "If the switch is missing, run any Xcode build to the device once.",
                        code: .developerModeOff
                    )
                )
            case nil:
                checks.append(DoctorCheck("developer mode", .warn, "unknown, devicectl did not report it"))
        }

        guard target.connectionState == "connected" else {
            checks.append(
                DoctorCheck(
                    "connection",
                    .fail,
                    target.connectionState,
                    fix: "Connect \(target.name) with a cable or join the same network, unlock it, and run deviceloop doctor again.",
                    code: .deviceOffline
                )
            )
            return checks
        }

        switch target.transport {
            case "wired":
                checks.append(DoctorCheck("connection", .ok, "connected over USB"))
            case "localNetwork":
                checks.append(
                    DoctorCheck(
                        "connection",
                        .warn,
                        "connected over the network",
                        fix: "Connect a USB cable. Screen video from devices needs USB."
                    )
                )
            default:
                checks.append(DoctorCheck("connection", .ok, "connected over \(target.transport ?? "an unknown transport")"))
        }

        checks.append(
            target.tunnelAddress.map { DoctorCheck("tunnel", .ok, $0) }
                ?? DoctorCheck(
                    "tunnel",
                    .warn,
                    "no tunnel address",
                    fix: "Unlock \(target.name) and reconnect it, then run deviceloop doctor again.",
                    code: .deviceOffline
                )
        )
        return checks
    }

    /// The pending changes of an open state scope, which `deviceloop state restore` sets back. Nil without a scope.
    static func scopeCheck(_ target: Target) -> DoctorCheck? {
        let journal = ChangeJournal(udid: target.udid)
        guard journal.isOpen else { return nil }
        do {
            let (scope, entries) = try journal.lines()
            let fields = ChangeJournal.pending(entries).map(\.field)
            guard !fields.isEmpty else { return DoctorCheck("state scope", .ok, "open since \(scope.at), no pending changes") }
            return DoctorCheck(
                "state scope",
                .warn,
                "\(fields.count) pending change\(fields.count == 1 ? "" : "s") since \(scope.at): \(fields.joined(separator: ", "))",
                fix: "deviceloop state restore --device \(target.udid)"
            )
        } catch {
            return DoctorCheck("state scope", failedWith: error)
        }
    }

    static func lockCheck(_ target: Target) async -> DoctorCheck {
        do {
            let arguments = Devicectl.device(target, "info", "lockState")
            return lockCheck(try await Devicectl.run(arguments, target: target, timeout: .seconds(20)), target: target)
        } catch let error as DeviceLoopError where error.code == .deviceError {
            let transport = target.transport == "localNetwork" ? " over the network" : ""
            return DoctorCheck(
                "lock",
                .warn,
                "unknown, devicectl could not read it\(transport)",
                fix: "Connect \(target.name) with a cable and unlock it, then run deviceloop doctor again.",
                code: .deviceError
            )
        } catch {
            return DoctorCheck("lock", failedWith: error)
        }
    }

    /// From `devicectl device info lockState`: `passcodeRequired` and `unlockedSinceBoot`.
    static func lockCheck(_ state: JSONValue, target: Target) -> DoctorCheck {
        if state["passcodeRequired"]?.bool == true {
            return DoctorCheck("lock", .warn, "locked", fix: "Unlock \(target.name).", code: .deviceLocked)
        }
        if state["unlockedSinceBoot"]?.bool == false {
            return DoctorCheck("lock", .warn, "not unlocked since restart", fix: "Unlock \(target.name).", code: .deviceLocked)
        }
        return DoctorCheck("lock", .ok, "unlocked")
    }

    /// Reads the DDI state without mounting anything.
    static func ddiCheck(_ target: Target, host: DoctorCheck) async -> DoctorCheck {
        do {
            let result = try await Devicectl.run(
                Devicectl.device(target, "info", "ddiServices") + ["--no-auto-mount-ddis"],
                target: target,
                timeout: .seconds(20)
            )
            return ddiCheck(result, target: target, host: host)
        } catch {
            return DoctorCheck("ddi services", failedWith: error)
        }
    }

    /// From `devicectl device info ddiServices`: `ddiMetadata.isUsable` and `buildUpdate`. Without a mounted image, the fix
    /// is the `host` fix when the host check found no usable image.
    static func ddiCheck(_ result: JSONValue, target: Target, host: DoctorCheck) -> DoctorCheck {
        guard result.value(at: "ddiMetadata.isUsable")?.bool == true else {
            if host.code == .ddiUnavailable {
                return DoctorCheck(
                    "ddi services",
                    .warn,
                    "developer disk image not mounted, and this Mac has no usable image to mount",
                    fix: host.fix,
                    code: .ddiUnavailable
                )
            }
            return DoctorCheck(
                "ddi services",
                .warn,
                "developer disk image not mounted",
                fix: "deviceloop prepare --device \(target.udid)",
                code: .ddiUnavailable
            )
        }
        let build = result.value(at: "ddiMetadata.buildUpdate")?.string
        return DoctorCheck("ddi services", .ok, "usable\(build.map { " (\($0))" } ?? "")")
    }
}
