//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Darwin
import Foundation

/// Stdio MCP server: newline-delimited JSON-RPC 2.0 on stdin and stdout, logs on stderr.
public enum MCPServer {
    static let supportedVersions = ["2025-03-26", "2025-06-18", "2025-11-25"]
    static let latestVersion = "2025-11-25"

    static let baseInstructions = """
        DeviceLoop drives iPhones, iPads and simulators paired with this Mac through devicectl, simctl and an XCUITest runner.
        Pick a target with `device` (a UDID, a name or a unique part of it, `booted`, `usb` or `device`). Omit it when exactly one device or simulator is ready. device_list shows them.
        Loop: screen_capture or ui_tree, act (ui_tap, ui_type, ui_swipe, app_launch, url_open, device_set), then observe again to verify.
        Screenshots come back at point size, so image pixels are screen points that ui_tap takes as x,y.
        ui_tree lists elements with refs. Pass `@<ref>`, x,y, `id=<identifier>` or a label to ui_tap, ui_type or ui_swipe. \
        The first ui tool call starts the UI runner on the target.
        flow_run runs a flow (schema deviceloop.flow/1) of taps, typing, asserts and screenshots, and flow_validate checks one \
        without a device. flow_run returns the result, or a run_id while the flow still runs. Then call flow_status until the \
        flow finishes, or flow_cancel to stop it.
        For animation and transition questions use video_capture with one step such as `tap id=login`, `swipe up` or `launch <bundle ID>`, \
        or video_record start, act, then video_record stop. video_inspect analyzes a saved recording.
        test_run runs the XCTest and Swift Testing tests of a project, workspace or .xctestrun. When it returns a running job, \
        call test_status until it finishes, or test_cancel to stop it.
        Errors start with `ERROR <code>`. `(needs user)` means only the person at the device can fix it: relay the Fix line, then retry.
        device_doctor checks setup and connection with one fix per problem.
        To keep a record of a test, call run start, then the tools, then run stop. Every call on that device in between is \
        journaled with its result and files in a run folder, and run stop returns the report.
        """

    /// The server instructions, with a line that names `DEVICELOOP_DEVICE` when it is set.
    static func instructions(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        guard let device = environment["DEVICELOOP_DEVICE"]?.trimmingCharacters(in: .whitespaces), !device.isEmpty else {
            return baseInstructions
        }
        return baseInstructions + "\nDEVICELOOP_DEVICE is \(device), so tools act on that target when `device` is left out. "
            + "device_list gives its UDID as defaultDevice."
    }

    /// Serves until stdin closes, then waits for running tool calls, cancelled flow runs and test jobs to finish.
    public static func serve(version: String = "dev") async throws {
        // Points fd 1 at stderr so stray prints cannot corrupt the protocol stream.
        let protocolOutput = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)
        let session = MCPSession(tools: MCPTools.all, serverVersion: version) { line in
            protocolOutput.write(Data((line + "\n").utf8))
        }
        try await session.run(FileHandle.standardInput.bytes)
        await MCPTools.flowJobs.finishAll()
        try await MCPTools.waitForTestJobs()
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("deviceloop mcp: \(message)\n".utf8))
    }

    /// One text item, one image item per attachment, and the JSON payload as `structuredContent`.
    static func toolResult(_ result: CommandResult, isError: Bool = false) -> JSONValue {
        var content: [JSONValue] = [["type": "text", "text": .string(result.text)]]
        for image in result.images {
            content.append(["type": "image", "data": .string(image.data.base64EncodedString()), "mimeType": .string(image.mimeType)])
        }
        var fields: [String: JSONValue] = ["content": .array(content), "isError": .bool(isError)]
        switch result.json {
            case .null: break
            case .object: fields["structuredContent"] = result.json
            default: fields["structuredContent"] = ["result": result.json]
        }
        return .object(fields)
    }

    static func toolResult(_ error: DeviceLoopError) -> JSONValue {
        [
            "content": [["type": "text", "text": .string(error.rendered)]],
            "structuredContent": ["ok": false, "error": (try? JSONValue(encoding: error)) ?? .null],
            "isError": true,
        ]
    }
}

/// One client connection. Tool calls run concurrently so `notifications/cancelled` and `ping` are answered meanwhile.
actor MCPSession {
    private let tools: [MCPTool]
    private let toolsByName: [String: MCPTool]
    private let serverVersion: String
    private let resolve: MCPArguments.Resolve
    private let output: @Sendable (String) -> Void
    private var running: [JSONValue: Task<Void, Never>] = [:]

    init(
        tools: [MCPTool], serverVersion: String, resolve: @escaping MCPArguments.Resolve = TargetResolver.resolve,
        output: @escaping @Sendable (String) -> Void
    ) {
        self.tools = tools
        self.toolsByName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.serverVersion = serverVersion
        self.resolve = resolve
        self.output = output
    }

    /// Reads newline-delimited messages until `input` ends, then waits for running tool calls.
    nonisolated func run<Input: AsyncSequence>(_ input: Input) async throws where Input.Element == UInt8 {
        var line: [UInt8] = []
        for try await byte in input {
            if byte == UInt8(ascii: "\n") {
                await receive(String(decoding: line, as: UTF8.self))
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(byte)
            }
        }
        if !line.isEmpty { await receive(String(decoding: line, as: UTF8.self)) }
        await drain()
    }

    func receive(_ line: String) {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let message = try? JSONValue(data: Data(text.utf8)) else {
            return reply(.null, code: -32700, message: "Parse error: each line must be one JSON-RPC message.")
        }
        guard case .object(let fields) = message else {
            return reply(.null, code: -32600, message: "Invalid request: expected a JSON object.")
        }
        let id = fields["id"]
        guard let method = fields["method"]?.string else {
            // Client responses carry no method and are dropped.
            if id == nil || fields["result"] != nil || fields["error"] != nil { return }
            return reply(id ?? .null, code: -32600, message: "Invalid request: missing method.")
        }
        let params = fields["params"] ?? [:]
        guard let id else { return notification(method, params) }

        switch method {
            case "initialize":
                let requested = params["protocolVersion"]?.string ?? ""
                reply(
                    id,
                    result: [
                        "protocolVersion": .string(MCPServer.supportedVersions.contains(requested) ? requested : MCPServer.latestVersion),
                        "capabilities": ["tools": ["listChanged": false]],
                        "serverInfo": ["name": "deviceloop", "version": .string(serverVersion)],
                        "instructions": .string(MCPServer.instructions()),
                    ]
                )
            case "ping":
                reply(id, result: [:])
            case "tools/list":
                reply(id, result: ["tools": .array(tools.map(\.definition))])
            case "tools/call":
                guard let name = params["name"]?.string, let tool = toolsByName[name] else {
                    return reply(id, code: -32602, message: "Unknown tool: \(params["name"]?.string ?? "missing name").")
                }
                let arguments = params["arguments"] ?? [:]
                running[id] = Task.detached { [serverVersion, resolve] in
                    let result = await tool.call(arguments, serverVersion: serverVersion, resolve: resolve)
                    await self.complete(id, result)
                }
            default:
                reply(id, code: -32601, message: "Method not found: \(method).")
        }
    }

    private func notification(_ method: String, _ params: JSONValue) {
        guard method == "notifications/cancelled", let requestID = params["requestId"] else { return }
        guard let task = running.removeValue(forKey: requestID) else { return }
        task.cancel()
        MCPServer.log("cancelled request \(requestID): \(params["reason"]?.string ?? "no reason given")")
    }

    private func complete(_ id: JSONValue, _ result: JSONValue) {
        // A cancelled call was already removed and gets no response.
        guard running.removeValue(forKey: id) != nil else { return }
        reply(id, result: result)
    }

    private func drain() async {
        while let task = running.values.first {
            await task.value
        }
    }

    private func reply(_ id: JSONValue, result: JSONValue) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func reply(_ id: JSONValue, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]])
    }

    private func send(_ message: JSONValue) {
        do {
            output(String(decoding: try message.data(), as: UTF8.self))
        } catch {
            MCPServer.log("could not encode a response: \(error)")
        }
    }
}
