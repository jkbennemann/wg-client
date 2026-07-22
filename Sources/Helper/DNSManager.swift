import Foundation
import SystemConfiguration

/// Sets DNS by writing directly to the SystemConfiguration dynamic store, the same
/// mechanism the resolver reads. This is effectively instant and requires no
/// subprocesses — unlike `networksetup`, which spawns one process per service per
/// operation and dominated connect/disconnect latency.
///
/// We override the DNS key of the primary IPv4/IPv6 service(s) (where the default
/// resolver's queries originate) and keep a serializable backup so the previous
/// value can be restored — or the key removed — when the tunnel goes down.
enum DNSManager {
    struct Backup: Codable {
        struct Entry: Codable {
            var key: String
            var priorPlist: Data?  // nil => key was absent; remove on restore
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
    /// everything else becomes a search domain). Returns nil if there were no
    /// server addresses to set (we never blank out ServerAddresses).
    ///
    /// `preserving` carries the pre-VPN DNS backup forward across a make-before-break
    /// handover: when non-nil, we overwrite the live DNS but return that original
    /// backup unchanged, so a later teardown restores the true pre-VPN state rather
    /// than the outgoing tunnel's (VPN) DNS values.
    static func apply(_ dnsEntries: [String], preserving existing: Backup? = nil) throws -> Backup? {
        let servers = dnsEntries.filter(isIPAddress)
        let search = dnsEntries.filter { !isIPAddress($0) }
        guard !servers.isEmpty else { return existing }

        guard let store = makeStore() else {
            throw HelperError("Unable to open the SystemConfiguration dynamic store")
        }
        let ids = primaryServiceIDs(store)
        guard !ids.isEmpty else {
            log("No primary network service; skipping DNS configuration")
            return existing ?? Backup(entries: [])
        }

        var dns: [String: Any] = ["ServerAddresses": servers]
        if !search.isEmpty {
            dns["SearchDomains"] = search
            dns["DomainName"] = search.first
        }

        var entries: [Backup.Entry] = []
        for id in ids {
            let key = "State:/Network/Service/\(id)/DNS"
            if existing == nil {
                let prior = SCDynamicStoreCopyValue(store, key as CFString)
                let priorData = prior.flatMap {
                    try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0)
                }
                entries.append(Backup.Entry(key: key, priorPlist: priorData))
            }
            SCDynamicStoreSetValue(store, key as CFString, dns as CFDictionary)
        }
        return existing ?? Backup(entries: entries)
    }

    static func restore(_ backup: Backup) {
        guard let store = makeStore() else { return }
        for entry in backup.entries {
            let key = entry.key as CFString
            if let data = entry.priorPlist,
               let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                SCDynamicStoreSetValue(store, key, obj as CFPropertyList)
            } else {
                SCDynamicStoreRemoveValue(store, key)
            }
        }
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, value, &v4) == 1 || inet_pton(AF_INET6, value, &v6) == 1
    }
}
