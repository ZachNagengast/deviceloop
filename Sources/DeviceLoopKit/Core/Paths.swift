//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// Where DeviceLoop keeps runner builds, sessions and artifacts.
public enum Paths {
    /// `$DEVICELOOP_HOME`, or `~/Library/Caches/deviceloop`.
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["DEVICELOOP_HOME"], !override.isEmpty {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/deviceloop", directoryHint: .isDirectory)
    }

    /// Per-target runner session state: session file, xctestrun, xcodebuild log, result bundle.
    public static func session(for udid: String) -> URL {
        home.appending(path: "sessions/\(udid)", directoryHint: .isDirectory)
    }

    /// Runner build products, keyed by everything that changes the build.
    public static var runnerBuilds: URL {
        home.appending(path: "runner", directoryHint: .isDirectory)
    }

    /// Run directories, each with a manifest, an event journal and artifacts.
    public static var runs: URL {
        home.appending(path: "runs", directoryHint: .isDirectory)
    }

    /// Screenshots, videos and contact sheets. Inside a run, the run's `artifacts` folder.
    public static var artifacts: URL {
        RunStore.current?.artifacts ?? home.appending(path: "artifacts", directoryHint: .isDirectory)
    }

    /// One JSON line per MCP tool call.
    public static var mcpLog: URL {
        home.appending(path: "logs/mcp.jsonl")
    }

    /// Creates `url` (and parents) with 0700 permissions.
    @discardableResult
    public static func ensureDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Writes `data` to `url` with 0600 permissions through a temporary file and a rename, so readers never see part of it.
    public static func writePrivate(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// A new path under `artifacts`, for example `screenshot-20261022-131927-412-3f9a2c.png`, or `test-...-3f9a2c` without an extension.
    public static func newArtifact(_ prefix: String, extension ext: String? = nil) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let directory = try ensureDirectory(artifacts)
        let suffix = UUID().uuidString.prefix(6).lowercased()
        let name = "\(prefix)-\(formatter.string(from: Date()))-\(suffix)"
        return directory.appending(path: ext.map { "\(name).\($0)" } ?? name)
    }

    /// `<prefix>/libexec/DeviceLoopCapture.app` next to the resolved `executable`, or nil when it is not installed.
    public static func bundledCaptureApp(executable: URL? = Bundle.main.executableURL) -> URL? {
        guard let bin = executable?.resolvingSymlinksInPath().deletingLastPathComponent() else { return nil }
        let app = bin.appending(path: "../libexec/DeviceLoopCapture.app", directoryHint: .isDirectory).standardizedFileURL
        return FileManager.default.fileExists(atPath: app.appending(path: "Contents/Info.plist").path) ? app : nil
    }

    /// The runner Xcode project: `$DEVICELOOP_RUNNER_PATH`, `<prefix>/share/deviceloop/Runner` next to the
    /// resolved executable, or `Runner/` in a source checkout. Nil when the folder found holds no runner project.
    public static var runnerProject: URL? {
        if let override = ProcessInfo.processInfo.environment["DEVICELOOP_RUNNER_PATH"] {
            let project = URL(filePath: override, directoryHint: .isDirectory)
            return FileManager.default.fileExists(atPath: project.appending(path: "DeviceLoopRunner.xcodeproj/project.pbxproj").path)
                ? project : nil
        }
        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let bin = executable.deletingLastPathComponent()
            candidates.append(bin.appending(path: "../share/deviceloop/Runner").standardizedFileURL)
            var directory = bin
            for _ in 0 ..< 6 {
                directory = directory.deletingLastPathComponent()
                candidates.append(directory.appending(path: "Runner"))
            }
        }
        #if DEBUG
            candidates.append(URL(filePath: #filePath).appending(path: "../../../../Runner").standardizedFileURL)
        #endif
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appending(path: "DeviceLoopRunner.xcodeproj/project.pbxproj").path)
        }
    }
}
