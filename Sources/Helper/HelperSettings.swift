import Foundation

/// Machine-wide options set from the app, kept next to the tunnel configs so they apply
/// to tunnels brought up, adopted, or reconciled while the app isn't running.
enum HelperSettings {
    static let path = "/Library/Application Support/WGClient/settings.json"

    private struct Stored: Codable {
        var blockOutsideTunnel: Bool?
    }

    /// While a full tunnel is up, cut traffic that would leave outside it (connections
    /// opened before connecting, sockets bound to the physical interface) instead of
    /// letting it through. On unless turned off.
    static var blockOutsideTunnel: Bool {
        get { load().blockOutsideTunnel ?? true }
        set {
            var stored = load()
            stored.blockOutsideTunnel = newValue
            save(stored)
        }
    }

    private static func load() -> Stored {
        guard let data = FileManager.default.contents(atPath: path),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return Stored() }
        return stored
    }

    private static func save(_ stored: Stored) {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            log("Warning: could not save settings: \(error.localizedDescription)")
        }
    }
}
