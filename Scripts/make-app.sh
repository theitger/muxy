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
    tmp="$(mktemp -d)"
    swift "$REPO/Scripts/make-icon.swift" "$tmp/AppIcon.iconset"
    iconutil -c icns "$tmp/AppIcon.iconset" -o "$ICNS"
fi

echo "[muxy] assembling bundle …"
mkdir -p "$APP_DIR"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$REPO/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$REPO/.build/release/muxy" "$APP/Contents/MacOS/muxy"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# macOS 26 dark icon style: ship a real dark variant (Icon Composer source,
# compiled by Xcode's actool) — otherwise the system tints the icon itself.
if xcrun --find actool >/dev/null 2>&1 && [ -d "$REPO/Packaging/AppIcon.icon" ]; then
    tmp_assets="$(mktemp -d)"
    if xcrun actool "$REPO/Packaging/AppIcon.icon" --compile "$tmp_assets" \
        --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
        --output-partial-info-plist "$tmp_assets/partial.plist" >/dev/null 2>&1; then
        cp "$tmp_assets/Assets.car" "$APP/Contents/Resources/"
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
    else
        echo "[muxy] note: actool failed — light icon only"
    fi
    rm -rf "$tmp_assets"
fi


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
