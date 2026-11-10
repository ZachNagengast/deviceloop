//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit
import Foundation

struct TargetOptions: ParsableArguments {
    @Option(
        name: [.short, .customLong("device")],
        help: "A UDID, a name or a unique part of it, `booted`, `usb` or `device`. Defaults to $DEVICELOOP_DEVICE or the only ready target."
    )
    var device: String?

    @Flag(name: .long, help: "Print JSON instead of text.")
    var json = false
}

struct OutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Print JSON instead of text.")
    var json = false
}

/// Parses repeated `--env KEY=VALUE` options.
func parseEnvironment(_ pairs: [String]) throws -> [String: String] {
    var variables: [String: String] = [:]
    for pair in pairs {
        guard let equals = pair.firstIndex(of: "=") else { throw DeviceLoopError.usage("--env expects KEY=VALUE, got \(pair)") }
        variables[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
    }
    return variables
}

enum Output {
    /// Resolves the target, runs `body` journaled in the target's active run, prints the result, and maps errors to exit codes.
    /// A returned result exits with `exitCode(result)`, and is journaled as an error when that is not 0.
    static func run(
        _ options: TargetOptions,
        hiding: [String] = [],
        savingResult: Bool = true,
        exitCode: (CommandResult) -> Int32 = { _ in 0 },
        _ body: (Target) async throws -> CommandResult
    ) async throws {
        try await emit(json: options.json, exitCode: exitCode) {
            let target = try await TargetResolver.resolve(options.device)
            return try await record(target.udid, hiding: hiding, savingResult: savingResult, failed: { exitCode($0) != 0 }) {
                try await body(target)
            }
        }
    }

    /// Like `run` for a body that returns a flow-result. Ctrl-C cancels the run before its next step. Prints the
    /// result, then exits 1 when the run did not pass and 130 when it was cancelled.
    static func runFlow(
        _ options: TargetOptions, hiding: [String] = [], _ body: @escaping @Sendable (Target) async throws -> CommandResult
    ) async throws {
        try await run(options, hiding: hiding, exitCode: flowExitCode) { target in
            try await FlowEngine.cancellingOnInterrupt { try await body(target) }
        }
    }

    /// 1 when the result has `ok` false, otherwise 0.
    static func failedExitCode(_ result: CommandResult) -> Int32 {
        result.json["ok"]?.bool == false ? 1 : 0
    }

    /// 1 for a flow-result that did not pass, 130 for a cancelled one, otherwise 0.
    static func flowExitCode(_ result: CommandResult) -> Int32 {
        result.json["status"]?.string.flatMap(FlowResult.Status.init)?.exitCode ?? 0
    }

    /// Runs `body` journaled in the active run of `udid` with the command words and arguments of this process.
    static func record(
        _ udid: String?, hiding: [String] = [], savingResult: Bool = true, failed: (CommandResult) -> Bool = { _ in false },
        _ body: () async throws -> CommandResult
    ) async throws -> CommandResult {
        let (command, words) = commandWords(Array(CommandLine.arguments.dropFirst()))
        return try await RunRecorder.record(
            udid, command: command, args: .array(words.map(JSONValue.string)), hiding: hiding, savingResult: savingResult,
            failed: failed, body)
    }

    /// The subcommand names at the start of `arguments`, ending with the default subcommand of a group, and the words after them.
    static func commandWords(_ arguments: [String]) -> (command: String, args: [String]) {
        let path = commandPath(arguments)
        var command = path.commands.dropFirst().map { $0._commandName }
        if let fallback = path.commands.last?.configuration.defaultSubcommand { command.append(fallback._commandName) }
        return (command.joined(separator: " "), Array(path.rest))
    }

    /// The root command and the subcommands the words at the start of `arguments` name, and the arguments after them.
    static func commandPath(_ arguments: [String]) -> (commands: [any ParsableCommand.Type], rest: ArraySlice<String>) {
        var rest = arguments[...]
        var commands: [any ParsableCommand.Type] = [DeviceLoopCLI.self]
        var parent: any ParsableCommand.Type = DeviceLoopCLI.self
        while let word = rest.first, let subcommand = parent.configuration.subcommands.first(where: { $0._commandName == word }) {
            commands.append(subcommand)
            rest.removeFirst()
            parent = subcommand
        }
        return (commands, rest)
    }

    /// Whether `--json` comes before any `--` in `arguments`.
    static func wantsJSON(_ arguments: [String]) -> Bool {
        arguments.prefix { $0 != "--" }.contains("--json")
    }

    /// Prints the result of `body`, then exits with `exitCode(result)` when it is not 0. Maps errors to exit codes.
    static func emit(json: Bool, exitCode: (CommandResult) -> Int32 = { _ in 0 }, _ body: () async throws -> CommandResult) async throws {
        do {
            let result = try await body()
            if json {
                print(String(decoding: try result.json.data(pretty: true), as: UTF8.self))
            } else if !result.text.isEmpty {
                print(result.text)
            }
            let code = exitCode(result)
            if code != 0 { throw ExitCode(code) }
        } catch let error as DeviceLoopError {
            report(error, json: json)
            throw ExitCode(error.exitCode)
        } catch let error as ExitCode {
            throw error
        } catch is CancellationError {
            throw ExitCode(130)
        } catch {
            let wrapped = DeviceLoopError(.internalError, "\(error)")
            report(wrapped, json: json)
            throw ExitCode(wrapped.exitCode)
        }
    }

    static func report(_ error: DeviceLoopError, json: Bool) {
        if json, let data = try? JSONValue.object(["ok": false, "error": JSONValue(encoding: error)]).data(pretty: true) {
            print(String(decoding: data, as: UTF8.self))
        } else {
            FileHandle.standardError.write(Data((error.rendered + "\n").utf8))
        }
    }
}
