#!/usr/bin/env bash
# A debug app with its own bundle identity, state and sessions. No installed
# build or existing development process is replaced. --build-only assembles it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO/.build/Muxy Dev.app"
swift build --package-path "$REPO"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$REPO/Packaging/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.theitger.muxy.dev' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Muxy Dev' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Muxy Dev' "$APP/Contents/Info.plist"
cp "$REPO/.build/debug/muxy" "$APP/Contents/MacOS/muxy"
cp -R "$REPO/.build/debug/muxy_muxy.bundle" "$APP/Contents/Resources/"
cp "$REPO/Packaging/AppIcon.icns" "$APP/Contents/Resources/"
cp "$REPO/Scripts/agent-hook.sh" "$APP/Contents/Resources/"
# Serve the same phone frontend being tested in this checkout.
pnpm --dir "$REPO/Prototypes/remote" build
cp "$REPO/Prototypes/remote/dist/index.html" "$APP/Contents/Resources/remote.html"
mkdir -p "$APP/Contents/Resources/bin"
cp "$REPO/Scripts/muxy" "$APP/Contents/Resources/bin/"
ditto "$REPO/.build/debug/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/muxy"
codesign --force --sign - "$APP"
printf 'Dev app: %s\n' "$APP"
if [ "${1:-}" != "--build-only" ]; then
    open "$APP" --env "MUXY_STATE_DIR=$REPO/.build/dev-state" \
        --stdout "$REPO/.build/dev-app.log" --stderr "$REPO/.build/dev-app.log"
fi
