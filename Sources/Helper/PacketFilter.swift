import Foundation

/// The pf rules that keep traffic from bypassing a full tunnel. They live in their own
/// anchor under `com.apple/`, which the stock /etc/pf.conf already evaluates, so the main
/// ruleset (and other users of pf: AirDrop, Internet Sharing, VM networking) is never
/// touched. pf is shared, so it is turned on with a reference token (`pfctl -E`) and the
/// token is released when done; pf only goes off if nobody else holds one.
enum PacketFilter {
    static let anchor = "com.apple/wg-client"

    /// Rules rejecting everything that leaves a physical interface while the tunnel owns
    /// the default route, except traffic that belongs on that network: the tunnel's own
    /// packets to its endpoints, the local subnet, link-local, multicast and broadcast, and
    /// DHCP. TCP gets a reset and UDP a port-unreachable (`block return`), so apps learn
    /// at once and reconnect through the tunnel instead of retrying into the void.
    static func bypassRules(defaults: [NetworkSetup.ScopedDefault], endpoints: [String]) -> String {
        // Subnets spelled out rather than as `en0:network`, which pfctl resolves once at load
        // time: this way the text changes with the network, and a reconcile reloads it.
        let ifaces = Array(Set(defaults.map(\.iface))).sorted()
        let direct = ifaces.flatMap(NetworkSetup.attachedNetworks)
            + ["169.254.0.0/16", "224.0.0.0/4", "255.255.255.255", "fe80::/10", "ff00::/8"]
            + endpoints
        var rules = ["table <wg_direct> const { \(direct.joined(separator: ", ")) }"]
        for route in defaults {
            let (icmp, dhcpClientPort) = route.family == "inet6" ? ("ipv6-icmp", 546) : ("icmp", 68)
            let scope = "out quick on \(route.iface) \(route.family)"
            rules += [
                "block return \(scope) proto tcp to ! <wg_direct>",
                // DHCP renewals go unicast to the server, which may sit behind a relay.
                "block return \(scope) proto udp from any port != \(dhcpClientPort) to ! <wg_direct>",
                "block drop \(scope) proto \(icmp) to ! <wg_direct>",
            ]
        }
        return rules.joined(separator: "\n") + "\n"
    }

    /// Replaces the anchor's rules; returns whether pf accepted them.
    static func load(_ rules: String) -> Bool {
        guard let result = try? Shell.run("/sbin/pfctl", ["-a", anchor, "-f", "-"], stdin: rules) else { return false }
        if result.status != 0 {
            log("Warning: pf rejected the rules: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.status == 0
    }

    /// Empties the anchor. Only its rules and tables: a plain `-F all` is avoided so that
    /// nothing global (the state table other pf users' NAT relies on) can be flushed.
    static func clear() {
        _ = try? Shell.run("/sbin/pfctl", ["-a", anchor, "-F", "rules"])
        _ = try? Shell.run("/sbin/pfctl", ["-a", anchor, "-F", "Tables"])
    }

    /// Takes a pf enable reference; nil if pf could not be enabled.
    static func enable() -> String? {
        guard let result = try? Shell.run("/sbin/pfctl", ["-E"]), result.status == 0 else { return nil }
        for line in (result.stdout + "\n" + result.stderr).components(separatedBy: "\n") {
            let parts = line.components(separatedBy: ":")
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "Token" {
                let token = parts[1].trimmingCharacters(in: .whitespaces)
                return token.isEmpty ? nil : token
            }
        }
        return nil
    }

    static func release(_ token: String) {
        _ = try? Shell.run("/sbin/pfctl", ["-X", token])
    }

    /// pf can be switched off behind our back (`pfctl -d` ignores references).
    static var isEnabled: Bool {
        guard let result = try? Shell.run("/sbin/pfctl", ["-s", "info"]) else { return false }
        return result.stdout.contains("Status: Enabled")
    }
}
