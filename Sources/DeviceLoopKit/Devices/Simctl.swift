//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// Runs `xcrun simctl` for the simulator-only paths devicectl does not cover.
public enum Simctl {
    @discardableResult
    public static func run(_ arguments: [String], timeout: Duration = .seconds(60)) async throws -> ShellResult {
        let result = try await Shell.run(["xcrun", "simctl"] + arguments, timeout: timeout)
        guard result.succeeded else {
            let message = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = message.split(separator: "\n").map(String.init)
            let headers = ["Detected file type", "Note:", "An error was encountered"]
            let reason = lines.first { line in !headers.contains { line.hasPrefix($0) } } ?? lines.first ?? "exit \(result.status)"
            throw DeviceLoopError(.deviceError, "simctl \(arguments.first ?? "") failed: \(reason)", detail: message)
        }
        return result
    }
}
