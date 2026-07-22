import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import Shared

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let state = AppState()
    private(set) lazy var controller = TunnelController(state: state)

    private var statusItem: NSStatusItem!
    private var manageWindow: NSWindow?
    private var logWindow: NSWindow?
    private var refreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "WireGuard")
        statusItem.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controller.onError = { [weak self] message in
            self?.showError(message)
        }

        state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                DispatchQueue.main.async {
                    self?.rebuildMenu()
                    self?.updateIcon()
                }
            }
            .store(in: &cancellables)

        rebuildMenu()
        controller.refresh { [weak self] in
            guard let self else { return }
            if self.state.helperState != .ok {
                self.promptHelperInstall(firstRun: true)
            }
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard self?.state.busy == false else { return }
            self?.controller.refresh()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        guard !state.busy else { return }
        controller.refresh()
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        switch state.helperState {
        case .ok:
            addStatusSection(to: menu)
            addTunnelSection(to: menu)
        case .notInstalled, .unknown:
            menu.addItem(disabledItem("Helper Not Installed"))
            menu.addItem(actionItem("Install Helper…", #selector(installHelper)))
            menu.addItem(.separator())
        case .versionMismatch:
            menu.addItem(disabledItem("Helper Needs Update"))
            menu.addItem(actionItem("Update Helper…", #selector(installHelper)))
            menu.addItem(.separator())
        }

        let manage = actionItem("Manage Tunnels", #selector(openManageWindow))
        manage.keyEquivalent = "m"
        menu.addItem(manage)
        menu.addItem(actionItem("Import Tunnel(s) from File…", #selector(importFromFile)))
        menu.addItem(actionItem("View Log", #selector(openLogWindow)))
        menu.addItem(.separator())
        menu.addItem(actionItem("About WG Client", #selector(showAbout)))
        let quit = actionItem("Quit WG Client", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func addStatusSection(to menu: NSMenu) {
        if state.busy {
            menu.addItem(disabledItem("Status: \(state.busyLabel ?? "Working…")"))
            menu.addItem(.separator())
            return
        }
        menu.addItem(disabledItem("Status: \(state.isActive ? "Active" : "Inactive")"))
        if state.isActive, !state.activeNetworks.isEmpty {
            menu.addItem(disabledItem("Networks: \(state.activeNetworks.joined(separator: ", "))"))
        }
        if state.isActive {
            menu.addItem(actionItem("Deactivate", #selector(deactivate)))
        }
        menu.addItem(.separator())
    }

    private func addTunnelSection(to menu: NSMenu) {
        if state.tunnels.isEmpty {
            menu.addItem(disabledItem("No Tunnels"))
        } else {
            for tunnel in state.tunnels {
                let item = NSMenuItem(title: tunnel.name, action: #selector(toggleTunnel(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = tunnel.name
                item.state = tunnel.isActive ? .on : .off
                item.isEnabled = !state.busy
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let symbol = state.busy ? "arrow.triangle.2.circlepath" : "network"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "WireGuard")
        button.image?.isTemplate = true
        button.alphaValue = (state.isActive || state.busy) ? 1.0 : 0.45
    }

    // MARK: - Actions

    @objc private func toggleTunnel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        controller.toggle(name)
    }

    @objc private func deactivate() {
        controller.deactivate()
    }

    @objc func openManageWindow() {
        if manageWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Manage Tunnels"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: ManageTunnelsView(state: state, controller: controller, delegate: self)
            )
            window.center()
            manageWindow = window
        }
        manageWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openLogWindow() {
        if logWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 460),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "WG Client Log"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: LogView())
            window.center()
            logWindow = window
        }
        logWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func importFromFile() {
        guard state.helperState == .ok else {
            promptHelperInstall(firstRun: false)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Import Tunnel(s)"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let confType = UTType(filenameExtension: "conf") {
            panel.allowedContentTypes = [confType]
        }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        controller.importFiles(panel.urls)
    }

    @objc private func installHelper() {
        performHelperInstall()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "An open-source client for WireGuard® on macOS. Tunnels are powered by wireguard-go via a privileged helper daemon. Not affiliated with WireGuard LLC.",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
            )
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helper install

    private func promptHelperInstall(firstRun: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = firstRun ? "Install WireGuard Helper" : "WireGuard Helper Required"
        alert.informativeText = "Creating VPN tunnels requires a privileged helper daemon. "
            + "It is installed once with an administrator prompt and then starts automatically."
        alert.addButton(withTitle: "Install…")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            performHelperInstall()
        }
    }

    private func performHelperInstall() {
        DispatchQueue.global().async {
            do {
                try HelperInstaller.install()
                DispatchQueue.main.async { self.controller.refresh() }
            } catch HelperInstallerError.cancelled {
                // user backed out of the admin prompt — nothing to report
            } catch {
                DispatchQueue.main.async { self.showError(error.localizedDescription) }
            }
        }
    }

    func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "WG Client"
        alert.informativeText = message
        alert.runModal()
    }
}
