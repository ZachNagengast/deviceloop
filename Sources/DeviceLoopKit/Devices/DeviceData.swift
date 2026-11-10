//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// One screen from `devicectl device info displays`.
struct DeviceDisplay: Codable, Sendable, Equatable {
    var name: String
    var uniqueID: String?
    var pixelWidth: Int
    var pixelHeight: Int
    var pointScale: Double
    var primary: Bool
    /// False for the folded-away screen of a dual-display simulator. Single-screen targets omit the key.
    var active: Bool

    init?(devicectl entry: JSONValue) {
        guard let size = entry["nativeSize"]?.array, size.count == 2,
            let width = size[0].number, let height = size[1].number
        else { return nil }
        name = entry["name"]?.string ?? "display"
        uniqueID = entry["uniqueId"]?.string
        pixelWidth = Int(width)
        pixelHeight = Int(height)
        pointScale = entry["pointScale"]?.number ?? 1
        primary = entry["primary"]?.bool ?? false
        active = entry["active"]?.bool ?? true
    }

    var pointWidth: Int { Int((Double(pixelWidth) / pointScale).rounded()) }
    var pointHeight: Int { Int((Double(pixelHeight) / pointScale).rounded()) }
}

/// The `result` of `devicectl device info displays`.
struct DeviceDisplays: Sendable {
    var displays: [DeviceDisplay]
    var orientation: String?
    /// The last orientation other than `faceUp` or `faceDown`.
    var nonFlatOrientation: String?

    init(devicectl result: JSONValue) {
        displays = (result["displays"]?.array ?? []).compactMap(DeviceDisplay.init(devicectl:))
        orientation = result.value(at: "orientation.currentDeviceOrientation")?.string
        nonFlatOrientation = result.value(at: "orientation.currentDeviceNonFlatOrientation")?.string
    }

    /// The screen a person sees: the active primary display, else any active one, else the first.
    var visible: DeviceDisplay? {
        displays.first { $0.active && $0.primary } ?? displays.first(where: \.active) ?? displays.first
    }
}

/// The `result` of `devicectl device orientation get`.
struct DeviceOrientation: Sendable {
    /// `deviceOrientationNonFlat`, else `deviceOrientation`, skipping `unknown`.
    var orientation: String
    /// Rotation lock, nil when devicectl omits it.
    var locked: Bool?

    init(devicectl result: JSONValue) {
        let names = [result["deviceOrientationNonFlat"]?.string, result["deviceOrientation"]?.string].compactMap { $0 }
        orientation = names.first { $0 != "unknown" } ?? "unknown"
        locked = result["deviceIsOrientationLocked"]?.bool
    }
}

/// One app from `devicectl device info apps`.
struct InstalledApp: Codable, Sendable, Equatable {
    var bundleID: String
    var name: String
    var version: String?
    var build: String?
    /// Bundle location on the target, for example `file:///Applications/Preferences.app/`.
    var url: String
    /// Ships with the OS (devicectl `defaultApp`), such as Settings or Safari.
    var systemApp: Bool
    /// devicectl can read and write the app's data container. Nil when devicectl does not say.
    var containerAccessible: Bool?

    init?(devicectl entry: JSONValue) {
        guard let bundleID = entry["bundleIdentifier"]?.string else { return nil }
        self.bundleID = bundleID
        name = entry["name"]?.string ?? bundleID
        version = entry["version"]?.string
        build = entry["bundleVersion"]?.string
        url = entry["url"]?.string ?? ""
        systemApp = entry["defaultApp"]?.bool ?? false
        containerAccessible = entry["containerAccessible"]?.bool
    }

    static func list(devicectl result: JSONValue) -> [InstalledApp] {
        (result["apps"]?.array ?? []).compactMap(InstalledApp.init(devicectl:))
            .sorted { $0.bundleID < $1.bundleID }
    }

    /// Bundle IDs in a `devicectl device install app` result, which names them `bundleID`.
    static func bundleIDs(installResult result: JSONValue) -> [String] {
        (result["installedApplications"]?.array ?? []).compactMap { $0["bundleID"]?.string }
    }
}

/// An .app bundle on the Mac, from its Info.plist and code signature.
struct AppArtifact: Encodable, Sendable, Equatable {
    var bundleID: String
    var version: String?
    var build: String?
    var executable: String?
    /// First of `CFBundleSupportedPlatforms`, for example `iPhoneOS` or `iPhoneSimulator`.
    var platform: String?
    var minimumOSVersion: String?
    /// `TeamIdentifier` from codesign. Nil for ad hoc and unsigned bundles.
    var team: String?
    /// `adhoc`, `unsigned` or the first signing authority, for example `Apple Development: Jane Doe (ABCDE12345)`.
    var signing: String?

    /// Throws `bad_arguments` when the bundle is built for the other kind of target or needs a newer iOS than it runs.
    func check(for target: Target) throws {
        let expected = target.isSimulator ? "iPhoneSimulator" : "iPhoneOS"
        if let platform, platform != expected {
            throw DeviceLoopError(
                .badArguments,
                "\(bundleID) is built for \(platform), and \(target.summary) needs an \(expected) build.",
                fix: target.isSimulator
                    ? "Build with -destination 'generic/platform=iOS Simulator' and pass the .app from Debug-iphonesimulator."
                    : "Build with -destination 'generic/platform=iOS' and pass the .app from Debug-iphoneos.",
                device: target.name
            )
        }
        if let minimumOSVersion, target.osVersion.first?.isNumber == true,
            Self.version(minimumOSVersion, isAbove: target.osVersion)
        {
            throw DeviceLoopError(
                .badArguments,
                "\(bundleID) needs iOS \(minimumOSVersion) or later, and \(target.summary) runs iOS \(target.osVersion).",
                fix: "Set IPHONEOS_DEPLOYMENT_TARGET to \(target.osVersion) or lower, or use a target on iOS \(minimumOSVersion) or later.",
                device: target.name
            )
        }
    }

    /// Throws `device_error` unless `installed` is this bundle ID with this version and build.
    func verify(installed: InstalledApp?, on target: Target) throws {
        guard let installed, installed.bundleID == bundleID, installed.version == version, installed.build == build else {
            let found = installed.map { Self.label(version: $0.version, build: $0.build) } ?? "nothing"
            throw DeviceLoopError(
                .deviceError,
                "\(target.summary) lists \(found) for \(bundleID) after install, expected \(Self.label(version: version, build: build)).",
                fix: "Run `deviceloop apps` to see what is installed, then install again.",
                device: target.name
            )
        }
    }

    /// Sets `signing` and `team` from `codesign -dv --verbose=2` output.
    mutating func readSignature(codesign output: String) {
        let lines = output.split(whereSeparator: \.isNewline)
        func value(_ key: String) -> String? {
            lines.first { $0.hasPrefix("\(key)=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        team = value("TeamIdentifier").flatMap { $0 == "not set" ? nil : $0 }
        signing = value("Signature") == "adhoc" ? "adhoc" : value("Authority") ?? "unsigned"
    }

    /// `1.0 (7)`, `1.0` or `(7)`, or `no version` when the bundle has neither.
    static func label(version: String?, build: String?) -> String {
        let parts = [version, build.map { "(\($0))" }].compactMap { $0 }
        return parts.isEmpty ? "no version" : parts.joined(separator: " ")
    }

    /// Compares dotted versions with missing parts as zero, so 17.0 is not above 17.
    static func version(_ version: String, isAbove other: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            Array((text.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]).prefix(3))
        }
        return parts(other).lexicographicallyPrecedes(parts(version))
    }
}

extension AppArtifact {
    /// Reads `Info.plist` at the top of an iOS app bundle.
    init(bundle: URL) throws {
        let plist = try? Data(contentsOf: bundle.appending(path: "Info.plist"))
        let info = plist.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
        guard let bundleID = info?["CFBundleIdentifier"] as? String else {
            throw DeviceLoopError(
                .badArguments, "\(bundle.lastPathComponent) has no Info.plist with a CFBundleIdentifier.",
                fix: "Pass an .app built by Xcode, or an .ipa that contains one.")
        }
        try Validate.bundleID(bundleID)
        self.init(
            bundleID: bundleID,
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            executable: info?["CFBundleExecutable"] as? String,
            platform: (info?["CFBundleSupportedPlatforms"] as? [String])?.first,
            minimumOSVersion: info?["MinimumOSVersion"] as? String
        )
    }
}

/// One file or folder in an app data container.
struct ContainerFile: Codable, Sendable, Equatable {
    /// Relative to the container, for example `Documents/f.txt`. `container pull` takes it.
    var path: String
    var directory: Bool
    /// Bytes, nil for folders.
    var size: Int?
    /// ISO 8601 modification time.
    var modified: String?

    /// Entries of a `devicectl device info files` result for the folder `path`, which devicectl lists relative to it.
    static func list(devicectl result: JSONValue, under path: String? = nil) -> [ContainerFile] {
        let prefix = path.map { $0 + "/" } ?? ""
        return (result["files"]?.array ?? []).compactMap { file in
            guard let relative = file["relativePath"]?.string ?? file["name"]?.string else { return nil }
            let directory = file.value(at: "resources.isDirectory")?.bool ?? false
            return ContainerFile(
                path: prefix + relative, directory: directory,
                size: directory ? nil : file.value(at: "metadata.size")?.number.map { Int($0) },
                modified: file.value(at: "metadata.lastModDate")?.string)
        }
        .sorted { $0.path < $1.path }
    }
}

enum RunningApps {
    /// Bundle ID to pids, from `devicectl device info processes` on a device. A process belongs to an app when
    /// its executable sits directly in the app bundle, so `.appex` extensions inside the bundle are skipped.
    static func match(processes result: JSONValue, apps: [InstalledApp]) -> [String: [Int32]] {
        let bundles = Dictionary(apps.map { (normalizedFolder($0.url), $0.bundleID) }) { first, _ in first }
        var running: [String: [Int32]] = [:]
        for process in result["runningProcesses"]?.array ?? [] {
            guard let executable = process["executable"]?.string, let pid = process["processIdentifier"]?.number,
                let slash = executable.lastIndex(of: "/"),
                let bundleID = bundles[normalizedFolder(String(executable[...slash]))]
            else { continue }
            running[bundleID, default: []].append(Int32(pid))
        }
        return running
    }

    /// Bundle ID to pids, from `launchctl list` inside a simulator, where apps run as
    /// `UIKitApplication:<bundle id>[<instance>][rb-legacy]` jobs.
    static func match(launchctlList output: String) -> [String: [Int32]] {
        var running: [String: [Int32]] = [:]
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: "\t")
            guard columns.count == 3, let pid = Int32(columns[0]), columns[2].hasPrefix("UIKitApplication:") else { continue }
            let label = columns[2].dropFirst("UIKitApplication:".count)
            let bundleID = label.prefix { $0 != "[" }
            if !bundleID.isEmpty { running[String(bundleID), default: []].append(pid) }
        }
        return running
    }

    private static func normalizedFolder(_ url: String) -> String {
        url.hasSuffix("/") ? url : url + "/"
    }
}

/// One `.ips` report from a device's `systemCrashLogs` domain or the Mac's DiagnosticReports folder.
struct CrashReport: Codable, Sendable, Equatable {
    /// Path relative to the crash log root, for example `Retired/MyApp-2026-10-22-131927.ips`. `crashes pull` takes it.
    var name: String
    var process: String
    var date: Date?
    var bugType: String?
    var size: Int?

    init(name: String, date: Date?, bugType: String?, size: Int?) {
        self.name = name
        process = CrashReport.process(fromFileName: (name as NSString).lastPathComponent)
        self.date = date
        self.bugType = bugType
        self.size = size
    }

    /// `Foo.cpu_resource-2024-09-18-234417.ips` is `Foo.cpu_resource`.
    static func process(fromFileName fileName: String) -> String {
        let pattern = /-\d{4}-\d{2}-\d{2}-\d{6}(\.\d+)?\.ips$/
        if let match = fileName.firstMatch(of: pattern) {
            return String(fileName[..<match.range.lowerBound])
        }
        return fileName.hasSuffix(".ips") ? String(fileName.dropLast(4)) : fileName
    }

    /// Reports in a `devicectl device info files --domain-type systemCrashLogs` result.
    static func list(devicectl result: JSONValue) -> [CrashReport] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (result["files"]?.array ?? []).compactMap { file in
            guard let name = file["relativePath"]?.string ?? file["name"]?.string, name.hasSuffix(".ips"),
                file.value(at: "resources.isDirectory")?.bool != true
            else { return nil }
            let metadata = file["metadata"]
            return CrashReport(
                name: name,
                date: metadata?["lastModDate"]?.string.flatMap { formatter.date(from: $0) },
                bugType: metadata?.value(at: "extendedAttributes.bug_type")?.string,
                size: metadata?["size"]?.number.map { Int($0) }
            )
        }
    }

    /// The first line of an `.ips` file is a JSON header with `bug_type`, `name` and `timestamp`.
    static func header(of contents: Data) -> JSONValue? {
        let firstLine = contents.prefix { $0 != UInt8(ascii: "\n") }
        return try? JSONValue(data: Data(firstLine))
    }

    /// The JSON object after the header line, with `pid`, `procName` and the threads.
    static func body(of contents: Data) -> JSONValue? {
        guard let newline = contents.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        return try? JSONValue(data: Data(contents[contents.index(after: newline)...]))
    }

    /// A report read from the Mac, dated by its header `timestamp`, for example `2026-10-22 11:35:39.00 -0700`.
    init(name: String, contents: Data, modified: Date?) {
        let header = CrashReport.header(of: contents)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamped = header?["timestamp"]?.string.flatMap { formatter.date(from: $0) }
        self.init(name: name, date: stamped ?? modified, bugType: header?["bug_type"]?.string, size: contents.count)
    }

    /// `crash` for 309, `cpu_resource` for 202, otherwise the raw bug type.
    var kind: String {
        switch bugType {
            case "309": "crash"
            case "202": "cpu_resource"
            case let other?: "bug_type \(other)"
            case nil: "report"
        }
    }

    /// The oldest report on `executable` dated `since` or later, from `pid` when `pidOf` reads one. Undated reports are left out.
    static func blamed(
        _ reports: [CrashReport], executable: String, since: Date, pid: Int32?, pidOf: (CrashReport) -> Int32?
    ) -> CrashReport? {
        reports.filter { report in
            guard report.process == executable, let date = report.date, date >= since else { return false }
            guard let pid, let reported = pidOf(report) else { return true }
            return reported == pid
        }
        .min { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    /// Newest first, filtered by a process name prefix and dated `since` or later. Undated reports are kept.
    static func select(_ reports: [CrashReport], process: String?, since: Date? = nil) -> [CrashReport] {
        reports.filter { report in
            if let since, let date = report.date, date < since { return false }
            guard let process, !process.isEmpty else { return true }
            return report.process.lowercased().hasPrefix(process.lowercased())
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}
