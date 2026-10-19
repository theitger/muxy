#!/usr/bin/env bash
# Builds Muxy.app (release) into ~/Applications.
#
# Environment:
#   MUXY_APP_DIR         where Muxy.app goes (default: ~/Applications)
#   MUXY_SIGN_IDENTITY   a "Developer ID Application: …" identity: signs with
#                        the hardened runtime and a secure timestamp.
#                        Unset: ad-hoc signature, as for local builds.
#   MUXY_NOTARY_PROFILE  a notarytool keychain profile (see
#                        `xcrun notarytool store-credentials`): notarizes
#                        and staples. Needs MUXY_SIGN_IDENTITY.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${MUXY_APP_DIR:-$HOME/Applications}"
APP="$APP_DIR/Muxy.app"
ICNS="$REPO/Packaging/AppIcon.icns"
IDENTITY="${MUXY_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${MUXY_NOTARY_PROFILE:-}"

if [ -n "$NOTARY_PROFILE" ] && [ -z "$IDENTITY" ]; then
    echo "[muxy] MUXY_NOTARY_PROFILE needs MUXY_SIGN_IDENTITY: Apple only notarizes Developer ID builds." >&2
    exit 1
fi

if [ ! -d "$REPO/Vendor/libghostty-spm/GhosttyKit.xcframework" ]; then
    "$REPO/Scripts/fetch-ghostty.sh"
fi
"$REPO/Scripts/fetch-sparkle.sh" >/dev/null

echo "[muxy] release build …"
swift build -c release --package-path "$REPO"

# The phone app (Settings → Phone), served by Muxy itself.
REMOTE="$REPO/Prototypes/remote"
if command -v pnpm >/dev/null 2>&1; then
    echo "[muxy] phone app …"
    (cd "$REMOTE" && pnpm install --frozen-lockfile --silent && pnpm build >/dev/null)
else
    echo "[muxy] note: pnpm not found — built without the phone app"
fi

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
# The agent hook; muxy copies it to ~/.local/share/muxy on install.
cp "$REPO/Scripts/agent-hook.sh" "$APP/Contents/Resources/agent-hook.sh"
# The `muxy` command; Settings links it onto your PATH.
mkdir -p "$APP/Contents/Resources/bin"
cp "$REPO/Scripts/muxy" "$APP/Contents/Resources/bin/muxy"
chmod 755 "$APP/Contents/Resources/bin/muxy"
if [ -f "$REMOTE/dist/index.html" ]; then
    cp "$REMOTE/dist/index.html" "$APP/Contents/Resources/remote.html"
fi

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

# Sparkle, for self-updates. ditto keeps the framework's symlinks.
mkdir -p "$APP/Contents/Frameworks"
ditto "$REPO/Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" \
    "$APP/Contents/Frameworks/Sparkle.framework"
cp "$REPO/Vendor/Sparkle/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
cp "$REPO/Packaging/Licenses/Lucide-LICENSE" "$APP/Contents/Resources/Lucide-LICENSE.txt"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/muxy"

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ -n "$IDENTITY" ]; then
    echo "[muxy] signing as $IDENTITY …"
    # Inside out, never --deep: Sparkle's helpers each need their own
    # signature (sparkle-project.org/documentation/sandboxing).
    sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
    sign "$SPARKLE/XPCServices/Installer.xpc"
    sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
    sign "$SPARKLE/Autoupdate"
    sign "$SPARKLE/Updater.app"
    sign "$APP/Contents/Frameworks/Sparkle.framework"
    sign --entitlements "$REPO/Packaging/Muxy.entitlements" "$APP"
else
    # Sparkle ships ad-hoc signed already; the app's own signature seals it.
    codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

if [ -n "$NOTARY_PROFILE" ]; then
    echo "[muxy] notarizing (takes a few minutes) …"
    tmp_zip="$(mktemp -d)/Muxy.zip"
    ditto -c -k --keepParent "$APP" "$tmp_zip"
    result="$(xcrun notarytool submit "$tmp_zip" --keychain-profile "$NOTARY_PROFILE" \
        --wait --output-format json)" || true
    rm -f "$tmp_zip"
    id="$(echo "$result" | plutil -extract id raw -o - - 2>/dev/null || true)"
    status="$(echo "$result" | plutil -extract status raw -o - - 2>/dev/null || true)"
    if [ "$status" != "Accepted" ]; then
        echo "[muxy] notarization failed (${status:-no status}). Details:" >&2
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || echo "$result" >&2
        exit 1
    fi
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose "$APP"
fi

echo "[muxy] done: $APP"
