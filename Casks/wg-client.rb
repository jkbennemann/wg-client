cask "wg-client" do
  version "0.0.3"
  sha256 "994b43ed73dfaa489592b2e40c08570129a1c5939e578906926b73aacf9d5757"

  url "https://github.com/jkbennemann/wg-client/releases/download/v#{version}/WG-Client-#{version}.zip",
      verified: "github.com/jkbennemann/wg-client/"
  name "WG Client"
  desc "Menu-bar WireGuard client with multi-tunnel support"
  homepage "https://github.com/jkbennemann/wg-client"

  # 0.0.x is a pre-1.0 line; allow Homebrew to see any newer tag as an upgrade.
  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "WG Client.app"

  # The app installs a privileged helper (root LaunchDaemon) on first launch.
  # On uninstall (and before each upgrade) Homebrew quits the app, unloads the
  # daemon, and removes its privileged files. The launchctl/delete steps touch
  # /Library, so Homebrew prompts once for admin rights. Tunnel configs live in
  # Application Support and are preserved here — only `--zap` removes them.
  # A tunnel can outlive the helper (wireguard-go runs on its own); its pf rules
  # would then block the physical network with nothing left to remove them.
  uninstall early_script: {
              executable:   "/sbin/pfctl",
              args:         ["-a", "com.apple/wg-client", "-F", "rules"],
              sudo:         true,
              must_succeed: false,
            },
            launchctl: "com.github.jkbennemann.wg-client.helper",
            quit:      "com.github.jkbennemann.wg-client",
            delete:    [
              "/Library/LaunchDaemons/com.github.jkbennemann.wg-client.helper.plist",
              "/Library/PrivilegedHelperTools/WGClient",
            ]

  # `brew uninstall --zap` also removes stored tunnel configs (which contain
  # private keys), runtime state, and preferences.
  zap delete: [
        "/Library/Application Support/WGClient",
        "/var/log/wg-client-helper.log",
        "/var/run/wg-client",
        "/var/run/wg-client.sock",
      ],
      trash:  [
        "~/Library/Preferences/com.github.jkbennemann.wg-client.plist",
        "~/Library/Saved Application State/com.github.jkbennemann.wg-client.savedState",
      ]
end
