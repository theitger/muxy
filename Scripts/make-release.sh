#!/usr/bin/env bash
# Builds Muxy.app, zips it for a GitHub release and signs the update feed.
# Output: dist/Muxy-<version>.zip and dist/appcast.xml (+ sha256 on stdout).
# Upload both to the release: installed copies read the feed from
# https://github.com/theitger/muxy/releases/latest/download/appcast.xml.
#
# Environment (besides make-app.sh's MUXY_SIGN_IDENTITY, MUXY_NOTARY_PROFILE
# and MUXY_APP_DIR):
#   MUXY_ED_KEY_FILE          private EdDSA key file instead of the keychain
#   MUXY_DOWNLOAD_URL_PREFIX  where the zip will live (default: the release)
#   MUXY_PREVIOUS_APPCAST     the feed to extend (default: the latest release's)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$REPO/Packaging/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null || true)"
FEED="https://github.com/theitger/muxy/releases/latest/download/appcast.xml"
PREFIX="${MUXY_DOWNLOAD_URL_PREFIX:-https://github.com/theitger/muxy/releases/download/v$VERSION/}"
PREVIOUS="${MUXY_PREVIOUS_APPCAST:-$FEED}"

# A release without the key would ship an app that can never update itself.
if [ -z "$KEY" ]; then
    echo "No update signing key: SUPublicEDKey in Packaging/Info.plist is empty." >&2
    echo "Run Scripts/setup-updates.sh once, commit Info.plist, then release again." >&2
    exit 1
fi

# generate_appcast reads every archive in its folder, so it gets a clean one
# with just this release and the current feed, whose older entries it keeps.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
case "$PREVIOUS" in
    http*://*)
        if ! curl -sL --fail "$PREVIOUS" -o "$work/appcast.xml"; then
            rm -f "$work/appcast.xml"
            echo "note: no previous feed at $PREVIOUS, starting a new one"
        fi ;;
    *) [ -f "$PREVIOUS" ] && cp "$PREVIOUS" "$work/appcast.xml" ;;
esac
if [ -f "$work/appcast.xml" ] && grep -q "<sparkle:version>$BUILD</sparkle:version>" "$work/appcast.xml"; then
    echo "Build $BUILD is already in the feed: bump CFBundleVersion in Packaging/Info.plist." >&2
    exit 1
fi

"$REPO/Scripts/make-app.sh"
APP="${MUXY_APP_DIR:-$HOME/Applications}/Muxy.app"

DIST="$REPO/dist"
mkdir -p "$DIST"
ZIP="$DIST/Muxy-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
cp "$ZIP" "$work/"

key_args=()
[ -n "${MUXY_ED_KEY_FILE:-}" ] && key_args=(--ed-key-file "$MUXY_ED_KEY_FILE")
"$REPO/Vendor/Sparkle/bin/generate_appcast" "${key_args[@]+"${key_args[@]}"}" \
    --download-url-prefix "$PREFIX" \
    --link "https://github.com/theitger/muxy" \
    "$work"

if ! grep -q 'sparkle:edSignature=' "$work/appcast.xml"; then
    echo "The feed came out without an EdDSA signature." >&2
    exit 1
fi
cp "$work/appcast.xml" "$DIST/appcast.xml"

echo "release: $ZIP"
echo "feed:    $DIST/appcast.xml"
shasum -a 256 "$ZIP"
echo "publish: gh release create v$VERSION '$ZIP' '$DIST/appcast.xml' --title 'muxy $VERSION'"
