#!/usr/bin/env bash
# Downloads the pinned Sparkle release (update framework + its signing tools)
# into Vendor/Sparkle. Needed once after a fresh clone, like fetch-ghostty.sh:
# SwiftPM's artifact downloader has hung for this project before, so the
# binary comes from here, checksum-verified, instead of a remote package.
set -euo pipefail

VERSION="2.10.0"
SHA256="17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
URL="https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-for-Swift-Package-Manager.zip"
DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Vendor/Sparkle"

if [ -d "$DEST/Sparkle.xcframework" ] && [ "$(cat "$DEST/VERSION" 2>/dev/null)" = "$VERSION" ]; then
    echo "Sparkle $VERSION already present."
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Downloading $URL …"
curl -sL --fail "$URL" -o "$tmp/sparkle.zip"
echo "$SHA256  $tmp/sparkle.zip" | shasum -a 256 -c - >/dev/null
rm -rf "$DEST"
mkdir -p "$DEST"
# ditto keeps the framework's symlinks and the tools' executable bits.
ditto -x -k "$tmp/sparkle.zip" "$DEST"
echo "$VERSION" > "$DEST/VERSION"
echo "OK: $DEST (Sparkle.xcframework, bin/)"
