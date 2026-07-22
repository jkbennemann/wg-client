import AppKit
import Foundation

enum HelperInstallerError: LocalizedError {
    case cancelled
    case missingResources
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Installation was cancelled."
        case .missingResources:
            return "Helper resources not found in the app bundle. Build the app with scripts/build-app.sh — `swift run` does not bundle the helper."
        case .failed(let message):
            return "Helper installation failed: \(message)"
        }
    }
}

enum HelperInstaller {
    /// Installs (or upgrades) the privileged helper via a one-time admin prompt.
    static func install() throws {
        guard let resources = Bundle.main.resourcePath else { throw HelperInstallerError.missingResources }
        let script = resources + "/install-helper.sh"
        let helper = resources + "/wireguard-client-helper"
        let wireguardGo = resources + "/wireguard-go"
        let plist = resources + "/com.github.jkbennemann.wg-client.helper.plist"

        let fm = FileManager.default
        for path in [script, helper, wireguardGo, plist] where !fm.fileExists(atPath: path) {
            throw HelperInstallerError.missingResources
        }

        let shellCommand = "/bin/sh " + [script, helper, wireguardGo, plist].map(shellQuote).joined(separator: " ")
        let appleScript = "do shell script \"\(escapeForAppleScript(shellCommand))\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if stderr.contains("-128") { throw HelperInstallerError.cancelled }
            throw HelperInstallerError.failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Give launchd a moment to start the daemon.
        for _ in 0..<20 {
            if (try? HelperClient.hello()) != nil { return }
            usleep(250_000)
        }
        throw HelperInstallerError.failed("Helper installed but did not start — check /var/log/wg-client-helper.log")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
