import Foundation
import Shared

/// Owns the lifecycle of the active tunnel: spawns wireguard-go, pushes the config over
/// UAPI, sets up addresses/routes/DNS, and tears everything down again.
/// Exactly one tunnel is active at a time — activating a tunnel switches away from the
/// previous one.
final class Engine {
    struct ActiveState: Codable {
        var name: String
        var pid: Int32
        var iface: String
        var networks: [String]
        var hostRoutes: [NetworkSetup.HostRoute]
        var dnsBackup: DNSManager.Backup?
        /// The tunnel's `DNS =` entries, re-applied after network changes. nil in state
        /// written by older helpers; read back from the stored config then.
        var dns: [String]?
        /// What keeps traffic from bypassing the tunnel; nil in state from older helpers.
        var bypass: BypassState?
    }

    /// The scoped default routes and pf rules managed by `enforceBypassPolicy`.
    struct BypassState: Codable {
        var scopedDefaults: [NetworkSetup.ScopedDefault] = []
        var pfToken: String?
        var pfRules: String?
    }

    static let stateDir = "/var/run/wg-client"
    static let statePath = stateDir + "/active.json"
    static let tunNameFile = stateDir + "/tun.name"

    private let lock = NSLock()
    private var child: Process?
    private var exitWatch: DispatchSourceProcess?
    /// The network the last reconcile saw, so each change is logged once.
    private var lastNetwork: String?

    /// Directory the helper binary lives in; wireguard-go is installed next to it.
    private lazy var helperDir: String = {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().path
    }()

    func ensureDirectories() throws {
        try FileManager.default.createDirectory(atPath: Self.stateDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    var activeState: ActiveState? {
        guard let data = FileManager.default.contents(atPath: Self.statePath) else { return nil }
        return try? JSONDecoder().decode(ActiveState.self, from: data)
    }

    var activeName: String? { activeState?.name }
    var activeNetworks: [String] { activeState?.networks ?? [] }

    /// Called at startup: if a previous helper instance left state behind and the
    /// wireguard-go process is gone, undo its DNS/route changes.
    func reconcileOnStartup() {
        guard let state = activeState else {
            // Rules left by a helper that died mid-teardown would block the physical network.
            PacketFilter.clear()
            return
        }
        if kill(state.pid, 0) != 0 {
            log("Stale state for tunnel \(state.name) (pid \(state.pid) gone), cleaning up")
            cleanup(state, killProcess: false)
        } else {
            log("Adopted running tunnel \(state.name) on \(state.iface) (pid \(state.pid))")
            watchForExit(pid: state.pid)
        }
    }

    func up(name: String, configText: String) throws {
        lock.lock(); defer { lock.unlock() }

        let overallStart = DispatchTime.now()
        let config = try TunnelConfig.parse(configText)
        let current = activeState
        let networks = config.peers.flatMap { $0.allowedIPs }.map(UAPI.normalizeCIDR)
        var bypass = current?.bypass ?? BypassState()

        // Bring the NEW tunnel fully onto its own interface first — the old tunnel (if
        // any) is untouched and keeps carrying traffic throughout. This is the only
        // step allowed to throw: if it fails, the old tunnel is never disturbed and its
        // own cleanup runs inside bringUpInterface.
        let (process, iface, pins) = try bringUpInterface(config: config, start: overallStart) { pins in
            // The old tunnel's rules only let its own endpoints through; the pins are about
            // to send the new tunnel's handshake out the physical network.
            guard let current, bypass.pfRules != nil else { return }
            enforceBypassPolicy(&bypass, families: NetworkSetup.fullTunnelFamilies(networks: current.networks),
                                endpoints: (current.hostRoutes + pins).map(\.dest))
        }

        // From here the new interface is up and able to carry traffic. Everything below
        // is best-effort finalization: a secondary failure (DNS store, status file)
        // must never abort the switch or tear the working tunnel back down.
        let networkArgs = NetworkSetup.networkRouteArgs(iface: iface, config: config)
        var lastStamp = DispatchTime.now()
        var dnsBackup: DNSManager.Backup?

        if let current {
            // Make-before-break handover: atomically re-point routes from the old
            // interface to the new one (route change), switch DNS, THEN retire the
            // old tunnel. The connectivity gap is just the route-table flip.
            log("Handover: \(current.name) (\(current.iface)) → \(name) (\(iface))")
            NetworkSetup.installNetworkRoutes(networkArgs, replaceExisting: true)
            lastStamp = phase("cut routes over to \(iface)", since: lastStamp)

            if !config.interface.dns.isEmpty {
                dnsBackup = (try? DNSManager.apply(config.interface.dns, backup: current.dnsBackup))?.backup
                    ?? current.dnsBackup
            } else if let originalDNS = current.dnsBackup {
                DNSManager.restore(originalDNS)  // new tunnel has no DNS → revert to pre-VPN
            }
            lastStamp = phase("switch DNS", since: lastStamp)

            // Retire the old tunnel. Its interface routes vanish with its utun; we
            // re-assert the new tunnel's routes and endpoint pins afterwards so
            // nothing is left pointing at the interface that just disappeared (and
            // so a shared endpoint pin removed with the old tunnel is restored).
            terminateProcess(pid: current.pid)
            NetworkSetup.removeHostRoutes(current.hostRoutes)
            NetworkSetup.installNetworkRoutes(networkArgs, replaceExisting: false)
            NetworkSetup.installHostRoutes(pins)
            lastStamp = phase("retire \(current.name)", since: lastStamp)
        } else {
            NetworkSetup.installNetworkRoutes(networkArgs, replaceExisting: false)
            lastStamp = phase("add routes", since: lastStamp)
            if !config.interface.dns.isEmpty {
                do {
                    dnsBackup = try DNSManager.apply(config.interface.dns, backup: nil).backup
                } catch {
                    log("Warning: could not set DNS: \(error.localizedDescription)")
                }
                lastStamp = phase("apply DNS", since: lastStamp)
            }
        }

        // Only now that the tunnel owns the default route: strict rules loaded earlier
        // would block the physical network's ordinary traffic.
        enforceBypassPolicy(&bypass, families: NetworkSetup.fullTunnelFamilies(networks: networks),
                            endpoints: pins.map(\.dest))
        _ = phase("route connections opened before connecting", since: lastStamp)

        let state = ActiveState(
            name: name,
            pid: process.processIdentifier,
            iface: iface,
            networks: networks,
            hostRoutes: pins,
            dnsBackup: dnsBackup,
            dns: config.interface.dns,
            bypass: bypass
        )
        save(state)
        child = process
        watchForExit(pid: process.processIdentifier)
        // Connections opened before this (direct, or through the previous tunnel) can't
        // carry traffic anymore; let apps that listen for network changes drop them.
        NetworkMonitor.announceChange()
        _ = phase("total activation", since: overallStart)
        log("Tunnel \(name) is up on \(iface)")
    }

    /// Spawns wireguard-go, waits for its utun + UAPI socket, applies the config, brings
    /// the interface up with its addresses, and pins the peer endpoints via the physical
    /// gateway. Does NOT install network routes, DNS, or persist state — so it never
    /// disturbs an already-active tunnel. Returns the process, interface, and pin routes.
    private func bringUpInterface(config: TunnelConfig, start: DispatchTime,
                                  beforePinning: ([NetworkSetup.HostRoute]) -> Void) throws -> (Process, String, [NetworkSetup.HostRoute]) {
        let wgGoPath = helperDir + "/wireguard-go"
        guard FileManager.default.isExecutableFile(atPath: wgGoPath) else {
            throw HelperError("wireguard-go not found at \(wgGoPath) — reinstall the helper")
        }

        // Spawn first, then do CPU/network work (endpoint resolution) while wireguard-go
        // creates its utun in parallel, hiding its startup latency.
        try? FileManager.default.removeItem(atPath: Self.tunNameFile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: wgGoPath)
        process.arguments = ["-f", "utun"]
        var env = ProcessInfo.processInfo.environment
        env["WG_TUN_NAME_FILE"] = Self.tunNameFile
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        try process.run()
        var lastStamp = phase("spawn wireguard-go", since: start)

        let resolvedEndpoints: [String?] = try config.peers.map { peer in
            guard let endpoint = peer.endpoint else { return nil }
            return try Endpoint.resolve(endpoint)
        }
        lastStamp = phase("resolve endpoints", since: lastStamp)

        // Wait for the utun + UAPI socket. Poll at 5ms so we proceed the moment it is
        // ready (usually a few tens of ms), up to a 6s ceiling.
        var iface: String?
        for _ in 0..<1200 {
            if let contents = try? String(contentsOfFile: Self.tunNameFile, encoding: .utf8) {
                let name = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, FileManager.default.fileExists(atPath: UAPI.socketPath(iface: name)) {
                    iface = name
                    break
                }
            }
            if !process.isRunning { break }
            usleep(5_000)
        }
        guard let iface else {
            if process.isRunning { process.terminate() }
            throw HelperError("wireguard-go failed to start — check /var/log/wg-client-helper.log")
        }
        lastStamp = phase("await utun ready (\(iface))", since: lastStamp)

        do {
            try UAPI.applyConfig(iface: iface, config: config, resolvedEndpoints: resolvedEndpoints)
            lastStamp = phase("apply UAPI config", since: lastStamp)
            try NetworkSetup.configureInterface(iface: iface, config: config)
            lastStamp = phase("configure interface", since: lastStamp)
            let pins = NetworkSetup.endpointHostRoutes(config: config, resolvedEndpoints: resolvedEndpoints)
            beforePinning(pins)
            NetworkSetup.installHostRoutes(pins)
            _ = phase("pin endpoints", since: lastStamp)
            return (process, iface, pins)
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    private func terminateProcess(pid: Int32) {
        kill(pid, SIGTERM)
        // wireguard-go exits within a few tens of ms; poll finely up to 2s.
        for _ in 0..<200 {
            if kill(pid, 0) != 0 { break }
            usleep(10_000)
        }
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
            for _ in 0..<50 where kill(pid, 0) == 0 { usleep(10_000) }
        }
    }

    func renameActive(from old: String, to new: String) {
        lock.lock(); defer { lock.unlock() }
        guard var state = activeState, state.name == old else { return }
        state.name = new
        save(state)
    }

    /// Re-asserts the active tunnel's endpoint pins and DNS against the network the Mac
    /// is on *now*. Called by `NetworkMonitor` after Wi-Fi roams, sleep/wake, and DHCP or
    /// preference changes; cheap and idempotent, so spurious calls are harmless.
    func reconcileNetwork() {
        lock.lock(); defer { lock.unlock() }
        guard var state = activeState, kill(state.pid, 0) == 0 else { return }

        // Logged on any change of the network itself, not just of the gateway: a new
        // address behind the same router needs the re-pin just as much.
        let network = NetworkMonitor.primaryIPv4Summary() ?? "no IPv4 network"
        let pins = NetworkSetup.refreshHostRoutes(state.hostRoutes)
        if network != lastNetwork || pins != state.hostRoutes {
            let summary = pins.map { "\($0.dest) " + ($0.isOffline ? "to loopback (offline)" : "via \($0.gateway)") }
            log("Network: \(network); endpoint pinned " + (summary.isEmpty ? "nowhere" : summary.joined(separator: ", ")))
            lastNetwork = network
        }
        state.hostRoutes = pins

        var bypass = state.bypass ?? BypassState()
        enforceBypassPolicy(&bypass, families: NetworkSetup.fullTunnelFamilies(networks: state.networks),
                            endpoints: pins.map(\.dest))
        state.bypass = bypass

        let dns = state.dns ?? (try? TunnelStore.read(name: state.name))
            .flatMap { try? TunnelConfig.parse($0) }?.interface.dns ?? []
        state.dns = dns
        if !dns.isEmpty {
            do {
                let (backup, written) = try DNSManager.apply(dns, backup: state.dnsBackup)
                state.dnsBackup = backup
                if !written.isEmpty {
                    log("Network changed: re-applied tunnel DNS to " + written.joined(separator: ", "))
                }
            } catch {
                log("Warning: could not re-apply DNS: \(error.localizedDescription)")
            }
        }
        save(state)
    }

    /// Applies a changed `HelperSettings.blockOutsideTunnel` to the active tunnel, if any.
    func applySettings() {
        lock.lock(); defer { lock.unlock() }
        guard var state = activeState, kill(state.pid, 0) == 0 else { return }
        var bypass = state.bypass ?? BypassState()
        enforceBypassPolicy(&bypass, families: NetworkSetup.fullTunnelFamilies(networks: state.networks),
                            endpoints: state.hostRoutes.map(\.dest))
        state.bypass = bypass
        save(state)
    }

    /// Decides what happens to traffic that would leave outside a full tunnel: connections
    /// opened before it came up, and sockets bound to the physical interface. Either way
    /// it gets a route again (see `NetworkSetup.ScopedDefault`); with `blockOutsideTunnel`
    /// pf rejects it on the physical interface so apps reconnect through the tunnel at
    /// once, otherwise it carries on outside the tunnel until it closes. If the rules can't
    /// be loaded no route is added either: that traffic then stalls, but never leaks.
    private func enforceBypassPolicy(_ bypass: inout BypassState, families: Set<String>, endpoints: [String]) {
        let defaults = NetworkSetup.physicalDefaults(families: families)
        var routed = defaults
        if HelperSettings.blockOutsideTunnel, !defaults.isEmpty {
            let rules = PacketFilter.bypassRules(defaults: defaults, endpoints: endpoints)
            if bypass.pfToken == nil || !PacketFilter.isEnabled {
                // A token is void once pf was switched off with `pfctl -d`.
                if let token = bypass.pfToken { PacketFilter.release(token) }
                bypass.pfToken = PacketFilter.enable()
            }
            if bypass.pfToken != nil, rules == bypass.pfRules || PacketFilter.load(rules) {
                if bypass.pfRules == nil {
                    log("Blocking traffic outside the tunnel on " + Set(defaults.map(\.iface)).sorted().joined(separator: ", "))
                }
                bypass.pfRules = rules
            } else {
                log("Warning: could not set up pf; connections opened before connecting stall until they time out")
                clearBypassRules(&bypass)
                routed = []
            }
        } else if bypass.pfRules != nil || bypass.pfToken != nil {
            clearBypassRules(&bypass)
            if !HelperSettings.blockOutsideTunnel {
                log("No longer blocking traffic outside the tunnel")
            }
        }

        let owned = NetworkSetup.refreshScopedDefaults(bypass.scopedDefaults, desired: routed)
        if owned != bypass.scopedDefaults {
            let summary = owned.map { "\($0.iface) via \($0.gateway)" }
            log("Route for connections opened before connecting: " + (summary.isEmpty ? "none" : summary.joined(separator: ", ")))
        }
        bypass.scopedDefaults = owned
    }

    private func clearBypassRules(_ bypass: inout BypassState) {
        if bypass.pfRules != nil {
            PacketFilter.clear()
        }
        if let token = bypass.pfToken {
            PacketFilter.release(token)
        }
        bypass.pfRules = nil
        bypass.pfToken = nil
    }

    /// wireguard-go dying on its own takes the tunnel's routes with its utun but leaves the
    /// endpoint pins, the DNS override, and the pf rules, which would cut the Mac off the
    /// physical network. Clean up as if the tunnel had been switched off.
    private func watchForExit(pid: Int32) {
        exitWatch?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { [weak self] in self?.tunnelProcessExited(pid: pid) }
        source.resume()
        exitWatch = source
    }

    private func tunnelProcessExited(pid: Int32) {
        lock.lock(); defer { lock.unlock() }
        // A tunnel we switched away from or took down ourselves no longer owns the state.
        guard let state = activeState, state.pid == pid else { return }
        log("wireguard-go for \(state.name) exited unexpectedly; removing its routes, DNS and firewall rules")
        cleanup(state, killProcess: false)
        NetworkMonitor.announceChange()
    }

    private func save(_ state: ActiveState) {
        guard let data = try? JSONEncoder().encode(state) else {
            log("Warning: could not persist active-tunnel state")
            return
        }
        try? data.write(to: URL(fileURLWithPath: Self.statePath), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.statePath)
    }

    /// Logs how long a phase took and returns a fresh timestamp to chain from.
    private func phase(_ label: String, since: DispatchTime) -> DispatchTime {
        let now = DispatchTime.now()
        let ms = Double(now.uptimeNanoseconds &- since.uptimeNanoseconds) / 1_000_000
        log(String(format: "  ↳ %@: %.0f ms", label, ms))
        return now
    }

    func down() throws {
        lock.lock(); defer { lock.unlock() }
        guard let state = activeState else {
            throw HelperError("No tunnel is active")
        }
        cleanup(state, killProcess: true)
        NetworkMonitor.announceChange()
        log("Tunnel \(state.name) is down")
    }

    func status() -> TunnelStatus? {
        guard let state = activeState else { return nil }
        guard FileManager.default.fileExists(atPath: UAPI.socketPath(iface: state.iface)) else { return nil }
        return try? UAPI.status(iface: state.iface, tunnelName: state.name)
    }

    private func cleanup(_ state: ActiveState, killProcess: Bool) {
        // Restore DNS first (instant, in-process) so name resolution is never left
        // pointing at the now-gone tunnel, even briefly.
        if let dnsBackup = state.dnsBackup {
            DNSManager.restore(dnsBackup)
        }
        // Before the tunnel's routes vanish: from then on the physical network carries all
        // traffic, and the rules would block it.
        var bypass = state.bypass ?? BypassState()
        bypass.scopedDefaults = NetworkSetup.refreshScopedDefaults(bypass.scopedDefaults, desired: [])
        clearBypassRules(&bypass)
        if killProcess {
            terminateProcess(pid: state.pid)
        }
        // Routes bound to the utun disappear with the interface; only the pinned
        // endpoint host routes survive and must be deleted explicitly.
        NetworkSetup.removeHostRoutes(state.hostRoutes)
        try? FileManager.default.removeItem(atPath: Self.statePath)
        try? FileManager.default.removeItem(atPath: Self.tunNameFile)
        child = nil
    }
}
