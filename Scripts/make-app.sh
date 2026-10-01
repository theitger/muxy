#!/usr/bin/env bash
# Builds Muxy.app (release) into ~/Applications.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/Muxy.app"
ICNS="$REPO/Packaging/AppIcon.icns"

if [ ! -d "$REPO/Vendor/libghostty-spm/GhosttyKit.xcframework" ]; then
    "$REPO/Scripts/fetch-ghostty.sh"
fi

echo "[muxy] release build …"
swift build -c release --package-path "$REPO"

if [ ! -f "$ICNS" ]; then
    echo "[muxy] rendering icon …"
    tmp="$(mktemp -d)/AppIcon.iconset"
    swift "$REPO/Scripts/make-icon.swift" "$tmp"
    iconutil -c icns "$tmp" -o "$ICNS"
fi

echo "[muxy] assembling bundle …"
mkdir -p "$APP_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$REPO/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$REPO/.build/release/muxy" "$APP/Contents/MacOS/muxy"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# Ghostty's shell integration + terminfo, so muxy doesn't depend on an
# installed Ghostty.app at runtime. Same layout as Ghostty.app.
GHOSTTY_RES="/Applications/Ghostty.app/Contents/Resources"
if [ -d "$GHOSTTY_RES/ghostty/shell-integration" ]; then
    mkdir -p "$APP/Contents/Resources/ghostty"
    cp -R "$GHOSTTY_RES/ghostty/shell-integration" "$APP/Contents/Resources/ghostty/"
    cp -R "$GHOSTTY_RES/terminfo" "$APP/Contents/Resources/"
else
    echo "[muxy] note: Ghostty.app not found — built without bundled shell integration"
fi
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "[muxy] done: $APP"
