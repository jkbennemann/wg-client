import Foundation
import Shared

/// Stores tunnel configs (which contain private keys) in a root-only directory.
enum TunnelStore {
    static let configDir = "/Library/Application Support/WGClient/tunnels"

    static func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configDir)
    }

    static func list() -> [String] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: configDir)) ?? []
        return entries
            .filter { $0.hasSuffix(".conf") }
            .map { String($0.dropLast(5)) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func path(for name: String) throws -> String {
        guard TunnelConfig.isValidName(name) else {
            throw HelperError("Invalid tunnel name: \(name)")
        }
        return configDir + "/" + name + ".conf"
    }

    static func read(name: String) throws -> String {
        let p = try path(for: name)
        guard let text = try? String(contentsOfFile: p, encoding: .utf8) else {
            throw HelperError("Tunnel \(name) not found")
        }
        return text
    }

    static func write(name: String, config: String) throws {
        let p = try path(for: name)
        try config.write(toFile: p, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p)
    }

    static func exists(name: String) -> Bool {
        guard let p = try? path(for: name) else { return false }
        return FileManager.default.fileExists(atPath: p)
    }

    static func delete(name: String) throws {
        let p = try path(for: name)
        guard FileManager.default.fileExists(atPath: p) else {
            throw HelperError("Tunnel \(name) not found")
        }
        try FileManager.default.removeItem(atPath: p)
    }

    static func rename(from old: String, to new: String) throws {
        guard TunnelConfig.isValidName(new) else {
            throw HelperError("Invalid tunnel name: \(new)")
        }
        let src = try path(for: old)
        let dst = try path(for: new)
        guard FileManager.default.fileExists(atPath: src) else {
            throw HelperError("Tunnel \(old) not found")
        }
        if old == new { return }
        guard !FileManager.default.fileExists(atPath: dst) else {
            throw HelperError("A tunnel named “\(new)” already exists")
        }
        try FileManager.default.moveItem(atPath: src, toPath: dst)
    }
}
