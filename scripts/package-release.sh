#!/bin/bash
# Builds, signs (Developer ID), notarizes, staples, and zips WG Client.app for a
# Homebrew Cask release, then prints the cask fields (version + sha256).
#
# Usage:
#   scripts/package-release.sh <version>
#   scripts/package-release.sh 0.0.1
#
# Required environment:
#   CODESIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#
# Notarization credentials — either a stored notarytool keychain profile:
#   NOTARY_PROFILE      name of a profile created with:
#                       xcrun notarytool store-credentials wg-client-notary \
#                           --apple-id you@example.com --team-id TEAMID \
#                           --password <app-specific-password>
# …or pass them directly:
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: $0 <version>   (e.g. $0 0.0.1)" >&2
    exit 1
fi
: "${CODESIGN_IDENTITY:?Set CODESIGN_IDENTITY to your Developer ID Application identity}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DIST="$REPO_ROOT/dist"
APP="$DIST/WG Client.app"
ZIP="$DIST/WG-Client-$VERSION.zip"

# --- Build + sign with the Developer ID identity ----------------------------
WG_VERSION="$VERSION" CODESIGN_IDENTITY="$CODESIGN_IDENTITY" "$REPO_ROOT/scripts/build-app.sh"

# --- Notarize ----------------------------------------------------------------
# notarytool wants a zip (or dmg/pkg). Zip the app, submit, then staple the
# .app itself and re-zip for distribution.
echo "==> Zipping for notarization"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary service (this can take a few minutes)"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
else
    : "${NOTARY_APPLE_ID:?Set NOTARY_PROFILE or NOTARY_APPLE_ID/NOTARY_TEAM_ID/NOTARY_PASSWORD}"
    : "${NOTARY_TEAM_ID:?Set NOTARY_TEAM_ID}"
    : "${NOTARY_PASSWORD:?Set NOTARY_PASSWORD (app-specific password)}"
    xcrun notarytool submit "$ZIP" \
        --apple-id "$NOTARY_APPLE_ID" \
        --team-id "$NOTARY_TEAM_ID" \
        --password "$NOTARY_PASSWORD" \
        --wait
fi

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Re-zipping stapled app for distribution"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

echo ""
echo "=============================================================="
echo "Release artifact: $ZIP"
echo "sha256:           $SHA"
echo ""
echo "Cask fields for Casks/wg-client.rb:"
echo "  version \"$VERSION\""
echo "  sha256 \"$SHA\""
echo ""
echo "Next:"
echo "  1. gh release create v$VERSION \"$ZIP\" --repo jkbennemann/wg-client --title \"v$VERSION\" --generate-notes"
echo "  2. Update Casks/wg-client.rb in jkbennemann/homebrew-tap with the version + sha256 above."
echo "=============================================================="