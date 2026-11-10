//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import ArgumentParser
import DeviceLoopKit

/// ArgumentParser usage errors as `bad_arguments`, with the closest command or option for a typo.
enum ArgumentErrors {
    /// `bad_arguments` for a usage error from parsing `arguments`, or nil for help, version and completion requests.
    static func badArguments(for error: any Error, arguments: [String]) -> DeviceLoopError? {
        guard DeviceLoopCLI.exitCode(for: error) == .validationFailure else { return nil }
        let parsed = DeviceLoopCLI.message(for: error)
        var usage = DeviceLoopCLI.fullMessage(for: error)
        if !parsed.isEmpty, let range = usage.range(of: parsed + "\n") { usage = String(usage[range.upperBound...]) }
        var detail = usage.split(separator: "\n").filter { !$0.hasPrefix("  See '") }.joined(separator: "\n")
        var message = parsed
        var fix: String?
        if !parsed.contains("\n"), parsed.hasSuffix("'?"), let range = parsed.range(of: ". Did you mean '") {
            message = String(parsed[..<range.lowerBound])
            fix = "Use `\(parsed[range.upperBound ..< parsed.index(parsed.endIndex, offsetBy: -2)])`."
        }
        if parsed.contains("--generate-completion-script"), let line = parsed.split(separator: "\n").first {
            message = String(line)
            fix = "Use `--generate-completion-script zsh`, `bash` or `fish`."
        }
        let path = Output.commandPath(arguments)
        var commands = path.commands
        let group = commands[commands.count - 1]
        let defaultSubcommand = group.configuration.defaultSubcommand
        if !group.configuration.subcommands.isEmpty, let word = path.rest.first, !word.isEmpty, !word.hasPrefix("-"),
            commands.count > 1 || word != "help", defaultSubcommand.map({ (try? $0.parse([word])) == nil }) ?? true
        {
            message = "\(name(of: commands)) has no command \(word)"
            if defaultSubcommand != nil { detail = "" }
            fix = fix ?? closest(to: word, under: group).map { "Use `\(name(of: commands)) \($0)`." }
        } else {
            while let fallback = commands[commands.count - 1].configuration.defaultSubcommand { commands.append(fallback) }
        }
        if let last = message.last, !".?!".contains(last) { message += "." }
        return DeviceLoopError(
            .badArguments,
            message,
            fix: fix ?? "Run `\(helpCommand(for: commands))`.",
            detail: detail.isEmpty ? nil : detail
        )
    }

    /// `bad_arguments` for `help` followed by a word that names no command, or nil.
    static func unknownHelpTopic(_ arguments: [String]) -> DeviceLoopError? {
        guard arguments.first == "help" else { return nil }
        let topics = arguments.dropFirst().prefix { !$0.hasPrefix("-") }
        let path = Output.commandPath(Array(topics))
        guard let word = path.rest.first, !word.isEmpty, path.commands.count > 1 || word != "help" else { return nil }
        let help = helpCommand(for: path.commands)
        let suggestion = closest(to: word, under: path.commands[path.commands.count - 1])
        return DeviceLoopError(
            .badArguments,
            "\(name(of: path.commands)) has no command \(word).",
            fix: suggestion.map { "Use `\(help) \($0)`." } ?? "Run `\(help)`."
        )
    }

    /// The displayed subcommand of `group` closest to `word`, or nil when none is close or two are equally close.
    static func closest(to word: String, under group: any ParsableCommand.Type) -> String? {
        let limit = max(1, min(2, word.count / 3))
        let names = group.configuration.subcommands.filter { $0.configuration.shouldDisplay }.map { $0._commandName }
        let near = names.map { (name: $0, edits: distance(word, $0)) }.filter { $0.edits <= limit }
        guard let fewest = near.map(\.edits).min() else { return nil }
        let best = near.filter { $0.edits == fewest }
        return best.count == 1 ? best[0].name : nil
    }

    /// The number of insertions, deletions, substitutions and swaps of neighbors that turn `source` into `target`.
    static func distance(_ source: String, _ target: String) -> Int {
        let source = Array(source)
        let target = Array(target)
        guard !source.isEmpty, !target.isEmpty else { return max(source.count, target.count) }
        var table = [[Int]](repeating: [Int](repeating: 0, count: target.count + 1), count: source.count + 1)
        for row in 0 ... source.count { table[row][0] = row }
        for column in 0 ... target.count { table[0][column] = column }
        for row in 1 ... source.count {
            for column in 1 ... target.count {
                let substitution = table[row - 1][column - 1] + (source[row - 1] == target[column - 1] ? 0 : 1)
                var edits = min(table[row - 1][column] + 1, table[row][column - 1] + 1, substitution)
                if row > 1, column > 1, source[row - 1] == target[column - 2], source[row - 2] == target[column - 1] {
                    edits = min(edits, table[row - 2][column - 2] + 1)
                }
                table[row][column] = edits
            }
        }
        return table[source.count][target.count]
    }

    /// The command names in `commands`, starting with `deviceloop`.
    private static func name(of commands: [any ParsableCommand.Type]) -> String {
        commands.map { $0._commandName }.joined(separator: " ")
    }

    /// `deviceloop help` followed by the subcommand names in `commands`.
    private static func helpCommand(for commands: [any ParsableCommand.Type]) -> String {
        (["deviceloop help"] + commands.dropFirst().map { $0._commandName }).joined(separator: " ")
    }
}
