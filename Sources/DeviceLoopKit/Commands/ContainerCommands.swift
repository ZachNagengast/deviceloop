//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Darwin
import Foundation

/// `deviceloop container`: files in an app's data container. Simulators use the container folder on the Mac from
/// `simctl get_app_container`, devices the devicectl `appDataContainer` file domain.
public enum ContainerCommands {
    /// Every file and folder under `path`, or in the whole container, with paths relative to the container.
    public static func list(_ target: Target, bundleID: String, path: String?) async throws -> CommandResult {
        try Validate.bundleID(bundleID)
        if let path { try Validate.containerPath(path) }
        let files: [ContainerFile]
        if target.isSimulator {
            files = try listing(in: try await simulatorRoot(target, bundleID: bundleID), under: path, bundleID: bundleID)
        } else {
            try DeviceQueries.require(Capability.listFiles, "Listing app files", on: target)
            try await requireContainer(target, bundleID: bundleID)
            files = try await deviceListing(target, bundleID: bundleID, under: path)
        }
        let header =
            "\(files.count) item\(files.count == 1 ? "" : "s") in the data container of \(bundleID)" + (path.map { " under \($0)" } ?? "")
        let rows = files.map { file in
            [file.modified ?? "-", file.size.map(String.init) ?? "-", file.directory ? file.path + "/" : file.path]
        }
        return CommandResult(
            text: ([target.summary, header] + ParityText.table(rows)).joined(separator: "\n"),
            json: ["bundleID": .string(bundleID), "path": path.map(JSONValue.string) ?? .null, "files": try JSONValue(encoding: files)]
        )
    }

    /// Copies one file out of the container into `directory`, or the artifacts folder when nil. A different file already
    /// at the destination is never replaced. Folders are refused.
    public static func pull(_ target: Target, bundleID: String, path: String, to directory: URL?) async throws -> CommandResult {
        try Validate.bundleID(bundleID)
        try Validate.containerPath(path)
        let contents: Data
        if target.isSimulator {
            let root = try await simulatorRoot(target, bundleID: bundleID)
            contents = try readFile(try resolve(path, in: root, bundleID: bundleID), path: path, bundleID: bundleID)
        } else {
            try DeviceQueries.require(Capability.transferFiles, "Pulling app files", on: target)
            try await requireContainer(target, bundleID: bundleID)
            let download = FileManager.default.temporaryDirectory.appending(path: "deviceloop-container-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: download) }
            let arguments =
                Devicectl.device(target, "copy", "from") + domain(bundleID) + ["--source", path, "--destination", download.path]
            _ = try await Devicectl.run(arguments, target: target, timeout: .seconds(120))
            contents = try readFile(download, path: path, bundleID: bundleID)
        }
        let destination = try CrashCommands.pullDestination(for: path, in: directory, artifacts: "container")
        try CrashCommands.save(contents, to: destination, overwrite: false)
        let digest = CrashCommands.sha256(contents)
        return CommandResult(
            text: "\(target.summary)\n\(bundleID) \(path), \(contents.count) bytes\nsha256 \(digest)\nsaved \(destination.path)",
            json: [
                "bundleID": .string(bundleID), "source": .string(path), "path": .string(destination.path),
                "size": .number(Double(contents.count)), "sha256": .string(digest), "udid": .string(target.udid),
            ],
            files: [destination]
        )
    }

    /// Copies the file `source` on this Mac to `path` in the container while the app is not running. An existing file is
    /// replaced only with `overwrite`.
    public static func push(_ target: Target, bundleID: String, source: URL, path: String, overwrite: Bool) async throws
        -> CommandResult
    {
        try Validate.bundleID(bundleID)
        try Validate.containerPath(path)
        let source = source.absoluteURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw DeviceLoopError(.badArguments, "\(source.path) is not a file.", fix: "Pass one file. Folders are not pushed.")
        }
        let contents = try Data(contentsOf: source)
        var root: URL?
        if target.isSimulator {
            root = try await simulatorRoot(target, bundleID: bundleID)
        } else {
            try DeviceQueries.require(Capability.transferFiles, "Pushing app files", on: target)
            try await requireContainer(target, bundleID: bundleID)
        }
        if let pids = try await DeviceQueries.runningApps(target)[bundleID], !pids.isEmpty {
            throw DeviceLoopError(
                .appRunning,
                "\(bundleID) is running on \(target.summary), pid \(pids.map(String.init).joined(separator: ", ")).",
                fix: "Terminate it first: deviceloop terminate \(bundleID)",
                device: target.name
            )
        }
        if let root {
            try write(contents, to: path, in: root, bundleID: bundleID, overwrite: overwrite)
        } else {
            if !overwrite || path.contains("/") {
                try DeviceQueries.require(Capability.listFiles, "Checking app files", on: target)
                let listing = try await deviceListing(target, bundleID: bundleID, under: nil)
                try checkPush(path, listing: listing, bundleID: bundleID, overwrite: overwrite)
            }
            let arguments =
                Devicectl.device(target, "copy", "to") + domain(bundleID) + ["--source", source.path, "--destination", path]
            _ = try await Devicectl.run(arguments, target: target, timeout: .seconds(120))
        }
        let digest = CrashCommands.sha256(contents)
        return CommandResult(
            text: "\(target.summary)\nPushed \(source.lastPathComponent) to \(bundleID) \(path), \(contents.count) bytes\n"
                + "sha256 \(digest)\nnot journaled, DeviceLoop cannot undo this push",
            json: [
                "bundleID": .string(bundleID), "source": .string(source.path), "path": .string(path),
                "size": .number(Double(contents.count)), "sha256": .string(digest), "overwrite": .bool(overwrite), "journaled": false,
                "udid": .string(target.udid),
            ]
        )
    }

    /// Files and folders under `path` in the container folder `root`, sorted by path. Links are listed, not followed.
    static func listing(in root: URL, under path: String?, bundleID: String) throws -> [ContainerFile] {
        let folder = try path.map { try resolve($0, in: root, bundleID: bundleID) } ?? root
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
            let walker = FileManager.default.enumerator(atPath: folder.path)
        else { throw missing(path ?? "", bundleID: bundleID) }
        guard isDirectory.boolValue else {
            throw DeviceLoopError(
                .badArguments, "\(path ?? "") is a file in the data container of \(bundleID).",
                fix: "Pull it with `deviceloop container pull \(bundleID) \(path ?? "")`.")
        }
        let prefix = path.map { $0 + "/" } ?? ""
        var files: [ContainerFile] = []
        while let name = walker.nextObject() as? String {
            let attributes = walker.fileAttributes
            let directory = attributes?[.type] as? FileAttributeType == .typeDirectory
            files.append(
                ContainerFile(
                    path: prefix + name, directory: directory, size: directory ? nil : (attributes?[.size] as? NSNumber)?.intValue,
                    modified: (attributes?[.modificationDate] as? Date)?.ISO8601Format()))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Throws bad_arguments when `listing` has no folder for `path`, since devicectl does not create one, or already has
    /// `path` and `overwrite` is false.
    static func checkPush(_ path: String, listing: [ContainerFile], bundleID: String, overwrite: Bool) throws {
        let folder = (path as NSString).deletingLastPathComponent
        if !folder.isEmpty, !listing.contains(where: { $0.path == folder && $0.directory }) {
            throw missing(path, bundleID: bundleID)
        }
        if !overwrite, listing.contains(where: { $0.path == path }) {
            throw exists(path, bundleID: bundleID)
        }
    }

    /// Writes `data` to `path` in the container folder `root`. An existing file is replaced only with `overwrite`.
    static func write(_ data: Data, to path: String, in root: URL, bundleID: String, overwrite: Bool) throws {
        let file = try resolve(path, in: root, bundleID: bundleID)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw DeviceLoopError(
                .badArguments, "\(path) is a folder in the data container of \(bundleID).",
                fix: "Pass the path of a file inside it, for example \(path)/name.")
        }
        do {
            try data.write(to: file, options: overwrite ? .atomic : .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            throw exists(path, bundleID: bundleID)
        }
    }

    /// `path` inside the container folder `root` with every link resolved. Throws bad_arguments when neither it nor its
    /// folder exists, or when it resolves outside `root`.
    static func resolve(_ path: String, in root: URL, bundleID: String) throws -> URL {
        guard let base = realPath(root), let resolved = realPath(root.appending(path: path)) else {
            throw missing(path, bundleID: bundleID)
        }
        guard resolved == base || resolved.hasPrefix(base + "/") else {
            throw DeviceLoopError(
                .badArguments, "\(path) leads outside the data container of \(bundleID).",
                fix: "Pass a path inside the container. Links that point out of it are refused.")
        }
        return URL(filePath: resolved)
    }

    /// The bytes of the file at `url`. Folders are refused.
    static func readFile(_ url: URL, path: String, bundleID: String) throws -> Data {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw missing(path, bundleID: bundleID) }
        guard !isDirectory.boolValue else {
            throw DeviceLoopError(
                .badArguments, "\(path) is a folder in the data container of \(bundleID).",
                fix: "Pull one file at a time. `deviceloop container \(bundleID) --path \(path)` lists the folder.")
        }
        return try Data(contentsOf: url)
    }

    /// Throws unsupported_on_target when devicectl reports that it cannot reach the app's container.
    static func checkAccessible(_ app: InstalledApp, on target: Target) throws {
        guard app.containerAccessible != false else {
            throw DeviceLoopError(
                .unsupportedOnTarget,
                "The data container of \(app.bundleID) is not accessible on \(target.summary).",
                fix: "Install a development-signed build of the app.",
                device: target.name
            )
        }
    }

    /// The real path of `url`, or of its folder plus its name when nothing is at `url`. Nil for a broken link, or when
    /// the folder is missing too.
    private static func realPath(_ url: URL) -> String? {
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil,
            let folder = realpath(url.deletingLastPathComponent().path, nil)
        else { return nil }
        defer { free(folder) }
        return String(cString: folder) + "/" + url.lastPathComponent
    }

    /// The data container folder of an installed app on a simulator.
    private static func simulatorRoot(_ target: Target, bundleID: String) async throws -> URL {
        try DeviceQueries.requireReady(target)
        guard try await DeviceQueries.installedApp(target, bundleID: bundleID) != nil else {
            throw DeviceQueries.appNotInstalled(bundleID, on: target)
        }
        let result = try await Simctl.run(["get_app_container", target.udid, bundleID, "data"])
        return URL(filePath: result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), directoryHint: .isDirectory)
    }

    private static func requireContainer(_ target: Target, bundleID: String) async throws {
        guard let app = try await DeviceQueries.installedApp(target, bundleID: bundleID) else {
            throw DeviceQueries.appNotInstalled(bundleID, on: target)
        }
        try checkAccessible(app, on: target)
    }

    private static func deviceListing(_ target: Target, bundleID: String, under path: String?) async throws -> [ContainerFile] {
        let arguments = Devicectl.device(target, "info", "files") + domain(bundleID) + (path.map { ["--subdirectory", $0] } ?? [])
        return ContainerFile.list(devicectl: try await Devicectl.run(arguments, target: target), under: path)
    }

    private static func domain(_ bundleID: String) -> [String] {
        ["--domain-type", "appDataContainer", "--domain-identifier", bundleID]
    }

    private static func missing(_ path: String, bundleID: String) -> DeviceLoopError {
        DeviceLoopError(
            .badArguments, "Nothing at \(path) in the data container of \(bundleID).",
            fix: "Run `deviceloop container \(bundleID)` for the paths.")
    }

    private static func exists(_ path: String, bundleID: String) -> DeviceLoopError {
        DeviceLoopError(
            .badArguments, "\(path) already exists in the data container of \(bundleID).",
            fix: "Pass --overwrite to replace it, or push to another path.")
    }
}
