import Foundation
import Shared

enum HelperClientError: LocalizedError {
    case notInstalled
    case failure(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "The WireGuard helper is not installed or not running."
        case .failure(let message):
            return message
        }
    }
}

enum HelperClient {
    @discardableResult
    static func request(_ req: IPCRequest, timeout: TimeInterval = 20) throws -> IPCResponse {
        let fd: Int32
        do {
            fd = try UnixSocket.connect(path: IPC.socketPath, timeout: timeout)
        } catch {
            throw HelperClientError.notInstalled
        }
        defer { close(fd) }

        var payload = try JSONEncoder().encode(req)
        payload.append(0x0A)
        try UnixSocket.sendAll(fd, payload)

        let data = try UnixSocket.recvUntil(fd, terminator: Data([0x0A]))
        let response = try JSONDecoder().decode(IPCResponse.self, from: data)
        guard response.ok else {
            throw HelperClientError.failure(response.error ?? "Unknown helper error")
        }
        return response
    }

    static func hello() throws -> IPCResponse {
        try request(IPCRequest(cmd: "hello"), timeout: 5)
    }

    static func list() throws -> IPCResponse {
        try request(IPCRequest(cmd: "list"), timeout: 5)
    }

    static func up(_ name: String) throws {
        try request(IPCRequest(cmd: "up", name: name), timeout: 30)
    }

    static func down() throws {
        try request(IPCRequest(cmd: "down"), timeout: 30)
    }

    static func status() throws -> IPCResponse {
        try request(IPCRequest(cmd: "status"), timeout: 5)
    }

    static func importTunnel(name: String, config: String) throws {
        try request(IPCRequest(cmd: "import", name: name, config: config))
    }

    static func getConfig(_ name: String) throws -> String {
        guard let config = try request(IPCRequest(cmd: "get", name: name)).config else {
            throw HelperClientError.failure("Helper returned no config for \(name)")
        }
        return config
    }

    static func setConfig(_ name: String, config: String) throws {
        try request(IPCRequest(cmd: "set", name: name, config: config))
    }

    static func delete(_ name: String) throws {
        try request(IPCRequest(cmd: "delete", name: name), timeout: 30)
    }

    static func rename(_ name: String, to newName: String) throws {
        try request(IPCRequest(cmd: "rename", name: name, newName: newName))
    }

    static func fetchLog() throws -> String {
        try request(IPCRequest(cmd: "log"), timeout: 10).log ?? ""
    }

    static func setBlockOutsideTunnel(_ enabled: Bool) throws {
        try request(IPCRequest(cmd: "setBlockOutsideTunnel", enabled: enabled), timeout: 30)
    }
}
