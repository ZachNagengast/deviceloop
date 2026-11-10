//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Synchronization

/// One JSON line per MCP tool call, rotated to a single `.1` file at about 10 MB.
enum MCPActivityLog {
    static let maxBytes = 10_000_000
    private static let lock = Mutex(())

    static func append(tool: String, arguments: JSONValue, deviceName: String?, status: String, started: Date, to file: URL) {
        let entry: JSONValue = [
            "time": .string(started.formatted(.iso8601)),
            "tool": .string(tool),
            "device": arguments["device"] ?? .null,
            "deviceName": deviceName.map(JSONValue.string) ?? .null,
            "arguments": .object(redacted(arguments)),
            "result": .string(status),
            "durationMs": .number((Date().timeIntervalSince(started) * 1000).rounded()),
        ]
        lock.withLock { _ in
            do {
                try Paths.ensureDirectory(file.deletingLastPathComponent())
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int ?? 0
                if size >= maxBytes { _ = rename(file.path, file.appendingPathExtension("1").path) }
                let line = try entry.data() + Data("\n".utf8)
                let descriptor = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                defer { close(descriptor) }
                _ = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            } catch {
                MCPServer.log("could not write \(file.path): \(error)")
            }
        }
    }

    /// The arguments with typed, copied and Siri text replaced by its length and `env` reduced to its keys.
    /// An inline `flow` keeps the length of each typed text and the keys of each environment.
    static func redacted(_ arguments: JSONValue) -> [String: JSONValue] {
        var logged = arguments.object ?? [:]
        if let text = logged["text"] {
            logged["text"] = text.string.map { .number(Double($0.count)) } ?? .null
        }
        if let step = logged["step"]?.string, case .type(let text, _, _)? = try? UIStep.parse(step) {
            logged["step"] = .string("type, \(text.count) characters")
        }
        if let environment = logged["env"]?.array {
            logged["env"] = .array(environment.map { $0["key"] ?? .null })
        }
        if let flow = logged["flow"] {
            logged["flow"] = redacted(flow: flow).flow
        }
        return logged
    }

    /// `flow` with each string under a `text` key replaced by its length and each object under an `environment` key
    /// replaced by its keys, and the typed texts it replaced.
    static func redacted(flow: JSONValue) -> (flow: JSONValue, typed: [String]) {
        switch flow {
            case .array(let items):
                let redactedItems = items.map { redacted(flow: $0) }
                return (.array(redactedItems.map(\.flow)), redactedItems.flatMap(\.typed))
            case .object(let fields):
                var redactedFields: [String: JSONValue] = [:]
                var typed: [String] = []
                for (key, value) in fields {
                    switch (key, value) {
                        case ("text", .string(let text)):
                            redactedFields[key] = .number(Double(text.count))
                            typed.append(text)
                        case ("environment", .object(let environment)):
                            redactedFields[key] = .array(environment.keys.sorted().map(JSONValue.string))
                        default:
                            let nested = redacted(flow: value)
                            redactedFields[key] = nested.flow
                            typed += nested.typed
                    }
                }
                return (.object(redactedFields), typed)
            default:
                return (flow, [])
        }
    }
}
