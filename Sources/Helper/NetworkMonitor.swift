import Foundation
import SystemConfiguration

/// Watches the SystemConfiguration dynamic store for changes to the physical network —
/// Wi-Fi roams, sleep/wake, DHCP leases, cable or dock plugs, and configd re-applying
/// DNS preferences — and calls `onChange` on a private queue once things settle.
///
/// The tunnel's endpoint pin and DNS overlay are both tied to the network that existed
/// at connect time; without this, moving to another network leaves the tunnel dead
/// until it is reconnected.
final class NetworkMonitor {
    private let queue = DispatchQueue(label: "network-monitor")
    private let onChange: () -> Void
    private var store: SCDynamicStore?
    private var pending: [DispatchWorkItem] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkMonitor>.fromOpaque(info).takeUnretainedValue().scheduleReconcile()
        }
        guard let store = SCDynamicStoreCreate(nil, "com.github.jkbennemann.wg-client.monitor" as CFString,
                                               callback, &context) else {
            log("Warning: cannot watch for network changes; reconnect after switching networks")
            return
        }
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"]
        let patterns = [
            "State:/Network/Service/[^/]+/IPv4",
            "State:/Network/Service/[^/]+/IPv6",
            "Setup:/Network/Service/[^/]+/DNS",
        ]
        guard SCDynamicStoreSetNotificationKeys(store, keys as CFArray, patterns as CFArray),
              SCDynamicStoreSetDispatchQueue(store, queue) else {
            log("Warning: cannot watch for network changes; reconnect after switching networks")
            return
        }
        self.store = store
        // A tunnel adopted at startup may already be pinned to a network that is gone.
        queue.async { self.scheduleReconcile() }
    }

    /// A network transition arrives as a burst of store updates, and the kernel's
    /// default route can trail the store slightly — so act once the burst settles, then
    /// once more a little later. Must be called on `queue`.
    private func scheduleReconcile() {
        pending.forEach { $0.cancel() }
        pending = [0.5, 3.0].map { delay in
            let item = DispatchWorkItem(block: onChange)
            queue.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    }
}
