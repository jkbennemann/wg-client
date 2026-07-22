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
cp -f "$HELPER" "$DEST/wireguard-client-helper"
cp -f "$WGGO" "$DEST/wireguard-go"
chown -R root:wheel "$DEST"
chmod 755 "$DEST" "$DEST/wireguard-client-helper" "$DEST/wireguard-go"

cp -f "$PLIST" "/Library/LaunchDaemons/$LABEL.plist"
chown root:wheel "/Library/LaunchDaemons/$LABEL.plist"
chmod 644 "/Library/LaunchDaemons/$LABEL.plist"

mkdir -p "/Library/Application Support/WGClient/tunnels"
chown -R root:wheel "/Library/Application Support/WGClient"
chmod 700 "/Library/Application Support/WGClient/tunnels"

launchctl bootstrap system "/Library/LaunchDaemons/$LABEL.plist"
echo "Helper installed."
