//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import CryptoKit
import DeviceLoopProtocol
import Foundation

/// Builds and signs the UI runner, cached by source, toolchain and build configuration.
enum RunnerBuild {
    private static let configuration = "Debug"

    /// The error when `Paths.runnerProject` finds no runner project.
    static let missingProject = DeviceLoopError(
        .internalError, "Could not find the runner project.",
        fix: "Keep the source checkout the binary was built in, set DEVICELOOP_RUNNER_PATH to its Runner folder, or reinstall DeviceLoop.")

    /// The built products directory that holds the runner's xctestrun, building it if needed.
    static func products(for target: Target, log: (String) -> Void) async throws -> URL {
        guard let project = Paths.runnerProject else { throw missingProject }
        let team = target.isSimulator ? nil : try signingTeam(target)
        let key = try await cacheKey(project: project, simulator: target.isSimulator, team: team)
        // Different devices can share this cache key, so their per-device startup locks are insufficient.
        let buildLock = try await SessionLock.acquire(
            at: Paths.runnerBuilds.appending(path: ".locks/\(key).lock"), timeout: .seconds(660))
        defer { buildLock.release() }
        let folders = buildFolders(for: key)
        if let completed = folders.published {
            if target.isSimulator { return completed }
            let profile = await decodedHostProfile(in: completed)
            if let profile, profileUsable(profile, udid: target.udid) { return completed }
            if let profile, profileUsable(profile, udid: target.udid, now: .distantPast) {
                log("rebuilding the runner, its provisioning profile expired")
            } else {
                log("rebuilding the runner to add \(target.name) to the provisioning profile")
            }
        } else {
            log("building the runner (first run for this device, about a minute)")
        }
        let derivedData = try Paths.ensureDirectory(folders.next)
        let productsDir = derivedData.appending(path: "Build/Products")
        // Removing the marker first keeps a crashed or failed build from being reused.
        let completion = completionMarker(in: derivedData)
        if FileManager.default.fileExists(atPath: completion.path) {
            try FileManager.default.removeItem(at: completion)
        }

        createSwiftPMConfiguration(in: project)
        var arguments = [
            "xcrun", "xcodebuild", "build-for-testing",
            "-project", project.appending(path: "DeviceLoopRunner.xcodeproj").path,
            "-scheme", "DeviceLoopRunner",
            "-configuration", configuration,
            "-derivedDataPath", derivedData.path,
        ]
        if target.isSimulator {
            arguments += ["-destination", "generic/platform=iOS Simulator", "CODE_SIGNING_ALLOWED=NO"]
        } else {
            arguments += [
                "-destination", "id=\(target.udid)", "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration",
                "DEVELOPMENT_TEAM=\(team ?? "")",
            ]
        }

        let result = try await Shell.run(arguments, timeout: .seconds(600))
        guard result.succeeded, existingXctestrun(in: productsDir) != nil else {
            throw buildError(result, target: target, team: team)
        }
        try Task.checkCancellation()
        try publishCompletion(in: derivedData, key: key)
        return productsDir
    }

    /// The products of the newest completed build of `key` under `builds`, and the derived data folder for the next build.
    /// A rebuild goes to a new `<sim|device>-<digest>` folder, since other devices on the team can be installing from
    /// a completed one.
    static func buildFolders(for key: String, in builds: URL = Paths.runnerBuilds) -> (published: URL?, next: URL) {
        var published: URL?
        var next = builds.appending(path: key)
        while let products = completedProducts(in: next, key: key) {
            published = products
            next = builds.appending(path: "\(key.prefix { $0 != "-" })-\(digest(Data((key + next.lastPathComponent).utf8)))")
        }
        return (published, next)
    }

    /// The products in `derivedData` when they hold an xctestrun and its completion marker matches `key`.
    static func completedProducts(in derivedData: URL, key: String) -> URL? {
        let marker = completionMarker(in: derivedData)
        guard (try? marker.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
            (try? Data(contentsOf: marker)) == Data(key.utf8)
        else { return nil }
        let products = derivedData.appending(path: "Build/Products")
        return existingXctestrun(in: products) == nil ? nil : products
    }

    /// Writes the completion marker for `key`. Throws when the products have no template.
    static func publishCompletion(in derivedData: URL, key: String) throws {
        guard existingXctestrun(in: derivedData.appending(path: "Build/Products")) != nil else {
            throw DeviceLoopError(.runnerBuildFailed, "The completed runner build has no test configuration.")
        }
        try Data(key.utf8).write(to: completionMarker(in: derivedData), options: .atomic)
    }

    private static func completionMarker(in derivedData: URL) -> URL {
        derivedData.appending(path: ".deviceloop-build-complete")
    }

    /// The interactive runner's xctestrun, which runs only `DeviceLoopRunner/testServe` with its token and bind address.
    static func writeServeXctestrun(from products: URL, token: String, bind: String) throws -> URL {
        try writeSessionXctestrun(
            from: products, tests: ["DeviceLoopRunner/testServe"],
            environment: [RunnerWire.Environment.token: token, RunnerWire.Environment.bind: bind, RunnerWire.Environment.port: "0"]
        )
    }

    /// A finite xctestrun that runs only `DeviceLoopMeasure/<test>` with `scenario`.
    static func writeMeasureXctestrun(from products: URL, test: String, scenario: MeasureScenario) throws -> URL {
        try writeSessionXctestrun(
            from: products, tests: ["DeviceLoopMeasure/\(test)"],
            environment: [RunnerWire.Environment.scenario: String(decoding: try JSONEncoder().encode(scenario), as: UTF8.self)]
        )
    }

    /// Writes a uniquely named, owner-only xctestrun next to the built products (so its __TESTROOT__ paths resolve)
    /// that runs only `tests`, with `environment` and the capture-off keys.
    private static func writeSessionXctestrun(from products: URL, tests: [String], environment extra: [String: String]) throws -> URL {
        guard let template = existingXctestrun(in: products), var plist = propertyList(at: template) else {
            throw DeviceLoopError(.internalError, "The runner build produced no xctestrun.")
        }
        guard let targetKey = plist.keys.first(where: { $0 != "__xctestrun_metadata__" }),
            var targetConfig = plist[targetKey] as? [String: Any]
        else {
            throw DeviceLoopError(.internalError, "The runner xctestrun has no test target.")
        }

        var environment = targetConfig["TestingEnvironmentVariables"] as? [String: Any] ?? [:]
        environment.merge(extra) { _, new in new }
        targetConfig["TestingEnvironmentVariables"] = environment
        targetConfig["OnlyTestIdentifiers"] = tests
        targetConfig["PreferredScreenCaptureFormat"] = "screenshots"
        targetConfig["SystemAttachmentLifetime"] = "keepNever"
        targetConfig["UserAttachmentLifetime"] = "keepNever"
        targetConfig["UITargetAppPerformanceAntipatternCheckerEnabled"] = false
        plist[targetKey] = targetConfig

        let destination = products.appending(path: "run-\(UUID().uuidString).xctestrun")
        let output = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        do {
            try Paths.writePrivate(output, to: destination)
        } catch {
            throw DeviceLoopError(
                .internalError, "Could not write the private runner test configuration.",
                fix: "Check write permissions at \(products.path)."
            )
        }
        return destination
    }

    /// The bundle ID of the app the runner drives by default, read from the app that `xctestrun` names.
    static func hostBundleIdentifier(xctestrun: URL) -> String? {
        guard let app = hostApp(xctestrun: xctestrun) else { return nil }
        return propertyList(at: app.appending(path: "Info.plist"))?["CFBundleIdentifier"] as? String
    }

    /// The app that `xctestrun` names as `UITargetAppPath`.
    private static func hostApp(xctestrun: URL) -> URL? {
        guard let plist = propertyList(at: xctestrun),
            let config = plist.first(where: { $0.key != "__xctestrun_metadata__" })?.value as? [String: Any],
            let appPath = config["UITargetAppPath"] as? String
        else { return nil }
        let products = xctestrun.deletingLastPathComponent().path
        return URL(filePath: appPath.replacingOccurrences(of: "__TESTROOT__", with: products))
    }

    private static func propertyList(at url: URL) -> [String: Any]? {
        guard let contents = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: contents, format: nil) as? [String: Any]
    }

    /// The host app's `embedded.mobileprovision` in `products`, decoded by `security cms -D`.
    private static func decodedHostProfile(in products: URL) async -> Data? {
        guard let template = existingXctestrun(in: products), let app = hostApp(xctestrun: template),
            let result = try? await Shell.run(
                ["security", "cms", "-D", "-i", app.appending(path: "embedded.mobileprovision").path], timeout: .seconds(20)),
            result.succeeded
        else { return nil }
        return result.stdout
    }

    /// Creates the runner workspace's `xcshareddata/swiftpm/configuration` and sets it and its two parents to 0755.
    static func createSwiftPMConfiguration(in project: URL) {
        let shared = project.appending(path: "DeviceLoopRunner.xcodeproj/project.xcworkspace/xcshareddata", directoryHint: .isDirectory)
        let swiftpm = shared.appending(path: "swiftpm", directoryHint: .isDirectory)
        let configurationDirectory = swiftpm.appending(path: "configuration", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: configurationDirectory, withIntermediateDirectories: true)
        for directory in [configurationDirectory, swiftpm, shared] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
    }

    /// Whether a decoded provisioning profile expires after `now` and lists `udid` in `ProvisionedDevices` or sets
    /// `ProvisionsAllDevices`.
    static func profileUsable(_ decoded: Data, udid: String, now: Date = Date()) -> Bool {
        guard let profile = try? PropertyListSerialization.propertyList(from: decoded, format: nil) as? [String: Any],
            let expiration = profile["ExpirationDate"] as? Date, expiration > now
        else { return false }
        if profile["ProvisionsAllDevices"] as? Bool == true { return true }
        let devices = profile["ProvisionedDevices"] as? [String] ?? []
        return devices.contains { $0.caseInsensitiveCompare(udid) == .orderedSame }
    }

    /// The first xctestrun in `products` by name, skipping the `run-` files DeviceLoop writes with a runner token.
    static func existingXctestrun(in products: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return files.filter {
            $0.pathExtension == "xctestrun" && !$0.lastPathComponent.hasPrefix("run-")
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    private static func signingTeam(_ target: Target) throws -> String {
        guard let team = DeviceLoopConfig.team() else {
            throw DeviceLoopError(
                .signingNoTeam,
                "No signing team is set, and the runner must be signed to run on \(target.name).",
                fix: "Run `deviceloop setup --team <ID>`, or add an Apple ID in Xcode > Settings > Accounts."
            )
        }
        return team
    }

    private static func cacheKey(project: URL, simulator: Bool, team: String?) async throws -> String {
        let xcodeBuild = try xcodeBuildVersion(try await toolIdentity(["xcrun", "xcodebuild", "-version"]))
        let xcodePath = try await toolIdentity(["xcrun", "--find", "xcodebuild"])
        let sdk = simulator ? "iphonesimulator" : "iphoneos"
        let sdkBuild = try await toolIdentity(["xcrun", "--sdk", sdk, "--show-sdk-build-version"])
        let compiler = try await toolIdentity(["xcrun", "swiftc", "--version"])
        let compilerPath = try await toolIdentity(["xcrun", "--find", "swiftc"])
        var identity = [xcodeBuild, xcodePath, sdkBuild, compiler, compilerPath]
        // Xcode permits a configuration override outside the project directory.
        if let override = ProcessInfo.processInfo.environment["XCODE_XCCONFIG_FILE"], !override.isEmpty {
            identity += [override, try digest(Data(contentsOf: URL(filePath: override)))]
        }
        return try cacheIdentity(project: project, simulator: simulator, team: team, configuration: configuration, toolchain: identity)
    }

    private static func toolIdentity(_ arguments: [String]) async throws -> String {
        let result = try await Shell.run(arguments, timeout: .seconds(20))
        let value = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !value.isEmpty else {
            throw DeviceLoopError(
                .xcodeMissing, "Could not identify the runner build toolchain.",
                fix: "Select a complete Xcode installation with xcode-select and retry.",
                detail: "Failed to read \(arguments.joined(separator: " "))."
            )
        }
        return value
    }

    static func xcodeBuildVersion(_ output: String) throws -> String {
        let lines = output.split(whereSeparator: \.isNewline)
        guard lines.contains(where: { $0.hasPrefix("Xcode ") }),
            let buildLine = lines.first(where: { $0.hasPrefix("Build version ") }),
            let build = buildLine.split(separator: " ").last, build != "version", !build.isEmpty
        else {
            throw DeviceLoopError(
                .xcodeMissing, "Could not identify the selected Xcode build.",
                fix: "Select a complete Xcode installation with xcode-select and retry."
            )
        }
        return String(build)
    }

    /// Hashes ordered, length-delimited identity fields and runner inputs, independent of checkout location and mtimes.
    static func cacheIdentity(
        project: URL, simulator: Bool, team: String?, configuration: String, toolchain: [String]
    ) throws -> String {
        let root = project.standardizedFileURL
        var hasher = SHA256()
        func append(_ data: Data) {
            hasher.update(data: Data("\(data.count):".utf8))
            hasher.update(data: data)
        }
        for field in ["runner-cache-v2", simulator ? "sim" : "device", team ?? "", configuration] + toolchain {
            append(Data(field.utf8))
        }
        let manager = FileManager.default
        // Only local output and user-specific Xcode state are excluded. Resources of any type are inputs.
        let excluded: Set<String> = [".git", "xcuserdata", ".DS_Store"]
        let rootOutputs: Set<String> = [".build", "build", "DerivedData"]
        func files(in directory: URL) throws -> [URL] {
            var result: [URL] = []
            for entry in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) {
                if excluded.contains(entry.lastPathComponent)
                    || (directory == root && rootOutputs.contains(entry.lastPathComponent))
                {
                    continue
                }
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values.isDirectory == true {
                    result += try files(in: entry)
                } else if values.isRegularFile == true {
                    result.append(entry)
                }
            }
            return result
        }
        let inputs = try files(in: root).sorted { $0.path < $1.path }
        guard !inputs.isEmpty else {
            throw DeviceLoopError(
                .runnerBuildFailed, "The runner project has no build inputs.", fix: "Reinstall the runner resources and retry.")
        }
        for file in inputs {
            append(Data(file.path.dropFirst(root.path.count + 1).utf8))
            append(try Data(contentsOf: file))
        }
        return "\(simulator ? "sim" : "device")-\(hasher.finalize().map { String(format: "%02x", $0) }.joined())"
    }

    /// The SHA-256 of `contents` as lowercase hex.
    static func digest(_ contents: Data) -> String {
        SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
    }

    /// The last xcodebuild `error:` line about a missing or unusable provisioning profile.
    static func provisioningError(in log: String) -> String? {
        log.split(separator: "\n").last { line in
            guard let error = line.range(of: "error: ") else { return false }
            let message = line[error.upperBound...]
            return message.hasPrefix("No profiles") || message.hasPrefix("Provisioning profile")
                || message.contains("requires a provisioning profile")
        }.map(String.init)
    }

    static func buildError(_ result: ShellResult, target: Target, team: String?) -> DeviceLoopError {
        let text = result.stderrString + result.stdoutString
        let errorLine = text.split(separator: "\n").last(where: { $0.lowercased().contains("error") }).map(String.init)
        if text.contains("has no devices") || text.contains("doesn't include the currently selected device") {
            return DeviceLoopError(
                .signingProfileFailed,
                "The runner's provisioning profile does not include \(target.name).",
                fix: "Add \(target.name) (UDID \(target.udid)) to team \(team ?? "<ID>") under Devices on developer.apple.com, "
                    + "or ask a team admin to. A personal team adds it when Xcode runs any app on it. Then retry.",
                detail: errorLine,
                device: target.name
            )
        }
        if let line = provisioningError(in: text) {
            return DeviceLoopError(
                .signingProfileFailed,
                "The runner could not be signed for \(target.name).",
                fix: "Check Xcode > Settings > Accounts, then `deviceloop setup --team <ID>`. Free teams allow 10 App IDs every 7 days.",
                detail: line,
                device: target.name
            )
        }
        return DeviceLoopError(
            .runnerBuildFailed,
            "Building the runner for \(target.name) failed.",
            detail: errorLine ?? "exit \(result.status)",
            device: target.name
        )
    }
}
