import Foundation

/// Minimal JSON-RPC 2.0 / MCP client used by the SwiftShot MCP server.
///
/// The server talks to the running SwiftShot app over a unix socket, so the
/// agent reuses the app's Screen Recording permission instead of asking for a
/// second one.
final class BridgeClient {
    enum BridgeError: LocalizedError {
        case appNotRunning
        case badResponse(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .appNotRunning:
                return "SwiftShot is not running. Launch it with `open -a SwiftShot` and try again."
            case .badResponse(let message):
                return "SwiftShot returned an error: \(message)"
            case .timeout:
                return "Timed out waiting for SwiftShot."
            }
        }
    }

    private let socketPath: String
    private let timeout: TimeInterval

    init(socketPath: String? = nil, timeout: TimeInterval = 20) {
        self.socketPath = socketPath ?? Self.defaultSocketPath
        self.timeout = timeout
    }

    static var defaultSocketPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("SwiftShot", isDirectory: true)
            .appendingPathComponent("bridge.sock")
            .path
    }

    /// Whether the app is reachable.
    func isAppRunning() -> Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    /// Sends a command and waits for the matching response.
    func send(command: String, arguments: [String: Any] = [:]) throws -> Any {
        guard isAppRunning() else { throw BridgeError.appNotRunning }

        let request: [String: Any] = [
            "id": UUID().uuidString,
            "command": command,
            "arguments": arguments,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        var line = data
        line.append(0x0A)

        let socket = try connect()
        defer { socket.close() }

        try socket.write(contentsOf: line)

        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        while Date() < deadline {
            let chunk = try socket.read(availableBytes: 65_536)
            if chunk.isEmpty {
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            buffer.append(chunk)
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let responseData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                    throw BridgeError.badResponse("malformed response")
                }
                if response["ok"] as? Bool == true {
                    return response["payload"] ?? [:]
                }
                throw BridgeError.badResponse(response["error"] as? String ?? "unknown error")
            }
        }
        throw BridgeError.timeout
    }

    // MARK: - Socket plumbing

    private func connect() throws -> Socket {
        let socket = Socket()
        try socket.connect(to: socketPath)
        return socket
    }
}

/// A blocking unix domain socket.
final class Socket {
    private var descriptor: Int32 = -1

    func connect(to path: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BridgeClient.BridgeError.appNotRunning }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            Darwin.close(descriptor)
            descriptor = -1
            throw BridgeClient.BridgeError.appNotRunning
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            descriptor = -1
            throw BridgeClient.BridgeError.appNotRunning
        }
    }

    func write(contentsOf data: Data) throws {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(descriptor, base + offset, buffer.count - offset)
            }
            if written <= 0 { throw BridgeClient.BridgeError.timeout }
            offset += written
        }
    }

    func read(availableBytes: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: availableBytes)
        let count = Darwin.read(descriptor, &buffer, availableBytes)
        guard count > 0 else { return Data() }
        return Data(buffer.prefix(count))
    }

    func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    deinit { close() }
}
