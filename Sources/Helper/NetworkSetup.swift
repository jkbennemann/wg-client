import Foundation
import Shared

/// ifconfig / route plumbing — the parts wg-quick(8) would normally do on darwin.
/// DNS is handled separately by `DNSManager` (via the SystemConfiguration store).
enum NetworkSetup {
    struct HostRoute: Codable {
        var family: String  // "inet" | "inet6"
        var dest: String
        var gateway: String
    }

    // MARK: - Interface

    static func configureInterface(iface: String, config: TunnelConfig) throws {
        for address in config.interface.addresses {
            if address.contains(":") {
                try Shell.runChecked("/sbin/ifconfig", [iface, "inet6", address, "alias"])
            } else {
                let base = String(address.split(separator: "/").first ?? "")
                try Shell.runChecked("/sbin/ifconfig", [iface, "inet", address, base, "alias"])
            }
        }
        let mtu = config.interface.mtu ?? 1420
        try Shell.runChecked("/sbin/ifconfig", [iface, "mtu", String(mtu), "up"])
    }

    // MARK: - Routes

    /// Host routes pinning each peer endpoint to the physical default gateway, so the
    /// tunnel's own encrypted packets don't loop back into the tunnel. Only needed for
    /// full-tunnel configs (0.0.0.0/0 or ::/0). Pure computation — does not install.
    static func endpointHostRoutes(config: TunnelConfig, resolvedEndpoints: [String?]) -> [HostRoute] {
        let networks = config.peers.flatMap { $0.allowedIPs }.map(UAPI.normalizeCIDR)
        let hasDefault4 = networks.contains("0.0.0.0/0")
        let hasDefault6 = networks.contains("::/0")
        guard hasDefault4 || hasDefault6 else { return [] }

        var hostRoutes: [HostRoute] = []
        for index in config.peers.indices {
            guard let resolved = resolvedEndpoints[index] else { continue }
            let ip = stripPort(resolved)
            let isV6 = ip.contains(":")
            guard isV6 ? hasDefault6 : hasDefault4 else { continue }
            guard let gateway = defaultGateway(v6: isV6), gateway != ip else { continue }
            hostRoutes.append(HostRoute(family: isV6 ? "inet6" : "inet", dest: ip, gateway: gateway))
        }
        return hostRoutes
    }

    static func installHostRoutes(_ routes: [HostRoute]) {
        let commands = routes.map { ["-q", "-n", "add", "-\($0.family)", $0.dest, $0.gateway] }
        Shell.runParallel("/sbin/route", commands)
    }

    static func removeHostRoutes(_ routes: [HostRoute]) {
        let commands = routes.map { ["-q", "-n", "delete", "-\($0.family)", $0.dest, $0.gateway] }
        Shell.runParallel("/sbin/route", commands)
    }

    /// The interface-scoped routes for all AllowedIPs (the /1 split for full-tunnel
    /// configs, plus any specific prefixes). Returned as `route add` argument lists.
    static func networkRouteArgs(iface: String, config: TunnelConfig) -> [[String]] {
        let networks = config.peers.flatMap { $0.allowedIPs }.map(UAPI.normalizeCIDR)
        var commands: [[String]] = []
        for network in networks {
            switch network {
            case "0.0.0.0/0":
                commands.append(interfaceRouteArgs(iface: iface, family: "inet", cidr: "0.0.0.0/1"))
                commands.append(interfaceRouteArgs(iface: iface, family: "inet", cidr: "128.0.0.0/1"))
            case "::/0":
                commands.append(interfaceRouteArgs(iface: iface, family: "inet6", cidr: "::/1"))
                commands.append(interfaceRouteArgs(iface: iface, family: "inet6", cidr: "8000::/1"))
            default:
                let family = network.contains(":") ? "inet6" : "inet"
                commands.append(interfaceRouteArgs(iface: iface, family: family, cidr: network))
            }
        }
        return commands
    }

    /// Installs interface routes concurrently. When `replaceExisting` is true (a
    /// make-before-break cutover), each prefix is re-pointed with `route change` and
    /// falls back to `route add` if it didn't exist yet — this atomically moves a
    /// prefix from the old tunnel's interface to the new one without a delete/add gap.
    static func installNetworkRoutes(_ argsList: [[String]], replaceExisting: Bool) {
        if !replaceExisting {
            Shell.runParallel("/sbin/route", argsList)
            return
        }
        Shell.runParallelForEach(argsList) { addArgs in
            var changeArgs = addArgs
            if let verbIndex = changeArgs.firstIndex(of: "add") { changeArgs[verbIndex] = "change" }
            let result = try? Shell.run("/sbin/route", changeArgs)
            if result?.status != 0 {
                _ = try? Shell.run("/sbin/route", addArgs)
            }
        }
    }

    private static func interfaceRouteArgs(iface: String, family: String, cidr: String) -> [String] {
        ["-q", "-n", "add", "-\(family)", cidr, "-interface", iface]
    }

    private static func stripPort(_ resolvedEndpoint: String) -> String {
        if resolvedEndpoint.hasPrefix("[") {
            if let close = resolvedEndpoint.firstIndex(of: "]") {
                return String(resolvedEndpoint[resolvedEndpoint.index(after: resolvedEndpoint.startIndex)..<close])
            }
        }
        if let colon = resolvedEndpoint.lastIndex(of: ":") {
            return String(resolvedEndpoint[..<colon])
        }
        return resolvedEndpoint
    }

    private static func defaultGateway(v6: Bool) -> String? {
        let args = v6 ? ["-n", "get", "-inet6", "default"] : ["-n", "get", "default"]
        guard let result = try? Shell.run("/sbin/route", args), result.status == 0 else { return nil }
        for line in result.stdout.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                let gw = trimmed.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
                return gw.isEmpty ? nil : gw
            }
        }
        return nil
    }
}
