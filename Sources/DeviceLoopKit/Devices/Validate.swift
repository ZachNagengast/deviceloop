//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// Checks values that DeviceLoop passes on to devicectl and simctl, so none of them reads as an option.
enum Validate {
    /// Letters, digits, `.`, `-` and `_`, starting with a letter or digit, for example `com.apple.Preferences`.
    static func bundleID(_ bundleID: String) throws {
        guard bundleID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]*/) != nil else {
            throw DeviceLoopError(
                .badArguments, "\(bundleID) is not a bundle ID.",
                fix: "Pass a bundle ID such as com.apple.Preferences. `deviceloop apps --system` lists them.")
        }
    }

    /// A relative path such as `Retired/MyApp-2026-10-22-131927.ips` with no part that starts with `-` or `.`.
    static func reportName(_ name: String) throws {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasPrefix(".") }) else {
            throw DeviceLoopError(
                .badArguments, "\(name) is not a report name.",
                fix: "Pass a name from `deviceloop crashes`, for example MyApp-2026-10-22-131927.ips.")
        }
    }

    /// A path relative to an app data container, such as `Documents/f.txt` or `.config`, with no `.` or `..` part,
    /// no empty part and no leading `-`.
    static func containerPath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("-"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DeviceLoopError(
                .badArguments, "\(path) is not a path in an app data container.",
                fix: "Pass a relative path such as Documents/f.txt, as `deviceloop container <bundle ID>` lists it.")
        }
    }
}
