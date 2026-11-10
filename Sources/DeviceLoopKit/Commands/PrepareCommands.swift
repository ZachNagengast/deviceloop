//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

public enum PrepareCommands {
    /// Every device and booted simulator doctor checks when `all` is set, else the target `device` names.
    public static func targets(device: String?, all: Bool) async throws -> [Target] {
        guard all else { return [try await TargetResolver.resolve(device)] }
        guard device == nil else { throw DeviceLoopError.usage("Pass a device or all, not both.") }
        let targets = try await Devicectl.listTargets().filter(DoctorReport.checked)
        guard !targets.isEmpty else {
            throw DeviceLoopError(
                .deviceNotFound,
                "No iPhone or iPad paired and no booted simulator.",
                fix: TargetResolver.noTargetsFix
            )
        }
        return targets
    }

    /// `deviceloop prepare`: plans the steps doctor shows are missing on each target, runs them unless `dryRun`, waiting up to
    /// `wait` seconds for each owner step and restarting the runner for `ownerWait` seconds after a passcode prompt times out,
    /// then re-runs doctor per target. With `pair`, an unpaired device is asked to pair before the pair step waits.
    /// Targets run concurrently. `log` gets owner prompts and runner startup lines, prefixed with the target name when
    /// there are several targets.
    public static func prepare(
        _ targets: [Target], dryRun: Bool, wait: Int, ownerWait: Int = 0, pair: Bool = false,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        let reports = try await withThrowingTaskGroup(of: (Int, PrepareReport).self) { group in
            for (index, target) in targets.enumerated() {
                let targetLog = targets.count > 1 ? prefixedLog(log, for: target) : log
                group.addTask {
                    (index, try await prepare(target, dryRun: dryRun, wait: wait, ownerWait: ownerWait, pair: pair, log: targetLog))
                }
            }
            var collected: [(Int, PrepareReport)] = []
            for try await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }

        let payload: JSONValue = [
            "ok": .bool(reports.allSatisfy(\.ready)),
            "dryRun": .bool(dryRun),
            "targets": try JSONValue(encoding: reports),
        ]
        return CommandResult(text: text(reports, dryRun: dryRun), json: payload)
    }

    /// `log` with `<target name>: ` before each line.
    static func prefixedLog(_ log: @escaping @Sendable (String) -> Void, for target: Target) -> @Sendable (String) -> Void {
        { log("\(target.name): \($0)") }
    }

    /// The header, then per target its plan, doctor checks and readiness. With several targets the host checks follow the
    /// header once, and each target has only its own checks and doctor totals.
    static func text(_ reports: [PrepareReport], dryRun: Bool) -> String {
        let single = reports.count == 1
        var lines = [single ? reports[0].summary : SetupCommands.hostSummary]
        if !single { lines += reports.first?.doctor.host.flatMap(\.lines) ?? [] }
        for report in reports {
            if report.summary != lines[0] { lines.append(report.summary) }
            lines += report.steps.isEmpty ? ["plan: nothing to do"] : report.steps.flatMap(\.lines)
            let doctorLines = report.doctor.text.split(separator: "\n").map(String.init)
            if single {
                lines += doctorLines.dropFirst()
            } else {
                lines += report.doctor.targets.flatMap(\.checks).flatMap(\.lines) + doctorLines.suffix(1)
            }
            lines.append(report.ready ? "ready" : "not ready")
        }
        if dryRun { lines.append("Dry run: nothing was run.") }
        return lines.joined(separator: "\n")
    }

    private static func prepare(
        _ target: Target, dryRun: Bool, wait: Int, ownerWait: Int, pair: Bool, log: @escaping @Sendable (String) -> Void
    ) async throws -> PrepareReport {
        let before = await DoctorReport.run(target)
        let runnerLive = before.targets.flatMap(\.checks).contains { $0.name == "ui automation" && $0.status == .ok }
        var execution = PrepareRun(
            target: target,
            hostDDI: before.host.first { $0.name == "host ddi" } ?? DoctorCheck("host ddi", .ok, "not checked"),
            wait: wait,
            ownerWait: .seconds(ownerWait),
            pair: pair,
            log: log,
            devicectl: { try await Devicectl.run($0, target: target, timeout: .seconds(120)) }
        )
        let plan = PrepareRun.plan(for: target, doctor: before, runnerLive: runnerLive, pair: pair)
        let steps = try await execution.run(plan, dryRun: dryRun)
        guard !dryRun else { return PrepareReport(target: target, steps: steps, doctor: before) }
        let current = (try? await Devicectl.listTargets())?.first { $0.udid == target.udid } ?? execution.target
        return PrepareReport(target: current, steps: steps, doctor: await DoctorReport.run(current))
    }
}

/// One step of `deviceloop prepare`, done by the person at the device or by DeviceLoop.
struct PrepareStep: Encodable, Equatable, Sendable {
    enum Kind: String, Encodable, Sendable, CaseIterable {
        case pair
        case developerMode
        case unlock
        case mountDDI
        case signingTeam
        case uiAutomation
    }

    enum Status: String, Encodable, Sendable {
        /// Not run, in a dry run.
        case planned
        /// Already met when the step ran.
        case met
        case done
        /// An owner step that was not met when the wait ran out.
        case needsOwner
        case failed
        /// An earlier step is not met or done.
        case blocked
    }

    var kind: Kind
    var owner: Bool
    /// What the owner does, or what DeviceLoop runs.
    var instruction: String
    var status: Status = .planned
    /// What the step did, or why it failed.
    var detail: String?
    var fix: String?

    /// With `pair` on an unpaired target, the pair step names the `devicectl manage pair` request DeviceLoop runs.
    init(_ kind: Kind, on target: Target, pair: Bool = false) {
        self.kind = kind
        switch kind {
            case .pair where pair && !target.paired:
                owner = true
                instruction =
                    "DeviceLoop runs xcrun devicectl manage pair --device \(target.udid). On \(target.name) tap Trust and enter the passcode."
            case .pair:
                owner = true
                instruction = "Connect \(target.name) with a cable, unlock it, tap Trust and enter the passcode."
            case .developerMode:
                owner = true
                instruction = "On \(target.name): Settings > Privacy & Security > Developer Mode, then restart and confirm."
            case .unlock:
                owner = true
                instruction = "Unlock \(target.name)."
            case .mountDDI:
                owner = false
                instruction = "xcrun devicectl device info ddiServices --device \(target.udid)"
            case .signingTeam:
                owner = false
                instruction = "Store the Xcode signing team in \(DeviceLoopConfig.url.path), as deviceloop setup does."
            case .uiAutomation:
                owner = false
                instruction = "Start the UI runner. Enter the passcode on \(target.name) if it asks to enable UI Automation."
        }
    }

    /// `needsOwner pair: Connect ...`, plus an indented fix line.
    var lines: [String] {
        let label = status.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
        return ["\(label) \(kind.rawValue): \(detail ?? instruction)"] + (fix.map { ["           fix: \($0)"] } ?? [])
    }
}

struct PrepareReport: Encodable, Sendable {
    var udid: String
    var name: String
    var summary: String
    var ready: Bool
    var steps: [PrepareStep]
    var doctor: DoctorReport

    /// Ready when every step is met or done and doctor finds no failure.
    init(target: Target, steps: [PrepareStep], doctor: DoctorReport) {
        udid = target.udid
        name = target.name
        summary = target.summary
        ready = steps.allSatisfy { $0.status == .met || $0.status == .done } && doctor.failures == 0
        self.steps = steps
        self.doctor = doctor
    }
}

/// Runs a prepare plan on one target.
struct PrepareRun {
    /// Re-read from `devicectl list devices` while owner steps wait.
    var target: Target
    /// Doctor's host DDI check. `mountDDI` fails with its detail and fix when it found no usable image.
    var hostDDI: DoctorCheck
    /// Seconds to wait for each owner step.
    var wait: Int
    /// How long the runner start keeps retrying after the UI Automation passcode prompt times out.
    var ownerWait: Duration = .zero
    /// Runs `devicectl manage pair` when the pair step waits on a device that is not paired.
    var pair = false
    var poll: Duration = .seconds(2)
    var log: (String) -> Void
    var devicectl: ([String]) async throws -> JSONValue

    /// The steps doctor shows are not done, in order. Simulators need none. `pair` is the `--pair` option.
    static func plan(for target: Target, doctor: DoctorReport, runnerLive: Bool, pair: Bool = false) -> [PrepareStep] {
        guard !target.isSimulator else { return [] }
        let checks = doctor.host + doctor.targets.flatMap(\.checks)
        func check(_ name: String) -> DoctorCheck? { checks.first { $0.name == name } }

        var kinds: [PrepareStep.Kind] = []
        if check("pairing")?.status != .ok || check("connection")?.status == .fail { kinds.append(.pair) }
        if check("developer mode")?.status != .ok { kinds.append(.developerMode) }
        if !target.isReady || target.supports(Capability.lockState), check("lock").map({ $0.code == .deviceLocked }) ?? true {
            kinds.append(.unlock)
        }
        if check("ddi services")?.status != .ok { kinds.append(.mountDDI) }
        if check("deviceloop team")?.status != .ok { kinds.append(.signingTeam) }
        if !runnerLive { kinds.append(.uiAutomation) }
        return kinds.map { PrepareStep($0, on: target, pair: pair) }
    }

    /// Runs `steps` in order, or none of them when `dryRun` is set. Every step after one that is not met or done is blocked.
    mutating func run(_ steps: [PrepareStep], dryRun: Bool = false) async throws -> [PrepareStep] {
        guard !dryRun else { return steps }
        var finished: [PrepareStep] = []
        for var step in steps {
            if let last = finished.last, last.status != .met, last.status != .done {
                step.status = .blocked
            } else if step.owner {
                step.status = try await waitForOwner(step)
            } else {
                do {
                    step.detail = try await perform(step.kind)
                    step.status = .done
                } catch let error as DeviceLoopError {
                    step.status = .failed
                    step.detail = error.message
                    step.fix = error.fix
                }
            }
            finished.append(step)
        }
        return finished
    }

    /// Re-reads every `poll` until the step is met or `wait` runs out, logging the instruction once.
    private mutating func waitForOwner(_ step: PrepareStep) async throws -> PrepareStep.Status {
        let deadline = ContinuousClock.now + .seconds(wait)
        var asked = false
        while !(await isMet(step.kind)) {
            guard ContinuousClock.now < deadline else { return .needsOwner }
            if !asked {
                log("\(step.instruction) Waiting up to \(wait) s.")
                asked = true
                if step.kind == .pair, pair, !target.paired { await requestPairing(until: deadline) }
            }
            try await Task.sleep(for: poll)
        }
        return asked ? .done : .met
    }

    /// Runs `devicectl manage pair` for at most the seconds left before `deadline`, logging a failure.
    private func requestPairing(until deadline: ContinuousClock.Instant) async {
        // Stays under the 120 s process timeout of the devicectl call.
        let seconds = min(110, max(1, ContinuousClock.now.duration(to: deadline).components.seconds))
        do {
            _ = try await devicectl(["manage", "pair", "--device", target.udid, "--timeout", String(seconds)])
        } catch {
            log("devicectl manage pair failed: \((error as? DeviceLoopError)?.message ?? "\(error)")")
        }
    }

    /// Pairing and Developer Mode from `devicectl list devices`, unlocking from `devicectl device info lockState`.
    private mutating func isMet(_ kind: PrepareStep.Kind) async -> Bool {
        if kind == .unlock {
            guard let state = try? await devicectl(Devicectl.device(target, "info", "lockState")) else { return false }
            return DoctorReport.lockCheck(state, target: target).status == .ok
        }
        let listed = try? await devicectl(["list", "devices"])["devices"]?.array?.compactMap(Target.init(devicectl:))
        if let current = listed?.first(where: { $0.udid == target.udid }) { target = current }
        return kind == .pair ? target.paired && target.connectionState == "connected" : target.developerModeEnabled == true
    }

    /// Runs a tool step and returns what it did.
    private func perform(_ kind: PrepareStep.Kind) async throws -> String {
        switch kind {
            case .mountDDI:
                guard hostDDI.code != .ddiUnavailable else { throw DeviceLoopError(.ddiUnavailable, hostDDI.detail, fix: hostDDI.fix) }
                let arguments = Devicectl.device(target, "info", "ddiServices")
                _ = try await devicectl(arguments)
                let check = DoctorReport.ddiCheck(try await devicectl(arguments + ["--no-auto-mount-ddis"]), target: target, host: hostDDI)
                guard check.status == .ok else {
                    throw DeviceLoopError(
                        .ddiUnavailable,
                        "The developer disk image is still not mounted after devicectl tried to mount it.",
                        fix: "Run `xcrun devicectl device info ddiServices --device \(target.udid)` and read its error."
                    )
                }
                return "mounted, \(check.detail)"
            case .signingTeam:
                let signing = await SigningState.read()
                if DeviceLoopConfig.team() == nil, let team = try TeamChoice.pick(team: nil, stored: nil, signing: signing).team {
                    try DeviceLoopConfig.store(team: team, at: DeviceLoopConfig.url)
                }
                let check = DoctorReport.signingChecks(signing, stored: DeviceLoopConfig.team()).first { $0.name == "deviceloop team" }
                guard let check, check.status == .ok else {
                    throw DeviceLoopError(check?.code ?? .signingNoTeam, check?.detail ?? "no team stored", fix: check?.fix)
                }
                return check.detail
            case .uiAutomation:
                let session = try await RunnerSession.connect(target, ownerWait: ownerWait, log: log)
                return "runner ready on \(session.info.host):\(session.info.port)"
            case .pair, .developerMode, .unlock:
                throw DeviceLoopError(.internalError, "\(kind.rawValue) is an owner step.")
        }
    }
}
