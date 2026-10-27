# WG Client for macOS

An open-source, App Store-free client for [WireGuard](https://www.wireguard.com/)
on macOS. It lives in the menu bar, imports standard `wg-quick` style `.conf`
files, supports multiple tunnels, and switches between them with a make-before-break
handover.

No Apple ID or App Store access is required, and it does not depend on the
(outdated) Homebrew `wireguard-tools`.

> WireGuard is a registered trademark of Jason A. Donenfeld. This is an independent,
> unofficial project and is **not** affiliated with or endorsed by WireGuard LLC.

## Install

```sh
brew install --cask jkbennemann/tap/wg-client
```

This taps `jkbennemann/homebrew-tap` automatically and installs `WG Client.app`
into `/Applications`. Launch it, and on first run it will offer to install its
privileged helper (one admin prompt).

To upgrade: `brew upgrade --cask wg-client`. To remove: `brew uninstall --cask
wg-client` (add `--zap` to also delete stored tunnel configs).

## How it works

```
┌────────────────────┐   unix socket    ┌──────────────────────────┐
│  Menu bar app      │ ───────────────▶ │  Privileged helper       │
│  (WireGuardClient) │  JSON requests   │  (launchd daemon, root)  │
└────────────────────┘                  │  • stores tunnel configs │
                                        │  • spawns wireguard-go   │
                                        │  • addresses, routes, DNS│
                                        └──────────────────────────┘
```

- The **menu bar app** is a plain SwiftUI/AppKit app. It cannot create tunnels
  itself (creating `utun` interfaces requires root), so it talks to the helper.
- The **helper** is a small launchd daemon installed once via an admin prompt.
  It runs `wireguard-go` (bundled in the app), pushes the config over the
  [userspace UAPI](https://www.wireguard.com/xplatform/), assigns addresses,
  installs routes (including the `/1` split for full-tunnel configs plus a
  pinned endpoint route), and sets DNS by writing directly to the
  SystemConfiguration dynamic store — the same things `wg-quick` would do,
  implemented natively and without slow per-service `networksetup` subprocesses.
- Requests to the helper are only accepted from root or the **current console
  user** (checked via `getpeereid`). Configs (private keys) are stored root-only
  in `/Library/Application Support/WGClient/tunnels`.
- One tunnel is active at a time; activating another one switches over.

## Building

Requirements: macOS 13+, Xcode Command Line Tools. Go is only needed if
`wireguard-go` isn't already installed via Homebrew (the build script builds it
from source automatically when Go is available).

```sh
./scripts/build-app.sh
```

This produces `dist/WG Client.app` (ad-hoc signed). Copy it to `/Applications`.

## Releasing

Releases are distributed as a notarized `WG Client.app` attached to a GitHub
Release, installed via a Homebrew Cask hosted in a separate tap repo.

**Repos**

- `jkbennemann/wg-client` — this source repo; GitHub Releases host the built app.
- `jkbennemann/homebrew-tap` — the Homebrew tap; contains `Casks/wg-client.rb`
  (a copy of this repo's `Casks/wg-client.rb`). The tap repo **must** be named
  `homebrew-tap` for `brew tap jkbennemann/tap` to resolve it. Using a generic
  `homebrew-tap` (rather than a per-app repo) lets you publish future tools from
  the same tap.

**One-time setup**

- An Apple Developer ID Application certificate installed in your login keychain.
- A notarytool credential profile:
  ```sh
  xcrun notarytool store-credentials wg-client-notary \
      --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
  ```

**Cutting a release locally**

```sh
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE="wg-client-notary"
scripts/package-release.sh 0.0.1
```

This builds, signs with a hardened runtime + secure timestamp, notarizes, staples,
and zips the app, then prints the `version` and `sha256` for the cask. Then:

```sh
gh release create v0.0.1 "dist/WG-Client-0.0.1.zip" --title v0.0.1 --generate-notes
# update version + sha256 in the tap's Casks/wg-client.rb and push
```

**Or via CI:** push a `vX.Y.Z` tag and `.github/workflows/release.yml` does all of
the above on a macOS runner, then commits the updated cask to the tap. It needs
these repo secrets: `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`,
`MACOS_KEYCHAIN_PASSWORD`, `MACOS_CODESIGN_IDENTITY`, `NOTARY_APPLE_ID`,
`NOTARY_TEAM_ID`, `NOTARY_PASSWORD`, and `TAP_PUSH_TOKEN` (a PAT with write access
to the tap repo).

Bump `CFBundleShortVersionString`/`CFBundleVersion` in `Resources/Info.plist` and
`IPC.build` in `Sources/Shared/IPC.swift` to match each release (the build script
can also stamp the version via `WG_VERSION`; `IPC.build` triggers the in-app
"update helper" prompt when the helper changes).

## Usage

1. Launch the app — a network icon appears in the menu bar.
2. On first launch it offers to install the helper (one admin prompt).
3. Import tunnels via **Import Tunnel(s) from File…** (multiple `.conf` files
   at once) or the **+** button in **Manage Tunnels**.
4. Click a tunnel name in the menu to activate it; click the active one (or
   **Deactivate**) to disconnect. Activating another tunnel switches directly.
5. **Manage Tunnels** shows interface/peer details, live handshake and transfer
   stats, and lets you edit, rename (Rename… button or right-click a tunnel in
   the list), or delete configs.
6. **Block Traffic Outside the Tunnel** (on by default) decides what happens to
   traffic that would bypass a full tunnel (`0.0.0.0/0` / `::/0`): connections
   opened before connecting, and sockets bound to Wi-Fi/Ethernet. On, the helper
   rejects it with pf (TCP reset, UDP port-unreachable) so apps reconnect through
   the tunnel within seconds; the local subnet, multicast, DHCP and the endpoint
   stay reachable. Off, those connections keep running outside the tunnel until
   they close. Either way the helper adds a default route scoped to the physical
   interface: without it, macOS drops such packets as unroutable and apps hang for
   20–30 s after connecting.

Switching directly from one active tunnel to another performs a **make-before-break
handover**: the incoming tunnel is fully brought up on its own interface while the
outgoing one keeps carrying traffic, then routing and DNS are flipped over in one
step and the old tunnel is retired. This shrinks the connectivity gap to a routing
change (milliseconds). Note that existing TCP connections still reset on a switch —
the two tunnels have different source addresses and servers, so established sessions
cannot be carried across; this is inherent to switching between distinct tunnels and
is true of the official client as well.

Supported config options: `PrivateKey`, `Address`, `DNS` (servers and search
domains), `MTU`, `ListenPort`, `PublicKey`, `PresharedKey`, `AllowedIPs`,
`Endpoint`, `PersistentKeepalive`. `PreUp`/`PostUp`/`PreDown`/`PostDown`
scripts are deliberately **not** executed (the helper runs as root) and are
ignored with a warning.

## Updating & uninstalling

**Update:**

```sh
brew upgrade --cask wg-client
```

Homebrew quits the app, unloads and removes the old privileged helper, and installs
the new app (one admin prompt for the helper files). Your **tunnel configs are
preserved** (they live in `/Library/Application Support/WGClient`, which upgrades
don't touch). On next launch the app reinstalls its helper — expected, since the
helper version changed.

**Uninstall (keeps tunnel configs):**

```sh
brew uninstall --cask wg-client
```

This quits the app, unloads the root LaunchDaemon (`launchctl`), and deletes the
LaunchDaemon plist and `/Library/PrivilegedHelperTools/WGClient` (one admin prompt).
No background service is left behind.

**Full removal, including stored tunnel configs (private keys), logs, and prefs:**

```sh
brew uninstall --zap --cask wg-client
```

The `--zap` additionally removes `/Library/Application Support/WGClient`,
`/var/log/wg-client-helper.log`, the runtime socket/state under `/var/run`, and the
app's user preferences.

**Manual uninstall** (for a non-Homebrew install, e.g. a locally built `.app`):

```sh
sudo sh "/Applications/WG Client.app/Contents/Resources/uninstall-helper.sh"          # keep configs
sudo sh "/Applications/WG Client.app/Contents/Resources/uninstall-helper.sh" --purge  # remove configs too
```

Then drag the app to the Trash.

## Troubleshooting

- Helper log: **View Log** in the menu-bar menu or the ••• menu in Manage Tunnels
  (or read `/var/log/wg-client-helper.log` directly; it includes wireguard-go output)
- Helper status: `sudo launchctl print system/com.github.jkbennemann.wg-client.helper`
- Live tunnel state: the active `utun` shows up in `ifconfig`; the UAPI socket
  lives at `/var/run/wireguard/<utun>.sock`
- `swift run WireGuardClient` works for UI development, but helper
  installation needs the full bundle from `scripts/build-app.sh` (the helper
  binary and `wireguard-go` are bundle resources).

## Connect/disconnect performance

Early versions shelled out to `networksetup` to set DNS, which spawns one process
per network service per operation — ~44 subprocesses on connect (≈0.7–1.5s of
pure overhead) and more on disconnect. DNS is now written directly to the
SystemConfiguration dynamic store in-process (instant), peer endpoints are
resolved once instead of twice, and the wireguard-go startup / process-teardown
waits poll at 5–10ms instead of 100ms granularity. Route installation is done
concurrently, wireguard-go is spawned first so its utun-creation latency overlaps
other setup work, and switching tunnels uses a make-before-break handover (see
Usage). Connect and disconnect are now dominated by the WireGuard handshake and
process spawn rather than system-config plumbing, close to the official client.

Subprocesses (ifconfig/route) are spawned with `posix_spawn` rather than
Foundation's `Process`, which cost ~70-80ms per spawn (dispatch sources, KVO, a
reaper thread) — and more under the daemon's scheduling — versus ~2-3ms for
`posix_spawn`. This was the single largest remaining cost once DNS was fixed:
"configure interface" alone was ~700ms across four ifconfig spawns. The daemon
also runs at the `Interactive` launchd scheduling tier so connect/disconnect isn't
subject to background QoS throttling.

The helper logs a per-phase timing breakdown for every activation to
`/var/log/wg-client-helper.log` (look for the `↳` lines), so remaining
latency can be attributed precisely.

The UI reacts immediately to interaction: activate/deactivate show an
"Activating…/Deactivating…" state at once, and add/remove/rename update the tunnel
list optimistically before the helper round-trip completes.

## Known limitations

- After switching tunnels or disconnecting, connections opened through the
  previous tunnel keep its now-gone address and hang until the app times them
  out (typically 10–30 s for WebSockets and Node apps). Chromium-based apps drop
  their pooled HTTP connections right away, since the helper announces each change.
- No on-demand activation.
