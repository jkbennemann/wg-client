import Foundation
import Shared

// wireguard-client-helper — privileged launchd daemon.
// Listens on a unix socket and manages WireGuard tunnels on behalf of the
// menu bar app. Requests are only accepted from root or the current console user.

setbuf(stdout, nil)
signal(SIGPIPE, SIG_IGN)

guard geteuid() == 0 else {
    FileHandle.standardError.write("wireguard-client-helper must run as root\n".data(using: .utf8)!)
    exit(1)
}

let engine = Engine()

do {
    try engine.ensureDirectories()
    try TunnelStore.ensureDirectories()
} catch {
    log("Failed to create directories: \(error.localizedDescription)")
    exit(1)
}

engine.reconcileOnStartup()

/// Returns the tail of the helper's log file (the daemon's own StandardOutPath).
/// Reading it here — as root — avoids any permission ambiguity on the client side.
func readLogTail(maxBytes: UInt64 = 256 * 1024) -> String {
    guard let handle = FileHandle(forReadingAtPath: IPC.logPath) else { return "" }
    defer { try? handle.close() }
    let end = (try? handle.seekToEnd()) ?? 0
    let start = end > maxBytes ? end - maxBytes : 0
    try? handle.seek(toOffset: start)
    let data = (try? handle.readToEnd()) ?? Data()
    return String(data: data, encoding: .utf8) ?? ""
}

func peerAllowed(_ fd: Int32) -> Bool {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0 else { return false }
    if uid == 0 { return true }
    var consoleStat = stat()
    if stat("/dev/console", &consoleStat) == 0, consoleStat.st_uid == uid { return true }
    return false
}

func dispatch(_ request: IPCRequest) -> IPCResponse {
    do {
        switch request.cmd {
        case "hello":
            return IPCResponse(ok: true, version: IPC.protocolVersion, build: IPC.build,
                               activeTunnel: engine.activeName,
                               activeNetworks: engine.activeNetworks)

        case "list":
            let active = engine.activeName
            let tunnels = TunnelStore.list().map { TunnelInfo(name: $0, isActive: $0 == active) }
            return IPCResponse(ok: true, activeTunnel: active,
                               activeNetworks: engine.activeNetworks, tunnels: tunnels)

        case "import":
            guard let name = request.name, let config = request.config else {
                throw HelperError("import requires name and config")
            }
            _ = try TunnelConfig.parse(config)
            try TunnelStore.write(name: name, config: config)
            log("Imported tunnel \(name)")
            return IPCResponse(ok: true)

        case "get":
            guard let name = request.name else { throw HelperError("get requires name") }
            return IPCResponse(ok: true, config: try TunnelStore.read(name: name))

        case "set":
            guard let name = request.name, let config = request.config else {
                throw HelperError("set requires name and config")
            }
            guard TunnelStore.exists(name: name) else { throw HelperError("Tunnel \(name) not found") }
            _ = try TunnelConfig.parse(config)
            try TunnelStore.write(name: name, config: config)
            log("Updated tunnel \(name)")
            return IPCResponse(ok: true)

        case "rename":
            guard let name = request.name, let newName = request.newName else {
                throw HelperError("rename requires name and newName")
            }
            try TunnelStore.rename(from: name, to: newName)
            engine.renameActive(from: name, to: newName)
            log("Renamed tunnel \(name) to \(newName)")
            return IPCResponse(ok: true)

        case "delete":
            guard let name = request.name else { throw HelperError("delete requires name") }
            if engine.activeName == name { try engine.down() }
            try TunnelStore.delete(name: name)
            log("Deleted tunnel \(name)")
            return IPCResponse(ok: true)

        case "up":
            guard let name = request.name else { throw HelperError("up requires name") }
            let config = try TunnelStore.read(name: name)
            try engine.up(name: name, configText: config)
            return IPCResponse(ok: true, activeTunnel: engine.activeName,
                               activeNetworks: engine.activeNetworks)

        case "down":
            try engine.down()
            return IPCResponse(ok: true)

        case "status":
            return IPCResponse(ok: true, activeTunnel: engine.activeName,
                               activeNetworks: engine.activeNetworks, status: engine.status())

        case "log":
            return IPCResponse(ok: true, log: readLogTail())

        default:
            throw HelperError("Unknown command: \(request.cmd)")
        }
    } catch {
        return IPCResponse(ok: false, error: error.localizedDescription)
    }
}

func handle(_ fd: Int32) {
    defer { close(fd) }
    UnixSocket.setTimeout(fd, 30)

    var response: IPCResponse
    if !peerAllowed(fd) {
        response = IPCResponse(ok: false, error: "Permission denied")
    } else {
        do {
            let data = try UnixSocket.recvUntil(fd, terminator: Data([0x0A]), maxBytes: 1024 * 1024)
            let request = try JSONDecoder().decode(IPCRequest.self, from: data)
            response = dispatch(request)
        } catch {
            response = IPCResponse(ok: false, error: "Bad request: \(error.localizedDescription)")
        }
    }

    if var payload = try? JSONEncoder().encode(response) {
        payload.append(0x0A)
        try? UnixSocket.sendAll(fd, payload)
    }
}

let serverFD: Int32
do {
    // World-connectable socket; access control happens per-request via getpeereid.
    serverFD = try UnixSocket.bindListen(path: IPC.socketPath, mode: 0o666)
} catch {
    log("Failed to listen on \(IPC.socketPath): \(error.localizedDescription)")
    exit(1)
}

log("wireguard-client-helper v\(IPC.protocolVersion) listening on \(IPC.socketPath)")

while true {
    let client = accept(serverFD, nil, nil)
    if client < 0 {
        if errno == EINTR { continue }
        log("accept failed: \(String(cString: strerror(errno)))")
        usleep(200_000)
        continue
    }
    handle(client)
}
