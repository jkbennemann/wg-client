import Foundation
import CryptoKit

public struct ConfigError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct InterfaceConfig {
    public var privateKey: String = ""
    public var addresses: [String] = []
    public var dns: [String] = []
    public var mtu: Int?
    public var listenPort: Int?

    public var publicKey: String? {
        TunnelConfig.derivePublicKey(fromPrivate: privateKey)
    }
}

public struct PeerConfig {
    public var publicKey: String = ""
    public var presharedKey: String?
    public var allowedIPs: [String] = []
    public var endpoint: String?
    public var persistentKeepalive: Int?
}

public struct TunnelConfig {
    public var interface: InterfaceConfig
    public var peers: [PeerConfig]
    public var warnings: [String]

    public static func parse(_ text: String) throws -> TunnelConfig {
        enum Section { case none, interface, peer }
        var section = Section.none
        var iface = InterfaceConfig()
        var peers: [PeerConfig] = []
        var currentPeer: PeerConfig?
        var warnings: [String] = []
        var sawInterface = false

        func commitPeer() {
            if let p = currentPeer { peers.append(p) }
            currentPeer = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                switch line.lowercased() {
                case "[interface]":
                    commitPeer()
                    section = .interface
                    sawInterface = true
                case "[peer]":
                    commitPeer()
                    currentPeer = PeerConfig()
                    section = .peer
                default:
                    throw ConfigError("Unknown section \(line)")
                }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else {
                throw ConfigError("Invalid line: \(line)")
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let values = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

            switch section {
            case .interface:
                switch key {
                case "privatekey": iface.privateKey = value
                case "address": iface.addresses.append(contentsOf: values)
                case "dns": iface.dns.append(contentsOf: values)
                case "mtu": iface.mtu = Int(value)
                case "listenport": iface.listenPort = Int(value)
                case "saveconfig", "fwmark", "table":
                    warnings.append("Ignored unsupported [Interface] option \(key)")
                case "preup", "postup", "predown", "postdown":
                    warnings.append("Ignored \(key) script (not supported for security reasons)")
                default:
                    throw ConfigError("Unknown [Interface] option: \(key)")
                }
            case .peer:
                switch key {
                case "publickey": currentPeer?.publicKey = value
                case "presharedkey": currentPeer?.presharedKey = value
                case "allowedips": currentPeer?.allowedIPs.append(contentsOf: values)
                case "endpoint": currentPeer?.endpoint = value
                case "persistentkeepalive": currentPeer?.persistentKeepalive = Int(value)
                default:
                    throw ConfigError("Unknown [Peer] option: \(key)")
                }
            case .none:
                throw ConfigError("Option \(key) outside of a section")
            }
        }
        commitPeer()

        guard sawInterface else { throw ConfigError("Missing [Interface] section") }
        guard isValidKey(iface.privateKey) else { throw ConfigError("Missing or invalid PrivateKey") }
        for peer in peers {
            guard isValidKey(peer.publicKey) else { throw ConfigError("Peer with missing or invalid PublicKey") }
            if let psk = peer.presharedKey, !isValidKey(psk) {
                throw ConfigError("Peer with invalid PresharedKey")
            }
        }
        if peers.isEmpty { warnings.append("Config has no [Peer] sections") }

        return TunnelConfig(interface: iface, peers: peers, warnings: warnings)
    }

    /// A valid WireGuard key: base64 encoding of exactly 32 bytes.
    public static func isValidKey(_ key: String) -> Bool {
        guard let data = Data(base64Encoded: key) else { return false }
        return data.count == 32
    }

    public static func derivePublicKey(fromPrivate base64: String) -> String? {
        guard let data = Data(base64Encoded: base64), data.count == 32,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else { return nil }
        return key.publicKey.rawRepresentation.base64EncodedString()
    }

    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 60, !name.hasPrefix(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_=+.-— "))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public static func sanitizeName(_ name: String) -> String {
        var base = name
        if base.lowercased().hasSuffix(".conf") { base = String(base.dropLast(5)) }
        let filtered = base.unicodeScalars.filter {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_=+.- ")).contains($0)
        }
        var result = String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespaces)
        while result.hasPrefix(".") { result.removeFirst() }
        if result.count > 60 { result = String(result.prefix(60)) }
        return result
    }
}
