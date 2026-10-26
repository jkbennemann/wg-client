import Foundation
import Shared

/// ifconfig / route plumbing — the parts wg-quick(8) would normally do on darwin.
/// DNS is handled separately by `DNSManager` (via the SystemConfiguration store).
enum NetworkSetup {
    struct HostRoute: Codable, Equatable {
        var family: String  // "inet" | "inet6"
        var dest: String
        /// Physical gateway the endpoint is pinned to; empty while there is none
        /// (offline), in which case nothing is installed until the network returns.
        var gateway: String

        fileprivate func args(_ verb: String) -> [String] {
            ["-q", "-n", verb, "-\(family)", dest, gateway]
        }
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

        let gateways = GatewayLookup()
        var hostRoutes: [HostRoute] = []
        for index in config.peers.indices {
            guard let resolved = resolvedEndpoints[index] else { continue }
            let ip = stripPort(resolved)
            let family = ip.contains(":") ? "inet6" : "inet"
            guard family == "inet6" ? hasDefault6 : hasDefault4 else { continue }
            // Without a gateway (connecting while offline) the pin is still recorded, so
            // the network monitor installs it once a network shows up.
            let gateway = gateways.gateway(family: family) ?? ""
            guard gateway != ip else { continue }
            hostRoutes.append(HostRoute(family: family, dest: ip, gateway: gateway))
        }
        return hostRoutes
    }

    static func installHostRoutes(_ routes: [HostRoute]) {
        Shell.runParallelForEach(routes.filter { !$0.gateway.isEmpty }) { _ = install($0) }
    }

    /// Deletes by destination only: the kernel matches host routes on the destination,
    /// and the gateway recorded at pin time may no longer be the one installed.
    static func removeHostRoutes(_ routes: [HostRoute]) {
        let commands = routes.map { ["-q", "-n", "delete", "-\($0.family)", $0.dest] }
        Shell.runParallel("/sbin/route", commands)
    }

    /// Re-points the endpoint pins at the *current* physical network and returns them
    /// as now installed. A pin is a static route bound to the gateway and source address
    /// that existed when it was added: after a Wi-Fi roam or a wake on another network,
    /// sends to the endpoint fail with EADDRNOTAVAIL ("can't assign requested address")
    /// and the whole tunnel is dead until it is re-pinned. That holds even when the new
    /// network uses the same gateway IP, so every call re-points every pin.
    static func refreshHostRoutes(_ routes: [HostRoute]) -> [HostRoute] {
        let gateways = GatewayLookup()
        return routes.map { pin in
            // Offline or mid-roam: keep whatever is installed. A stale pin can't carry
            // traffic, but it keeps the endpoint out of the tunnel's own routes until a
            // gateway appears and it can be re-pointed in place.
            guard let gateway = gateways.gateway(family: pin.family), gateway != pin.dest else { return pin }
            let updated = HostRoute(family: pin.family, dest: pin.dest, gateway: gateway)
            return install(updated) ? updated : pin
        }
    }

    /// Installs or re-points one pin in place; returns whether the kernel accepted it.
    private static func install(_ pin: HostRoute) -> Bool {
        switch exactHostRouteFlags(family: pin.family, dest: pin.dest) {
        case let flags? where flags.contains("STATIC") && !flags.contains("WASCLONED"):
            // Only ever `route change` a pin that is really there: for a host route that
            // doesn't exist, the kernel re-points whichever route best matches the
            // destination instead — the tunnel's own /1 route.
            return route(pin.args("change"))
        case .some:
            // A host route the kernel cloned from another route as a cache entry.
            route(["-q", "-n", "delete", "-\(pin.family)", pin.dest])
            return route(pin.args("add"))
        case nil:
            return route(pin.args("add"))
        }
    }

    /// The flags of the host route for exactly `dest`, or nil if lookups for it only
    /// match a covering network route.
    private static func exactHostRouteFlags(family: String, dest: String) -> String? {
        guard let result = try? Shell.run("/sbin/route", ["-n", "get", "-\(family)", dest]),
              result.status == 0 else { return nil }
        var destination: String?
        var flags = ""
        for line in result.stdout.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("destination:") {
                destination = trimmed.dropFirst("destination:".count).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("flags:") {
                flags = trimmed
            }
        }
        guard destination == dest, flags.contains("HOST") else { return nil }
        return flags
    }

    @discardableResult
    private static func route(_ args: [String]) -> Bool {
        (try? Shell.run("/sbin/route", args))?.status == 0
    }

    /// Looks up each family's default gateway at most once per pin computation.
    private final class GatewayLookup {
        private var cache: [String: String?] = [:]

        func gateway(family: String) -> String? {
            if let cached = cache[family] { return cached }
            let gateway = NetworkSetup.defaultGateway(v6: family == "inet6")
            cache.updateValue(gateway, forKey: family)
            return gateway
        }
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
