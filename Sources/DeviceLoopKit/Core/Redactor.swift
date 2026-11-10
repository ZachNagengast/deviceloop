//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import CryptoKit
import Foundation

/// Replaces personal values and secrets with short aliases such as `device-3f9a`. Aliases are salted per redactor,
/// so a value keeps one alias within an export and gets a different one in the next export.
struct Redactor {
    enum Kind: String, CaseIterable {
        case home
        case user
        case device
        case udid
        case coredevice
        case tunnel
        case team
        case teamName = "teamname"
        case identity
        case token
        case typed
        case siri

        /// The replacement and what it covers, for REDACTIONS.txt.
        var rule: String {
            switch self {
                case .home: "~ for the home path"
                case .user: "user-xxxx for the user name and full name"
                case .device: "device-xxxx for device names"
                case .udid: "udid-xxxx for UDIDs"
                case .coredevice: "coredevice-xxxx for CoreDevice identifiers"
                case .tunnel: "tunnel-xxxx for tunnel addresses and fdxx: IPv6 addresses"
                case .team: "team-xxxx for team IDs"
                case .teamName: "teamname-xxxx for team names"
                case .identity: "identity-xxxx for signing identity names and Apple Development: ... (...)"
                case .token: "token-xxxx for runner tokens, Bearer ... and 44-character base64"
                case .typed: "[hidden] for typed text in XCTest Type '...' into lines"
                case .siri: "[hidden] for Siri phrases in XCTest Activate Siri lines"
            }
        }
    }

    private let key = SymmetricKey(size: .bits256)
    private var known: [(value: String, kind: Kind)] = []
    private var aliases: [String: String] = [:]
    /// Replacements made so far, by kind.
    private(set) var counts: [Kind: Int] = [:]

    /// Replaces `value` wherever it appears, ignoring case. Nil and values shorter than three characters are skipped.
    mutating func add(_ value: String?, as kind: Kind) {
        guard let value, value.count >= 3, !known.contains(where: { $0.value.lowercased() == value.lowercased() }) else { return }
        known.append((value, kind))
        known.sort { $0.value.count > $1.value.count }
    }

    /// `text` with typed text and Siri phrases hidden, then xcodebuild destination names and known values replaced longest
    /// first, then tokens, identities and ULA addresses.
    /// Typed text runs from `Type '` to the next `' into `, across lines, or from the start when `text` begins inside it.
    mutating func redact(_ text: String) -> String {
        let typed = #/(?:\A(?:(?!Type ')(?s:.))*?|Type '(?s:.*?))' into /#
        var text = text.replacing(typed) { _ in "Type '\(alias("", .typed))' into " }
        text = text.replacing(/(Activate Siri with voice recognition text: ).*/) { $0.1 + alias("", .siri) }
        text = text.replacing(/(\{ platform:[^}\n]*, name:)([^}\n]+)( \})/) { $0.1 + alias(String($0.2), .device) + $0.3 }
        for (value, kind) in known {
            text = text.replacing(Regex<Substring>(verbatim: value).ignoresCase()) { _ in alias(value, kind) }
        }
        text = text.replacing(/Bearer\s+([A-Za-z0-9+\/=._~-]+)/) { "Bearer " + alias(String($0.1), .token) }
        text = text.replacing(/[A-Za-z0-9+\/]{43}=/) { alias(String($0.0), .token) }
        text = text.replacing(/(?:Apple Development|iPhone Developer): [^"\n(]*\([^)\n]*\)/) { alias(String($0.0), .identity) }
        return text.replacing(/fd[0-9a-f]{2}(?::[0-9a-f]{0,4}){2,7}/.ignoresCase()) { alias(String($0.0), .tunnel) }
    }

    /// `json` with every string and object key redacted.
    mutating func redact(_ json: JSONValue) -> JSONValue {
        switch json {
            case .string(let value): .string(redact(value))
            case .array(let items): .array(items.map { redact($0) })
            case .object(let object):
                .object(Dictionary(object.map { (redact($0.key), redact($0.value)) }, uniquingKeysWith: { first, _ in first }))
            default: json
        }
    }

    /// `kind-` and the first hex digits of the salted HMAC of `value`, longer when that alias belongs to another value.
    private mutating func alias(_ value: String, _ kind: Kind) -> String {
        counts[kind, default: 0] += 1
        switch kind {
            case .home: return "~"
            case .typed, .siri: return "[hidden]"
            default: break
        }
        let id = "\(kind.rawValue):\(value.lowercased())"
        if let existing = aliases[id] { return existing }
        let digest = HMAC<SHA256>.authenticationCode(for: Data(id.utf8), using: key).map { String(format: "%02x", $0) }.joined()
        let taken = Set(aliases.values)
        let length = stride(from: 4, to: digest.count, by: 2).first { !taken.contains("\(kind.rawValue)-\(digest.prefix($0))") }
        let alias = "\(kind.rawValue)-\(digest.prefix(length ?? digest.count))"
        aliases[id] = alias
        return alias
    }
}
