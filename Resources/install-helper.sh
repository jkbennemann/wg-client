#!/bin/sh
# Installs the wireguard-client privileged helper daemon.
# Usage: install-helper.sh <helper-binary> <wireguard-go-binary> <launchd-plist>
set -eu

HELPER="$1"
WGGO="$2"
PLIST="$3"

LABEL="com.github.jkbennemann.wg-client.helper"
DEST="/Library/PrivilegedHelperTools/WGClient"

launchctl bootout "system/$LABEL" 2>/dev/null || true

mkdir -p "$DEST"
# Replace binaries by rename, never in place: an active tunnel's wireguard-go keeps
# running across a helper upgrade, and rewriting its executable under it can get it
# killed for an invalid code signature. A rename leaves the running inode untouched.
cp -f "$HELPER" "$DEST/wireguard-client-helper.new"
cp -f "$WGGO" "$DEST/wireguard-go.new"
mv -f "$DEST/wireguard-client-helper.new" "$DEST/wireguard-client-helper"
mv -f "$DEST/wireguard-go.new" "$DEST/wireguard-go"
chown -R root:wheel "$DEST"
chmod 755 "$DEST" "$DEST/wireguard-client-helper" "$DEST/wireguard-go"

cp -f "$PLIST" "/Library/LaunchDaemons/$LABEL.plist"
chown root:wheel "/Library/LaunchDaemons/$LABEL.plist"
chmod 644 "/Library/LaunchDaemons/$LABEL.plist"

mkdir -p "/Library/Application Support/WGClient/tunnels"
chown -R root:wheel "/Library/Application Support/WGClient"
chmod 700 "/Library/Application Support/WGClient/tunnels"

# Homebrew quarantines what it downloads, and copying out of the app bundle carries the
# flag along (copyfile propagates it even with `cp -X`). launchd on macOS 27+ refuses a
# daemon whose plist or program is quarantined: "Bootstrap failed: 5: Input/output error".
for f in "$DEST/wireguard-client-helper" "$DEST/wireguard-go" "/Library/LaunchDaemons/$LABEL.plist"; do
    xattr -d com.apple.quarantine "$f" 2>/dev/null || true
done

launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist"
echo "Helper installed."
