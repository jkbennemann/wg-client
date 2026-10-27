import Foundation
import Shared

/// ifconfig / route plumbing — the parts wg-quick(8) would normally do on darwin.
/// DNS is handled separately by `DNSManager` (via the SystemConfiguration store).
enum NetworkSetup {
    struct HostRoute: Codable, Equatable {
        var family: String  // "inet" | "inet6"
        var dest: String
        /// Physical gateway the endpoint is pinned to, or loopback while there is none.
        var gateway: String

        /// Stand-in gateway while offline: packets to the endpoint are dropped on lo0
        /// instead of matching the tunnel's own /1 routes and looping through it. A plain
        /// gateway route (not -blackhole), so `route change` re-points it in place later.
        static func offlineGateway(family: String) -> String {
            family == "inet6" ? "::1" : "127.0.0.1"
        }

        var isOffline: Bool { gateway == Self.offlineGateway(family: family) }

        fileprivate func args(_ verb: String) -> [String] {
            ["-q", "-n", verb, "-\(family)", dest, gateway]
        }
    }

    /// A default route scoped to the physical interface (`route add -ifscope en0 default
    /// <gw>`), kept while a full tunnel is up.
    ///
    /// Connections opened before the tunnel came up keep their physical source address,
    /// and XNU sends a TCP packet through the interface owning its source address, with a
    /// route lookup scoped to that interface. The physical interface stays the system's
    /// primary one here (the tunnel isn't a configd service), and the primary interface has
    /// no scoped default of its own; the lookup's fallback to "the default route" is a
    /// longest-prefix match on 0.0.0.0, which now finds the tunnel's 0.0.0.0/1 on the wrong
    /// interface. So every packet is dropped as unroutable before reaching any interface or
    /// pf, and TCP retries silently until the app gives up: 20–30 s of hanging in browsers
    /// and chat apps after connecting. With the scoped default those packets reach the
    /// physical interface again, where `PacketFilter` either rejects them or (setting off)
    /// lets them finish outside the tunnel. New connections still pick the tunnel.
    ///
    /// configd maintains scoped defaults for every non-primary interface itself, so only
    /// the primary interface's one is ever added or removed here.
    struct ScopedDefault: Codable, Equatable {
        var family: String  // "inet" | "inet6"
        var iface: String
        var gateway: String

        fileprivate var deleteArgs: [String] {
            ["-q", "-n", "delete", "-\(family)", "-ifscope", iface, "default"]
        }

        fileprivate var addArgs: [String] {
            ["-n", "add", "-\(family)", "-ifscope", iface, "default", gateway]
        }
    }

    /// The subnets directly attached to `iface` ("192.168.2.0/24", "2003:e5:d745:4c61::/64"),
    /// link-local ones excepted.
    static func attachedNetworks(iface: String) -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        var networks: [String] = []
        for entry in sequence(first: head, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            guard String(cString: ifa.ifa_name) == iface, let addr = ifa.ifa_addr, let mask = ifa.ifa_netmask else { continue }
            let family = Int32(addr.pointee.sa_family)
            let length = family == AF_INET ? 4 : family == AF_INET6 ? 16 : 0
            let offset = family == AF_INET ? 4 : 8  // sin_addr / sin6_addr within the sockaddr
            guard length > 0 else { continue }
            var bytes = [UInt8](repeating: 0, count: length)
            var prefix = 0
            let addrBytes = UnsafeRawPointer(addr).advanced(by: offset)
            let maskBytes = UnsafeRawPointer(mask).advanced(by: offset)
            for i in 0..<length {
                let m = maskBytes.load(fromByteOffset: i, as: UInt8.self)
                bytes[i] = addrBytes.load(fromByteOffset: i, as: UInt8.self) & m
                prefix += m.nonzeroBitCount
            }
            if family == AF_INET6, bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { continue }
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(family, bytes, &text, socklen_t(text.count)) != nil else { continue }
            let network = "\(String(cString: text))/\(prefix)"
            if !networks.contains(network) { networks.append(network) }
        }
        return networks
    }

    /// "inet" / "inet6" for each family whose default route the tunnel takes over.
    static func fullTunnelFamilies(networks: [String]) -> Set<String> {
        var families = Set<String>()
        if networks.contains("0.0.0.0/0") { families.insert("inet") }
        if networks.contains("::/0") { families.insert("inet6") }
        return families
    }

    /// The physical default route of each family, as the scoped default it calls for.
    static func physicalDefaults(families: Set<String>) -> [ScopedDefault] {
        ["inet", "inet6"].filter(families.contains).compactMap { family in
            guard let route = defaultRoute(v6: family == "inet6"), let iface = route.iface,
                  !iface.hasPrefix("utun") else { return nil }
            return ScopedDefault(family: family, iface: iface, gateway: route.gateway)
        }
    }

    /// Brings the scoped defaults this helper owns in line with `desired` and returns the
    /// ones it owns afterwards. Deleting is exact (`-ifscope` is part of the route's key,
    /// so the unscoped default can never match), but a scoped default is only deleted while
    /// its interface is still the primary one: once another interface took over, configd
    /// maintains this one.
    static func refreshScopedDefaults(_ owned: [ScopedDefault], desired: [ScopedDefault]) -> [ScopedDefault] {
        var result: [ScopedDefault] = []
        for family in ["inet", "inet6"] {
            let mine = owned.first { $0.family == family }
            let wanted = desired.first { $0.family == family }
            if let mine, mine != wanted, wanted == nil || wanted?.iface == mine.iface {
                route(mine.deleteArgs)
            }
            guard let wanted else { continue }
            // Re-added on every pass: IPConfiguration flushes routes along with the
            // addresses they use, and "File exists" is the cheap common case.
            guard let added = try? Shell.run("/sbin/route", wanted.addArgs) else { continue }
            let exists = (added.stdout + added.stderr).contains("File exists")
            if added.status == 0 || (exists && mine == wanted) {
                result.append(wanted)
            }
            // "File exists" for a route this helper didn't add: someone else's, left alone.
        }
        return result
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
            let gateway = gateways.gateway(family: family) ?? HostRoute.offlineGateway(family: family)
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
    ///
    /// Offline (no default gateway) the pin goes to loopback rather than being left
    /// alone: IPConfiguration deletes routes using an address it removes, and with the
    /// pin gone wireguard-go's own packets looped through the tunnel at ~75 MB/s.
    static func refreshHostRoutes(_ routes: [HostRoute]) -> [HostRoute] {
        let gateways = GatewayLookup()
        return routes.map { pin in
            let gateway = gateways.gateway(family: pin.family) ?? HostRoute.offlineGateway(family: pin.family)
            guard gateway != pin.dest else { return pin }
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
            let gateway = NetworkSetup.defaultRoute(v6: family == "inet6")?.gateway
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

    /// The physical default route's gateway and interface; nil without a gateway.
    private static func defaultRoute(v6: Bool) -> (gateway: String, iface: String?)? {
        let args = v6 ? ["-n", "get", "-inet6", "default"] : ["-n", "get", "default"]
        guard let result = try? Shell.run("/sbin/route", args), result.status == 0 else { return nil }
        var gateway: String?
        var iface: String?
        for line in result.stdout.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                gateway = trimmed.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("interface:") {
                iface = trimmed.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let gateway, !gateway.isEmpty else { return nil }
        return (gateway, iface)
    }
}
