import SwiftUI
import Shared

struct ManageTunnelsView: View {
    @ObservedObject var state: AppState
    let controller: TunnelController
    weak var delegate: AppDelegate?

    @State private var selection: String?
    @State private var configText: String?
    @State private var showEditSheet = false
    @State private var editText = ""
    @State private var showDeleteConfirm = false
    @State private var showRenameSheet = false
    @State private var renameTarget: String?
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 460)
        .sheet(isPresented: $showRenameSheet) { renameSheet() }
        .onAppear {
            controller.refresh()
            if selection == nil { selection = state.tunnels.first?.name }
        }
        .onChange(of: selection) { newValue in
            loadConfig(for: newValue)
        }
        .onChange(of: state.tunnels) { tunnels in
            if let sel = selection, !tunnels.contains(where: { $0.name == sel }) {
                selection = tunnels.first?.name
            } else if selection == nil {
                selection = tunnels.first?.name
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(state.tunnels, id: \.name) { tunnel in
                    HStack {
                        Circle()
                            .fill(tunnel.isActive ? Color.green : Color.secondary.opacity(0.35))
                            .frame(width: 8, height: 8)
                        Text(tunnel.name)
                            .lineLimit(1)
                        Spacer()
                    }
                    .tag(tunnel.name)
                    .contextMenu {
                        Button("Rename…") { beginRename(tunnel.name) }
                        Button(tunnel.isActive ? "Deactivate" : "Activate") {
                            controller.toggle(tunnel.name)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            selection = tunnel.name
                            showDeleteConfirm = true
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 12) {
                Button(action: { delegate?.importFromFile() }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Import tunnel(s) from file")

                Button(action: { showDeleteConfirm = true }) {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
                .help("Remove selected tunnel")

                Menu {
                    Button("View Log") { delegate?.openLogWindow() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More actions")

                Spacer()
            }
            .padding(8)
        }
        .confirmationDialog(
            "Delete tunnel “\(selection ?? "")”?",
            isPresented: $showDeleteConfirm
        ) {
            Button("Delete", role: .destructive) {
                if let name = selection { controller.delete(name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The tunnel configuration will be removed permanently.")
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let name = selection, let info = state.tunnels.first(where: { $0.name == name }) {
            tunnelDetail(info: info)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "network")
                    .font(.system(size: 42))
                    .foregroundColor(.secondary)
                Text(state.tunnels.isEmpty
                     ? "Import a tunnel configuration to get started."
                     : "Select a tunnel to view its configuration.")
                    .foregroundColor(.secondary)
                if state.tunnels.isEmpty {
                    Button("Import Tunnel(s) from File…") { delegate?.importFromFile() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tunnelDetail(info: TunnelInfo) -> some View {
        let parsed = configText.flatMap { try? TunnelConfig.parse($0) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(label: Text("Interface: \(info.name)").bold()) {
                    VStack(alignment: .leading, spacing: 6) {
                        row("Status", info.isActive ? "Active" : "Inactive")
                        if let publicKey = parsed?.interface.publicKey {
                            row("Public key", publicKey, monospaced: true)
                        }
                        if let addresses = parsed?.interface.addresses, !addresses.isEmpty {
                            row("Addresses", addresses.joined(separator: ", "))
                        }
                        if let dns = parsed?.interface.dns, !dns.isEmpty {
                            row("DNS servers", dns.joined(separator: ", "))
                        }
                        if let port = parsed?.interface.listenPort {
                            row("Listen port", String(port))
                        }
                        if let mtu = parsed?.interface.mtu {
                            row("MTU", String(mtu))
                        }
                        if info.isActive, let iface = state.activeStatus?.interfaceName {
                            row("System interface", iface)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                ForEach(Array((parsed?.peers ?? []).enumerated()), id: \.offset) { _, peer in
                    GroupBox(label: Text("Peer").bold()) {
                        VStack(alignment: .leading, spacing: 6) {
                            row("Public key", peer.publicKey, monospaced: true)
                            if !peer.allowedIPs.isEmpty {
                                row("Allowed IPs", peer.allowedIPs.joined(separator: ", "))
                            }
                            if let endpoint = peer.endpoint {
                                row("Endpoint", endpoint)
                            }
                            if let keepalive = peer.persistentKeepalive {
                                row("Keepalive", "every \(keepalive) seconds")
                            }
                            if info.isActive, let live = liveStatus(for: peer) {
                                if let handshake = live.lastHandshake {
                                    row("Latest handshake", relativeTime(handshake))
                                }
                                row("Transfer", "\(formatBytes(live.rxBytes)) received, \(formatBytes(live.txBytes)) sent")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                }

                if configText == nil {
                    Text("Loading configuration…").foregroundColor(.secondary)
                }

                Spacer(minLength: 0)

                HStack {
                    Button(info.isActive ? "Deactivate" : "Activate") {
                        controller.toggle(info.name)
                    }
                    .keyboardShortcut(.defaultAction)

                    Spacer()

                    Button("Rename…") { beginRename(info.name) }

                    Button("Edit") {
                        editText = configText ?? ""
                        showEditSheet = true
                    }
                    .disabled(configText == nil)
                }
            }
            .padding(16)
        }
        .sheet(isPresented: $showEditSheet) {
            editSheet(name: info.name)
        }
    }

    private func editSheet(name: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit \(name)").font(.headline)
            TextEditor(text: $editText)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 560, minHeight: 320)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel") { showEditSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    controller.saveConfig(name: name, config: editText) { error in
                        if error == nil {
                            configText = editText
                            showEditSheet = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            Text("Changes to an active tunnel apply the next time it is activated.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
    }

    private func renameSheet() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Tunnel").font(.headline)
            Text("Enter a new name for “\(renameTarget ?? "")”.")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("Tunnel name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
                .onSubmit(commitRename)
            HStack {
                Spacer()
                Button("Cancel") { showRenameSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commitRename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isRenameValid)
            }
        }
        .padding(16)
    }

    private var isRenameValid: Bool {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && TunnelConfig.isValidName(trimmed)
    }

    private func beginRename(_ name: String) {
        renameTarget = name
        renameText = name
        showRenameSheet = true
    }

    private func commitRename() {
        guard isRenameValid, let old = renameTarget else { return }
        controller.rename(old, to: renameText) { newName in
            if let newName { selection = newName }
            showRenameSheet = false
        }
    }

    // MARK: - Helpers

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label + ":")
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .trailing)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func loadConfig(for name: String?) {
        configText = nil
        guard let name else { return }
        DispatchQueue.global().async {
            let text = try? HelperClient.getConfig(name)
            DispatchQueue.main.async {
                if selection == name { configText = text }
            }
        }
    }

    private func liveStatus(for peer: PeerConfig) -> PeerStatus? {
        state.activeStatus?.peers.first(where: { $0.publicKey == peer.publicKey })
    }

    private func relativeTime(_ epochSeconds: Double) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: Date(timeIntervalSince1970: epochSeconds), relativeTo: Date())
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}
