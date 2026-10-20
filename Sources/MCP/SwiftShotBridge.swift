import AppKit
import Foundation
import Network

/// A small JSON-over-Unix-socket bridge that lets the `swiftshot-mcp` server drive
/// the running app.
///
/// The app already owns the Screen Recording permission, so an AI agent does not
/// need a second TCC grant: the bridge asks the app to take the screenshot and
/// returns the path of the resulting file.
///
/// Protocol: newline delimited JSON.
/// Request:  `{"id": 1, "command": "capture", "region": {"x":0,"y":0,"width":100,"height":100}}`
/// Response: `{"id": 1, "ok": true, "path": "/tmp/…png", "width": 100, "height": 100}`
final class SwiftShotBridge {
    static let shared = SwiftShotBridge()

    /// Path of the unix socket the MCP server connects to.
    static var socketPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("SwiftShot", isDirectory: true)
            .appendingPathComponent("bridge.sock")
            .path
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.luongcoder.swiftshot.bridge", qos: .utility)

    private init() {}

    // MARK: - Lifecycle

    func start() {
        let path = Self.socketPath
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        // A socket left behind by a previous run would block the bind.
        try? FileManager.default.removeItem(atPath: path)

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)

        do {
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.queue ?? .global())
                self?.receive(on: connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let error):
                    NSLog("[SwiftShot] bridge listener failed: \(error.localizedDescription)")
                    self?.listener = nil
                case .cancelled:
                    self?.listener = nil
                default:
                    break
                }
            }
            listener.start(queue: queue)
        } catch {
            NSLog("[SwiftShot] could not start the MCP bridge: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(atPath: Self.socketPath)
    }

    // MARK: - Connection handling

    private func receive(on connection: NWConnection) {
        var buffer = Data()

        func readNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data {
                    buffer.append(data)
                    // Process every complete line.
                    while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                        let line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                        buffer.removeSubrange(buffer.startIndex...newlineIndex)
                        self.handle(line: line, connection: connection)
                    }
                }
                if !isComplete && error == nil {
                    readNext()
                }
            }
        }
        readNext()
    }

    private func handle(line: Data, connection: NWConnection) {
        do {
            try handleCommand(line: line, connection: connection)
        } catch {
            // A failing command must never take the app down.
            NSLog("[SwiftShot] bridge command failed: \(error.localizedDescription)")
            send(["ok": false, "error": error.localizedDescription], connection: connection)
        }
    }

    private func handleCommand(line: Data, connection: NWConnection) throws {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let command = object["command"] as? String else {
            send(["ok": false, "error": "malformed request"], connection: connection)
            return
        }

        let requestID = object["id"]
        let arguments = object["arguments"] as? [String: Any] ?? [:]

        switch command {
        case "status":
            respond(requestID, ["ok": true, "payload": statusPayload()], connection: connection)

        case "displays":
            respond(requestID, ["ok": true, "payload": displaysPayload()], connection: connection)

        case "capture":
            handleCapture(arguments: arguments, requestID: requestID, connection: connection)

        case "settings.get":
            respond(requestID, ["ok": true, "payload": settingsPayload()], connection: connection)

        case "settings.set":
            handleSettingsSet(arguments: arguments, requestID: requestID, connection: connection)

        case "open_settings":
            DispatchQueue.main.async {
                AppState.shared?.openSettings()
            }
            respond(requestID, ["ok": true, "payload": ["opened": true]], connection: connection)

        default:
            respond(requestID, ["ok": false, "error": "unknown command \"\(command)\""], connection: connection)
        }
    }

    // MARK: - Commands

    private func statusPayload() -> [String: Any] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return [
            "version": version,
            "bundleId": Bundle.main.bundleIdentifier ?? "dev.luongcoder.SwiftShot",
            "screenRecordingPermission": CGPreflightScreenCaptureAccess(),
            "socket": Self.socketPath,
        ]
    }

    private func displaysPayload() -> [[String: Any]] {
        NSScreen.screens.enumerated().map { index, screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return [
                "id": number?.intValue ?? index,
                "name": screen.localizedName,
                "frame": Self.rectPayload(screen.frame),
                "scale": screen.backingScaleFactor,
                "isMain": screen == NSScreen.main,
            ]
        }
    }

    private func settingsPayload() -> [String: Any] {
        // `DispatchQueue.main.sync` would deadlock when we are already on the main
        // thread (the settings update command runs there).
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                guard let settings = AppState.shared?.settings else { return [:] }
                return Self.makeSettingsPayload(settings)
            }
        }
        var result: [String: Any] = [:]
        DispatchQueue.main.sync {
            guard let settings = AppState.shared?.settings else { return }
            result = Self.makeSettingsPayload(settings)
        }
        return result
    }

    private static func makeSettingsPayload(_ settings: Settings) -> [String: Any] {
        return [
            "hotkey": settings.hotkey.displayString,
            "autoSave": settings.autoSave,
            "copyToClipboard": settings.copyToClipboard,
            "saveDirectory": settings.saveDirectory.path,
            "saveFormat": settings.saveFormat.rawValue,
            "jpegQuality": settings.jpegQuality,
            "defaultColor": settings.defaultColor.hexString,
            "strokeWidth": settings.strokeWidth,
            "askWhereToSave": settings.askWhereToSave,
            "copyOnDoubleClick": settings.copyOnDoubleClick,
            "useLastRegion": settings.useLastRegion,
            "showMagnifier": settings.showMagnifier,
        ]
    }

    private func handleSettingsSet(arguments: [String: Any], requestID: Any?, connection: NWConnection) {
        DispatchQueue.main.async {
            guard let settings = AppState.shared?.settings else {
                self.respond(requestID, ["ok": false, "error": "app is not ready"], connection: connection)
                return
            }
            if let value = arguments["autoSave"] as? Bool { settings.autoSave = value }
            if let value = arguments["copyToClipboard"] as? Bool { settings.copyToClipboard = value }
            if let value = arguments["askWhereToSave"] as? Bool { settings.askWhereToSave = value }
            if let value = arguments["copyOnDoubleClick"] as? Bool { settings.copyOnDoubleClick = value }
            if let value = arguments["useLastRegion"] as? Bool { settings.useLastRegion = value }
            if let value = arguments["showMagnifier"] as? Bool { settings.showMagnifier = value }
            if let value = arguments["jpegQuality"] as? Double { settings.jpegQuality = min(max(value, 0.4), 1.0) }
            if let value = arguments["strokeWidth"] as? Double { settings.strokeWidth = CGFloat(value) }
            if let value = arguments["saveFormat"] as? String, let format = SaveFormat(rawValue: value) {
                settings.saveFormat = format
            }
            if let value = arguments["saveDirectory"] as? String {
                settings.saveDirectory = URL(fileURLWithPath: value)
            }
            self.respond(requestID, ["ok": true, "payload": self.settingsPayload()], connection: connection)
        }
    }

    private func handleCapture(arguments: [String: Any], requestID: Any?, connection: NWConnection) {
        // The capture has to run on the main thread (ScreenCaptureKit + AppKit).
        DispatchQueue.main.async {
            guard let state = AppState.shared else {
                self.respond(requestID, ["ok": false, "error": "app is not ready"], connection: connection)
                return
            }

            var region: CGRect?
            if let rect = arguments["region"] as? [String: Any],
               let x = rect["x"] as? Double, let y = rect["y"] as? Double,
               let width = rect["width"] as? Double, let height = rect["height"] as? Double {
                region = CGRect(x: x, y: y, width: width, height: height)
            }

            let displayID = arguments["display_id"] as? Int
            let format = (arguments["format"] as? String).flatMap(SaveFormat.init(rawValue:)) ?? .png
            let quality = (arguments["quality"] as? Double) ?? 0.9

            Task { @MainActor in
                do {
                    let result = try await state.screenshotService.capture(region: region, displayID: displayID)
                    let image = NSImage(cgImage: result.image, size: result.sizeInPoints)

                    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("SwiftShot", isDirectory: true)
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent("capture-\(UUID().uuidString).\(format.fileExtension)")
                    guard FileStore.write(image, to: url, format: format, quality: quality) else {
                        self.respond(requestID, ["ok": false, "error": "could not encode the image"], connection: connection)
                        return
                    }

                    self.respond(requestID, [
                        "ok": true,
                        "payload": [
                            "path": url.path,
                            "pixelWidth": result.image.width,
                            "pixelHeight": result.image.height,
                            "pointWidth": Int(result.sizeInPoints.width.rounded()),
                            "pointHeight": Int(result.sizeInPoints.height.rounded()),
                            "scale": result.scale,
                            "format": format.rawValue,
                        ],
                    ], connection: connection)
                } catch {
                    self.respond(requestID, ["ok": false, "error": error.localizedDescription], connection: connection)
                }
            }
        }
    }

    // MARK: - Helpers

    private func respond(_ id: Any?, _ payload: [String: Any], connection: NWConnection) {
        var body = payload
        if let id { body["id"] = id }
        send(body, connection: connection)
    }

    private func send(_ payload: [String: Any], connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var line = data
        line.append(0x0A)
        connection.send(content: line, completion: .contentProcessed { _ in })
    }

    private static func rectPayload(_ rect: CGRect) -> [String: Double] {
        ["x": rect.origin.x, "y": rect.origin.y, "width": rect.size.width, "height": rect.size.height]
    }
}

// MARK: - Helpers

extension NSColor {
    /// `#RRGGBB` representation, used by the bridge payloads.
    ///
    /// Dynamic colours (like `NSColor.systemRed`) have to be resolved into a
    /// concrete colour space first — asking them for their components directly
    /// raises an exception.
    var hexString: String {
        guard let color = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
