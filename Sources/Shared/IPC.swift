import Foundation

public enum IPC {
    public static let socketPath = "/var/run/wg-client.sock"
    public static let logPath = "/var/log/wg-client-helper.log"
    public static let protocolVersion = 1
    /// Bumped whenever the helper binary's behavior changes without a wire-protocol
    /// break. The app compares the running helper's reported build against its own
    /// and offers to reinstall on a mismatch, so rebuilds actually take effect.
    public static let build = "0.0.3"
}

public struct IPCRequest: Codable {
    public var cmd: String
    public var name: String?
    public var newName: String?
    public var config: String?
    /// Value for on/off settings (`setBlockOutsideTunnel`).
    public var enabled: Bool?

    public init(cmd: String, name: String? = nil, newName: String? = nil, config: String? = nil,
                enabled: Bool? = nil) {
        self.cmd = cmd
        self.name = name
        self.newName = newName
        self.config = config
        self.enabled = enabled
    }
}

public struct TunnelInfo: Codable, Hashable {
    public var name: String
    public var isActive: Bool

    public init(name: String, isActive: Bool) {
        self.name = name
        self.isActive = isActive
    }
}

public struct PeerStatus: Codable {
    public var publicKey: String
    public var endpoint: String?
    public var allowedIPs: [String]
    public var lastHandshake: Double?
    public var rxBytes: UInt64
    public var txBytes: UInt64

    public init(publicKey: String, endpoint: String? = nil, allowedIPs: [String] = [],
                lastHandshake: Double? = nil, rxBytes: UInt64 = 0, txBytes: UInt64 = 0) {
        self.publicKey = publicKey
        self.endpoint = endpoint
        self.allowedIPs = allowedIPs
        self.lastHandshake = lastHandshake
        self.rxBytes = rxBytes
        self.txBytes = txBytes
    }
}

public struct TunnelStatus: Codable {
    public var name: String
    public var interfaceName: String?
    public var listenPort: Int?
    public var peers: [PeerStatus]

    public init(name: String, interfaceName: String? = nil, listenPort: Int? = nil, peers: [PeerStatus] = []) {
        self.name = name
        self.interfaceName = interfaceName
        self.listenPort = listenPort
        self.peers = peers
    }
}

public struct IPCResponse: Codable {
    public var ok: Bool
    public var error: String?
    public var version: Int?
    public var build: String?
    public var activeTunnel: String?
    public var activeNetworks: [String]?
    public var tunnels: [TunnelInfo]?
    public var status: TunnelStatus?
    public var config: String?
    public var log: String?
    /// Whether traffic that would bypass an active full tunnel is blocked (helper setting).
    public var blockOutsideTunnel: Bool?

    public init(ok: Bool, error: String? = nil, version: Int? = nil, build: String? = nil,
                activeTunnel: String? = nil, activeNetworks: [String]? = nil,
                tunnels: [TunnelInfo]? = nil, status: TunnelStatus? = nil, config: String? = nil,
                log: String? = nil, blockOutsideTunnel: Bool? = nil) {
        self.ok = ok
        self.error = error
        self.version = version
        self.build = build
        self.activeTunnel = activeTunnel
        self.activeNetworks = activeNetworks
        self.tunnels = tunnels
        self.status = status
        self.config = config
        self.log = log
        self.blockOutsideTunnel = blockOutsideTunnel
    }
}
