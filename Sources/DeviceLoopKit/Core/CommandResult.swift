//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// What every command returns. The CLI prints `text` or `json`, the MCP server sends all of it.
public struct CommandResult: Sendable {
    /// Compact, agent-readable text. The first line names the target the command ran on.
    public var text: String
    /// Structured payload for `--json` and MCP `structuredContent`.
    public var json: JSONValue
    /// Images an agent should see, for example a point-sized screenshot or a contact sheet.
    public var images: [ImageAttachment]
    /// Artifacts written to disk, for example the full-resolution PNG or a video.
    public var files: [URL]

    public init(text: String, json: JSONValue = .null, images: [ImageAttachment] = [], files: [URL] = []) {
        self.text = text
        self.json = json
        self.images = images
        self.files = files
    }

    public init<T: Encodable>(text: String, payload: T, images: [ImageAttachment] = [], files: [URL] = []) throws {
        self.init(text: text, json: try JSONValue(encoding: payload), images: images, files: files)
    }
}

public struct ImageAttachment: Sendable {
    public var data: Data
    /// `image/jpeg` or `image/png`.
    public var mimeType: String
    /// Where the same image, or its full-resolution original, was saved.
    public var path: URL?

    public init(data: Data, mimeType: String, path: URL? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.path = path
    }
}
