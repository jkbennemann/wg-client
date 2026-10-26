import Foundation
import SystemConfiguration

/// Sets DNS by writing directly to the SystemConfiguration dynamic store, the same
/// mechanism the resolver reads. This is effectively instant and requires no
/// subprocesses — unlike `networksetup`, which spawns one process per service per
/// operation and dominated connect/disconnect latency.
///
/// We overlay the `Setup:` DNS entity of the primary IPv4/IPv6 service(s) — the slot a
/// manually configured DNS server occupies — which configd merges over the service's
/// `State:` DNS (the DHCP / router-advertisement values). Overriding `State:` instead
/// does not stick: IPConfiguration republishes it on every DHCP renewal and IPv6 RA,
/// often within seconds. `Setup:` is only rewritten when configd re-applies the network
/// preferences, which `apply` detects and re-asserts on the next network change. Nothing
/// touches the persistent preferences, so a crash can't leave DNS behind past a reboot.
enum DNSManager {
    struct Backup: Codable {
        struct Entry: Codable {
            var key: String
            var priorPlist: Data?    // nil => key was absent; remove on restore
            var appliedPlist: Data?  // what we last wrote, to tell it apart from configd's
        }
        var entries: [Entry]
    }

    private static func makeStore() -> SCDynamicStore? {
        SCDynamicStoreCreate(nil, "com.github.jkbennemann.wg-client" as CFString, nil, nil)
    }

    private static func primaryServiceIDs(_ store: SCDynamicStore) -> [String] {
        var ids: [String] = []
        for globalKey in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let dict = SCDynamicStoreCopyValue(store, globalKey as CFString) as? [String: Any],
               let service = dict["PrimaryService"] as? String, !ids.contains(service) {
                ids.append(service)
            }
        }
        return ids
    }

    /// Applies DNS from a list of `DNS =` values (IP addresses become servers,
    /// everything else becomes a search domain) to the current primary service(s).
    ///
    /// Idempotent, so it is safe to call on every network change: services that already
    /// carry our value are left alone. `backup` is threaded through every call — and
    /// across a make-before-break handover — so a teardown restores the true pre-VPN
    /// value rather than an outgoing tunnel's. Returns the backup to persist and the
    /// keys written by this call. With no server addresses or no primary service
    /// (offline, mid-roam), nothing is touched.
    static func apply(_ dnsEntries: [String], backup: Backup?) throws -> (backup: Backup?, written: [String]) {
        let servers = dnsEntries.filter(isIPAddress)
        let search = dnsEntries.filter { !isIPAddress($0) }
        guard !servers.isEmpty else { return (backup, []) }

        guard let store = makeStore() else {
            throw HelperError("Unable to open the SystemConfiguration dynamic store")
        }
        let ids = primaryServiceIDs(store)
        guard !ids.isEmpty else { return (backup, []) }

        var dns: [String: Any] = ["ServerAddresses": servers]
        if !search.isEmpty {
            dns["SearchDomains"] = search
            dns["DomainName"] = search.first
        }
        let desired = dns as NSDictionary

        // Entries left by helpers that overrode State: keys are dropped: IPConfiguration
        // republishes those keys by itself, and writing an old snapshot back would
        // reinstate stale DNS. Only a key still holding the tunnel's value is put back.
        for legacy in backup?.entries ?? [] where legacy.key.hasPrefix("State:") {
            if isEqual(SCDynamicStoreCopyValue(store, legacy.key as CFString), desired) {
                putBack(legacy, store)
            }
        }
        var entries = (backup?.entries ?? []).filter { $0.key.hasPrefix("Setup:") }
        var written: [String] = []
        for id in ids {
            let key = "Setup:/Network/Service/\(id)/DNS"
            let current = SCDynamicStoreCopyValue(store, key as CFString)
            if let index = entries.firstIndex(where: { $0.key == key }) {
                // Anything other than our own value was put there by configd re-applying
                // the network preferences: that is now the value to restore on teardown.
                let ours = isEqual(current, decode(entries[index].appliedPlist)) || isEqual(current, desired)
                if !ours { entries[index].priorPlist = encode(current) }
                entries[index].appliedPlist = encode(desired)
            } else {
                entries.append(Backup.Entry(key: key, priorPlist: encode(current), appliedPlist: encode(desired)))
            }
            if !isEqual(current, desired) {
                SCDynamicStoreSetValue(store, key as CFString, desired)
                written.append(key)
            }
        }
        return (Backup(entries: entries), written)
    }

    /// Puts back each overlaid key's pre-VPN value. A key that no longer holds what we
    /// wrote has been re-applied by configd since, so it is already correct and left alone.
    static func restore(_ backup: Backup) {
        guard let store = makeStore() else { return }
        for entry in backup.entries where entry.key.hasPrefix("Setup:") {
            if entry.appliedPlist != nil,
               !isEqual(SCDynamicStoreCopyValue(store, entry.key as CFString), decode(entry.appliedPlist)) {
                continue
            }
            putBack(entry, store)
        }
    }

    private static func putBack(_ entry: Backup.Entry, _ store: SCDynamicStore) {
        let key = entry.key as CFString
        if let prior = decode(entry.priorPlist) {
            SCDynamicStoreSetValue(store, key, prior)
        } else {
            SCDynamicStoreRemoveValue(store, key)
        }
    }

    private static func encode(_ value: CFPropertyList?) -> Data? {
        value.flatMap { try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
    }

    private static func decode(_ data: Data?) -> CFPropertyList? {
        data.flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as CFPropertyList }
    }

    private static func isEqual(_ a: CFPropertyList?, _ b: CFPropertyList?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return CFEqual(a, b)
        default: return false
        }
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, value, &v4) == 1 || inet_pton(AF_INET6, value, &v6) == 1
    }
}
