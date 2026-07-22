#!/bin/bash
# Builds the WG Client.app bundle into dist/.
# Requires: Xcode Command Line Tools. Go is only needed if wireguard-go
# is not already available via Homebrew or a previous build.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DIST="$REPO_ROOT/dist"
DEPS="$DIST/deps"
APP="$DIST/WG Client.app"
WGGO_VERSION="master"

mkdir -p "$DEPS"

# --- 1. Obtain wireguard-go -------------------------------------------------
if [ ! -x "$DEPS/wireguard-go" ]; then
    if command -v wireguard-go >/dev/null 2>&1; then
        echo "==> Using wireguard-go from $(command -v wireguard-go)"
        cp "$(command -v wireguard-go)" "$DEPS/wireguard-go"
    elif [ -x "/opt/homebrew/bin/wireguard-go" ]; then
        echo "==> Using wireguard-go from /opt/homebrew/bin"
        cp /opt/homebrew/bin/wireguard-go "$DEPS/wireguard-go"
    else
        if ! command -v go >/dev/null 2>&1; then
            echo "error: wireguard-go not found and Go is not installed." >&2
            echo "Install one of them first:  brew install wireguard-go   or   brew install go" >&2
            exit 1
        fi
        echo "==> Building wireguard-go from source ($WGGO_VERSION)"
        SRC="$REPO_ROOT/.build/wireguard-go-src"
        if [ ! -d "$SRC" ]; then
            git clone --depth 1 --branch "$WGGO_VERSION" https://git.zx2c4.com/wireguard-go "$SRC"
        fi
        (cd "$SRC" && go build -trimpath -ldflags "-s -w" -o "$DEPS/wireguard-go" .)
    fi
    chmod 755 "$DEPS/wireguard-go"
fi

# --- 2. Build Swift targets -------------------------------------------------
echo "==> Building Swift targets (release)"
swift build -c release

BIN="$(swift build -c release --show-bin-path)"

# --- 3. Assemble the .app bundle --------------------------------------------
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/WireGuardClient" "$APP/Contents/MacOS/WireGuardClient"
cp "$BIN/wireguard-client-helper" "$APP/Contents/Resources/"
cp "$DEPS/wireguard-go" "$APP/Contents/Resources/"
cp "$REPO_ROOT/Resources/install-helper.sh" "$APP/Contents/Resources/"
cp "$REPO_ROOT/Resources/uninstall-helper.sh" "$APP/Contents/Resources/"
cp "$REPO_ROOT/Resources/com.github.jkbennemann.wg-client.helper.plist" "$APP/Contents/Resources/"
cp "$REPO_ROOT/Resources/Info.plist" "$APP/Contents/"

# App icon (generate if missing).
if [ ! -f "$REPO_ROOT/Resources/AppIcon.icns" ]; then
    "$REPO_ROOT/scripts/make-icon.sh"
fi
cp "$REPO_ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# Stamp the version (WG_VERSION overrides the value in Resources/Info.plist).
VERSION="${WG_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO_ROOT/Resources/Info.plist")}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
echo "==> Version $VERSION"

# --- 4. Sign -----------------------------------------------------------------
# Ad-hoc signature by default (fine for local runs). For distribution, set
# CODESIGN_IDENTITY to a "Developer ID Application: …" certificate; a secure
# timestamp (required for notarization) is added automatically in that case.
# Sign inside-out: nested Mach-O binaries first, then the app bundle.
IDENTITY="${CODESIGN_IDENTITY:--}"
TS_FLAG="--timestamp=none"
if [ "$IDENTITY" != "-" ]; then TS_FLAG="--timestamp"; fi
echo "==> Codesigning (identity: $IDENTITY)"
for bin in \
    "$APP/Contents/Resources/wireguard-client-helper" \
    "$APP/Contents/Resources/wireguard-go" \
    "$APP/Contents/MacOS/WireGuardClient" \
    "$APP"; do
    codesign --force --options runtime $TS_FLAG --sign "$IDENTITY" "$bin"
done

if [ "$IDENTITY" != "-" ]; then
    echo "==> Verifying signature"
    codesign --verify --deep --strict --verbose=2 "$APP"
fi

echo ""
echo "Done: $APP"
echo "Move it to /Applications and launch it. The first run installs the helper (admin prompt)."
