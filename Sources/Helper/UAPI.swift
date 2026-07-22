import Foundation
import Shared

/// Talks to wireguard-go over its userspace API socket (/var/run/wireguard/<utun>.sock).
/// Protocol: https://www.wireguard.com/xplatform/
enum UAPI {
    static func socketPath(iface: String) -> String {
        "/var/run/wireguard/\(iface).sock"
    }

    /// `resolvedEndpoints` is aligned with `config.peers`; each entry is a numeric
    /// "ip:port" already resolved by the caller (nil for peers without an endpoint).
    static func applyConfig(iface: String, config: TunnelConfig, resolvedEndpoints: [String?]) throws {
        var body = "set=1\n"
        body += "private_key=\(try keyToHex(config.interface.privateKey))\n"
        if let port = config.interface.listenPort {
            body += "listen_port=\(port)\n"
        }
        body += "replace_peers=true\n"
        for (index, peer) in config.peers.enumerated() {
            body += "public_key=\(try keyToHex(peer.publicKey))\n"
            if let psk = peer.presharedKey {
                body += "preshared_key=\(try keyToHex(psk))\n"
            }
            if let endpoint = resolvedEndpoints[index] {
                body += "endpoint=\(endpoint)\n"
            }
            if let keepalive = peer.persistentKeepalive {
                body += "persistent_keepalive_interval=\(keepalive)\n"
            }
            body += "replace_allowed_ips=true\n"
            for cidr in peer.allowedIPs {
                body += "allowed_ip=\(normalizeCIDR(cidr))\n"
            }
        }
        body += "\n"
        let response = try request(iface: iface, body: body)
        try checkErrno(response)
    }

    static func status(iface: String, tunnelName: String) throws -> TunnelStatus {
        let response = try request(iface: iface, body: "get=1\n\n")
        try checkErrno(response)

        var status = TunnelStatus(name: tunnelName, interfaceName: iface)
        var currentPeer: PeerStatus?

        func commit() {
            if let p = currentPeer { status.peers.append(p) }
            currentPeer = nil
        }

        for line in response.components(separatedBy: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...])
            switch key {
            case "listen_port":
                status.listenPort = Int(value)
            case "public_key":
                commit()
                currentPeer = PeerStatus(publicKey: hexToBase64(value) ?? value)
            case "endpoint":
                currentPeer?.endpoint = value
            case "allowed_ip":
                currentPeer?.allowedIPs.append(value)
            case "last_handshake_time_sec":
                if let sec = Double(value), sec > 0 {
                    currentPeer?.lastHandshake = sec
                }
            case "rx_bytes":
                currentPeer?.rxBytes = UInt64(value) ?? 0
            case "tx_bytes":
                currentPeer?.txBytes = UInt64(value) ?? 0
            default:
                break
            }
        }
        commit()
        return status
    }

    private static func request(iface: String, body: String) throws -> String {
        let fd = try UnixSocket.connect(path: socketPath(iface: iface), timeout: 10)
        defer { close(fd) }
        try UnixSocket.sendAll(fd, body.data(using: .utf8)!)
        let data = try UnixSocket.recvUntil(fd, terminator: "\n\n".data(using: .utf8)!)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func checkErrno(_ response: String) throws {
        for line in response.components(separatedBy: "\n") where line.hasPrefix("errno=") {
            let value = String(line.dropFirst("errno=".count))
            if value != "0" {
                throw HelperError("wireguard-go rejected configuration (errno=\(value))")
            }
            return
        }
        throw HelperError("No response from wireguard-go UAPI socket")
    }

    private static func keyToHex(_ base64: String) throws -> String {
        guard let data = Data(base64Encoded: base64), data.count == 32 else {
            throw HelperError("Invalid key in configuration")
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func hexToBase64(_ hex: String) -> String? {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data.base64EncodedString()
    }

    static func normalizeCIDR(_ cidr: String) -> String {
        if cidr.contains("/") { return cidr }
        return cidr.contains(":") ? cidr + "/128" : cidr + "/32"
    }
}

enum Endpoint {
    /// Resolves "host:port" (or "[v6]:port") to a numeric "ip:port" / "[ip]:port" for the UAPI.
    static func resolve(_ endpoint: String) throws -> String {
        let (host, port) = try split(endpoint)

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, port, &hints, &result)
        guard rc == 0, let first = result else {
            throw HelperError("Cannot resolve endpoint \(endpoint): \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(result) }

        // Prefer IPv4 when both exist.
        var chosen = first
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let c = cursor {
            if c.pointee.ai_family == AF_INET { chosen = c; break }
            cursor = c.pointee.ai_next
        }

        var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var servBuf = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let ni = getnameinfo(chosen.pointee.ai_addr, chosen.pointee.ai_addrlen,
                             &hostBuf, socklen_t(hostBuf.count),
                             &servBuf, socklen_t(servBuf.count),
                             NI_NUMERICHOST | NI_NUMERICSERV)
        guard ni == 0 else {
            throw HelperError("Cannot format resolved endpoint for \(endpoint)")
        }
        let ip = String(cString: hostBuf)
        let resolvedPort = String(cString: servBuf)
        return ip.contains(":") ? "[\(ip)]:\(resolvedPort)" : "\(ip):\(resolvedPort)"
    }

    static func split(_ endpoint: String) throws -> (host: String, port: String) {
        if endpoint.hasPrefix("[") {
            guard let close = endpoint.firstIndex(of: "]") else {
                throw HelperError("Invalid endpoint: \(endpoint)")
            }
            let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
            let rest = endpoint[endpoint.index(after: close)...]
            guard rest.hasPrefix(":"), rest.count > 1 else {
                throw HelperError("Invalid endpoint (missing port): \(endpoint)")
            }
            return (host, String(rest.dropFirst()))
        }
        guard let colon = endpoint.lastIndex(of: ":") else {
            throw HelperError("Invalid endpoint (missing port): \(endpoint)")
        }
        return (String(endpoint[..<colon]), String(endpoint[endpoint.index(after: colon)...]))
    }
}
