import Foundation
import Combine
import Shared

enum HelperState {
    case unknown
    case notInstalled
    case versionMismatch
    case ok
}

final class AppState: ObservableObject {
    @Published var helperState: HelperState = .unknown
    @Published var tunnels: [TunnelInfo] = []
    @Published var activeTunnel: String?
    @Published var activeNetworks: [String] = []
    @Published var activeStatus: TunnelStatus?
    /// Helper setting; on by default, so assume so until the helper says otherwise.
    @Published var blockOutsideTunnel: Bool = true

    /// Set the instant the user triggers activate/deactivate so the UI reflects the
    /// in-progress state immediately instead of waiting for the helper round-trip.
    @Published var busy: Bool = false
    @Published var busyLabel: String?

    var isActive: Bool { activeTunnel != nil }
}

/// All helper interactions the UI triggers, funneled through one place so both the
/// menu and the manage window share refresh + error handling behavior.
final class TunnelController {
    let state: AppState
    private let queue = DispatchQueue(label: "tunnel-controller")
    var onError: ((String) -> Void)?

    init(state: AppState) {
        self.state = state
    }

    func refresh(_ completion: (() -> Void)? = nil) {
        queue.async {
            var helperState: HelperState = .notInstalled
            var tunnels: [TunnelInfo] = []
            var active: String?
            var networks: [String] = []
            var status: TunnelStatus?
            var blockOutsideTunnel: Bool?

            if let hello = try? HelperClient.hello() {
                if hello.version != IPC.protocolVersion || hello.build != IPC.build {
                    helperState = .versionMismatch
                } else {
                    helperState = .ok
                    if let listResponse = try? HelperClient.list() {
                        tunnels = listResponse.tunnels ?? []
                        active = listResponse.activeTunnel
                        networks = listResponse.activeNetworks ?? []
                        blockOutsideTunnel = listResponse.blockOutsideTunnel
                    }
                    if active != nil, let statusResponse = try? HelperClient.status() {
                        status = statusResponse.status
                    }
                }
            }

            DispatchQueue.main.async {
                self.state.helperState = helperState
                self.state.tunnels = tunnels
                self.state.activeTunnel = active
                self.state.activeNetworks = networks
                self.state.activeStatus = status
                if let blockOutsideTunnel { self.state.blockOutsideTunnel = blockOutsideTunnel }
                completion?()
            }
        }
    }

    func activate(_ name: String) {
        guard !state.busy else { return }
        markBusy("Activating \(name)…")
        performInBackground { try HelperClient.up(name) }
    }

    func deactivate() {
        guard !state.busy else { return }
        markBusy("Deactivating…")
        performInBackground { try HelperClient.down() }
    }

    /// Must be called on the main thread (menu/SwiftUI actions are). Reflects the
    /// pending operation in the UI right away.
    private func markBusy(_ label: String) {
        state.busy = true
        state.busyLabel = label
    }

    func setBlockOutsideTunnel(_ enabled: Bool) {
        // Optimistic, like delete/rename: the refresh after the call reconciles.
        state.blockOutsideTunnel = enabled
        performInBackground { try HelperClient.setBlockOutsideTunnel(enabled) }
    }

    func toggle(_ name: String) {
        if state.activeTunnel == name {
            deactivate()
        } else {
            activate(name)
        }
    }

    func delete(_ name: String) {
        // Optimistic: drop the row immediately so the button feels instant; the
        // subsequent refresh reconciles (re-adds it if the helper call actually failed).
        state.tunnels.removeAll { $0.name == name }
        performInBackground { try HelperClient.delete(name) }
    }

    /// Renames a tunnel. `completion` receives the new name on success (so the UI can
    /// keep it selected) or nil on failure.
    func rename(_ name: String, to newName: String, completion: ((String?) -> Void)? = nil) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        // Optimistic: reflect the new name in the list right away.
        if TunnelConfig.isValidName(trimmed), let idx = state.tunnels.firstIndex(where: { $0.name == name }) {
            state.tunnels[idx].name = trimmed
            if state.activeTunnel == name { state.activeTunnel = trimmed }
        }
        queue.async {
            var errorMessage: String?
            do {
                guard TunnelConfig.isValidName(trimmed) else {
                    throw ConfigError("“\(trimmed)” is not a valid tunnel name.")
                }
                try HelperClient.rename(name, to: trimmed)
            } catch {
                errorMessage = error.localizedDescription
            }
            DispatchQueue.main.async {
                if let errorMessage { self.onError?(errorMessage) }
                completion?(errorMessage == nil ? trimmed : nil)
                self.refresh()
            }
        }
    }

    func saveConfig(name: String, config: String, completion: ((String?) -> Void)? = nil) {
        queue.async {
            var errorMessage: String?
            do {
                try HelperClient.setConfig(name, config: config)
            } catch {
                errorMessage = error.localizedDescription
            }
            DispatchQueue.main.async {
                if let errorMessage { self.onError?(errorMessage) }
                completion?(errorMessage)
                self.refresh()
            }
        }
    }

    /// Imports config files; returns per-file error messages via completion.
    func importFiles(_ urls: [URL], completion: (([String]) -> Void)? = nil) {
        // Optimistic: show a row for each file straight away so the + button feels
        // responsive; the refresh after import reconciles (drops any that failed to parse).
        for url in urls {
            let name = TunnelConfig.sanitizeName(url.lastPathComponent)
            if !name.isEmpty, !state.tunnels.contains(where: { $0.name == name }) {
                state.tunnels.append(TunnelInfo(name: name, isActive: false))
            }
        }
        state.tunnels.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        queue.async {
            var errors: [String] = []
            for url in urls {
                let name = TunnelConfig.sanitizeName(url.lastPathComponent)
                do {
                    guard !name.isEmpty else { throw ConfigError("Cannot derive a tunnel name from \(url.lastPathComponent)") }
                    let text = try String(contentsOf: url, encoding: .utf8)
                    _ = try TunnelConfig.parse(text)
                    try HelperClient.importTunnel(name: name, config: text)
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                if !errors.isEmpty {
                    self.onError?("Some tunnels could not be imported:\n\n" + errors.joined(separator: "\n"))
                }
                completion?(errors)
                self.refresh()
            }
        }
    }

    private func performInBackground(_ work: @escaping () throws -> Void) {
        queue.async {
            var errorMessage: String?
            do {
                try work()
            } catch {
                errorMessage = error.localizedDescription
            }
            DispatchQueue.main.async {
                self.state.busy = false
                self.state.busyLabel = nil
                if let errorMessage { self.onError?(errorMessage) }
                self.refresh()
            }
        }
    }
}
