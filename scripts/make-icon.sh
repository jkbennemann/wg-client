#!/bin/bash
# Generates Resources/AppIcon.icns from scripts/make-icon.swift.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MASTER="$WORK/icon_1024.png"
swift "$REPO_ROOT/scripts/make-icon.swift" "$MASTER"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16   16   "$MASTER" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32   32   "$MASTER" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32   32   "$MASTER" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64   64   "$MASTER" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128  128  "$MASTER" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256  256  "$MASTER" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256  256  "$MASTER" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512  512  "$MASTER" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512  512  "$MASTER" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$MASTER" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$REPO_ROOT/Resources/AppIcon.icns"
echo "wrote Resources/AppIcon.icns"
