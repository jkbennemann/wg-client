cask "wg-client" do
  version "0.0.1"
  sha256 "c1ec837a8556d18d8a174c42a0ea10128a223afc54e6ed061fb2e829fc377e91"

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
  uninstall launchctl: "com.github.jkbennemann.wg-client.helper",
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
