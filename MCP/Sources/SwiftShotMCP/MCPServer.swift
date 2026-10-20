import Foundation

/// The MCP server: speaks JSON-RPC 2.0 over stdio and forwards the tool calls
/// to the running SwiftShot app.
final class MCPServer {
    private let client: BridgeClient
    private let output: OutputStreamWriter

    init(client: BridgeClient = BridgeClient(), output: OutputStreamWriter = OutputStreamWriter()) {
        self.client = client
        self.output = output
    }

    // MARK: - Main loop

    func run() {
        let stdin = FileHandle.standardInput
        var buffer = Data()

        // Announce that the server is up (some clients look for it on stderr).
        FileHandle.standardError.write(Data("swiftshot-mcp \(ToolCatalogue.version) ready\n".utf8))

        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty {
                // stdin closed -> shut down.
                break
            }
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                let trimmed = String(decoding: line, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                handle(line: Data(trimmed.utf8))
            }
        }
    }

    private func handle(line: Data) {
        guard let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            sendError(id: nil, code: -32700, message: "parse error")
            return
        }
        let id = request["id"]
        let method = request["method"] as? String ?? ""

        switch method {
        case "initialize":
            sendResult(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": [
                    "name": "swiftshot-mcp",
                    "version": ToolCatalogue.version,
                ],
                "instructions": """
                SwiftShot gives you screenshots of the macOS screen.
                Call `swiftshot_capture` to take one — the image is returned
                directly. Use `swiftshot_displays` first when you need a
                specific monitor.
                """,
            ])

        case "notifications/initialized", "notifications/cancelled":
            break // notifications have no response

        case "ping":
            sendResult(id: id, result: [:])

        case "tools/list":
            sendResult(id: id, result: ["tools": ToolCatalogue.all.map { $0.payload }])

        case "tools/call":
            guard let params = request["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                sendError(id: id, code: -32602, message: "invalid tool call")
                return
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            callTool(name: name, arguments: arguments, id: id)

        case "resources/list":
            sendResult(id: id, result: ["resources": []])

        case "prompts/list":
            sendResult(id: id, result: ["prompts": []])

        default:
            if id != nil {
                sendError(id: id, code: -32601, message: "method not found: \(method)")
            }
        }
    }

    // MARK: - Tools

    private func callTool(name: String, arguments: [String: Any], id: Any?) {
        guard let tool = ToolCatalogue.tool(named: name) else {
            sendToolError(id: id, message: "unknown tool \"\(name)\"")
            return
        }

        do {
            switch tool.name {
            case "swiftshot_capture":
                try capture(arguments: arguments, id: id)
            case "swiftshot_displays":
                let payload = try client.send(command: "displays")
                sendToolResult(id: id, text: Self.describeDisplays(payload as? [[String: Any]] ?? []))
            case "swiftshot_status":
                let payload = try client.send(command: "status")
                sendToolResult(id: id, text: Self.describeStatus(payload as? [String: Any] ?? [:]))
            case "swiftshot_settings":
                try settings(arguments: arguments, id: id)
            case "swiftshot_open_settings":
                _ = try client.send(command: "open_settings")
                sendToolResult(id: id, text: "The SwiftShot settings window was opened.")
            default:
                sendToolError(id: id, message: "tool \"\(name)\" is not implemented")
            }
        } catch {
            sendToolError(id: id, message: error.localizedDescription)
        }
    }

    private func capture(arguments: [String: Any], id: Any?) throws {
        var commandArguments: [String: Any] = [:]
        if let region = arguments["region"] as? [String: Any] {
            var rect: [String: Double] = [:]
            for key in ["x", "y", "width", "height"] {
                if let value = region[key] as? Double { rect[key] = value }
                if let value = region[key] as? Int { rect[key] = Double(value) }
            }
            if rect.count == 4 {
                commandArguments["region"] = rect
            }
        }
        if let displayID = arguments["display_id"] as? Int {
            commandArguments["display_id"] = displayID
        }
        if let format = arguments["format"] as? String {
            commandArguments["format"] = format
        }
        if let quality = arguments["quality"] as? Double {
            commandArguments["quality"] = quality
        }

        let payload = (try client.send(command: "capture", arguments: commandArguments)) as? [String: Any] ?? [:]
        guard let path = payload["path"] as? String else {
            sendToolError(id: id, message: "SwiftShot did not return a file path")
            return
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            sendToolError(id: id, message: "The screenshot file could not be read: \(path)")
            return
        }

        let mimeType = (payload["format"] as? String) == "jpeg" ? "image/jpeg" : "image/png"
        let summary = """
        Captured \(payload["pixelWidth"] ?? 0)x\(payload["pixelHeight"] ?? 0) pixels \
        (\(payload["pointWidth"] ?? 0)x\(payload["pointHeight"] ?? 0) points, scale \(payload["scale"] ?? 1)).
        Saved at \(path)
        """

        sendResult(id: id, result: [
            "content": [
                ["type": "text", "text": summary],
                ["type": "image", "data": data.base64EncodedString(), "mimeType": mimeType],
            ],
            "isError": false,
        ])
    }

    private func settings(arguments: [String: Any], id: Any?) throws {
        var commandArguments: [String: Any] = [:]
        let mapping: [String: String] = [
            "auto_save": "autoSave",
            "copy_to_clipboard": "copyToClipboard",
            "ask_where_to_save": "askWhereToSave",
            "copy_on_double_click": "copyOnDoubleClick",
            "use_last_region": "useLastRegion",
            "show_magnifier": "showMagnifier",
        ]
        for (key, bridgeKey) in mapping {
            if let value = arguments[key] as? Bool { commandArguments[bridgeKey] = value }
        }
        if let value = arguments["jpeg_quality"] as? Double { commandArguments["jpegQuality"] = value }
        if let value = arguments["stroke_width"] as? Double { commandArguments["strokeWidth"] = value }
        if let value = arguments["save_format"] as? String { commandArguments["saveFormat"] = value }
        if let value = arguments["save_directory"] as? String { commandArguments["saveDirectory"] = value }

        let command = commandArguments.isEmpty ? "settings.get" : "settings.set"
        let payload = (try client.send(command: command, arguments: commandArguments)) as? [String: Any] ?? [:]
        sendToolResult(id: id, text: Self.describeSettings(payload))
    }

    // MARK: - Descriptions

    private static func describeDisplays(_ displays: [[String: Any]]) -> String {
        if displays.isEmpty { return "No displays found." }
        let lines = displays.map { display -> String in
            let frame = display["frame"] as? [String: Double] ?? [:]
            return """
            id=\(display["id"] ?? "?") name=\(display["name"] ?? "?") \
            frame=(\(Int(frame["x"] ?? 0)), \(Int(frame["y"] ?? 0)), \(Int(frame["width"] ?? 0)), \(Int(frame["height"] ?? 0))) \
            scale=\(display["scale"] ?? 1) main=\(display["isMain"] as? Bool ?? false)
            """
        }
        return "Displays:\n" + lines.joined(separator: "\n")
    }

    private static func describeStatus(_ payload: [String: Any]) -> String {
        let permission = payload["screenRecordingPermission"] as? Bool ?? false
        return """
        SwiftShot \(payload["version"] ?? "?") (\(payload["bundleId"] ?? "?"))
        Screen Recording permission: \(permission ? "granted" : "NOT granted")
        Bridge socket: \(payload["socket"] ?? "?")
        """
    }

    private static func describeSettings(_ payload: [String: Any]) -> String {
        guard !payload.isEmpty else { return "No settings available." }
        return payload
            .sorted { $0.key < $1.key }
            .map { key, value in "\(key) = \(describeValue(value))" }
            .joined(separator: "\n")
    }

    /// JSON has no separate boolean type — booleans arrive as `NSNumber` and would
    /// be printed as `0`/`1`, so they are formatted explicitly.
    private static func describeValue(_ value: Any) -> String {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() {
            return number.doubleValue == number.doubleValue.rounded()
                ? String(Int(number.doubleValue))
                : String(number.doubleValue)
        }
        return "\(value)"
    }

    // MARK: - JSON-RPC

    private func sendResult(id: Any?, result: [String: Any]) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result,
        ]
        if let id { response["id"] = id }
        write(response)
    }

    private func sendError(id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
        ]
        if let id { response["id"] = id }
        write(response)
    }

    private func sendToolResult(id: Any?, text: String) {
        sendResult(id: id, result: [
            "content": [["type": "text", "text": text]],
            "isError": false,
        ])
    }

    private func sendToolError(id: Any?, message: String) {
        sendResult(id: id, result: [
            "content": [["type": "text", "text": message]],
            "isError": true,
        ])
    }

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        output.write(data)
    }
}

/// Writes raw bytes to stdout (MCP uses newline delimited JSON on stdout).
final class OutputStreamWriter {
    private let handle: FileHandle

    init(handle: FileHandle = .standardOutput) {
        self.handle = handle
    }

    func write(_ data: Data) {
        var line = data
        line.append(0x0A)
        handle.write(line)
    }
}
