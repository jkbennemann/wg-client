#!/bin/sh
# Removes the wireguard-client privileged helper daemon.
# Run with: sudo sh uninstall-helper.sh [--purge]
#   --purge also deletes stored tunnel configurations.
set -eu

LABEL="com.github.jkbennemann.wg-client.helper"

launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist"
rm -rf "/Library/PrivilegedHelperTools/WGClient"
rm -f /var/run/wg-client.sock
rm -rf /var/run/wg-client

if [ "${1:-}" = "--purge" ]; then
    rm -rf "/Library/Application Support/WGClient"
    echo "Helper and tunnel configurations removed."
else
    echo "Helper removed. Tunnel configs kept in /Library/Application Support/WGClient (use --purge to delete)."
fi
