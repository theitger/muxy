#!/usr/bin/env bash
# Downloads the pinned GhosttyKit XCFramework into the vendored package.
# Needed once after a fresh clone (the ~50 MB binary is not committed).
set -euo pipefail

VERSION="storage.1.3.2"
SHA256="9dcfaa1958a53b42b454728bbcc62c1be5a63f1537978aee85ce6607eecb57c6"
URL="https://github.com/Lakr233/libghostty-spm/releases/download/$VERSION/GhosttyKit.xcframework.zip"
DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Vendor/libghostty-spm"

if [ -d "$DEST/GhosttyKit.xcframework" ]; then
    echo "GhosttyKit.xcframework ist schon da."
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Lade $URL …"
curl -sL --fail "$URL" -o "$tmp/ghostty.zip"
echo "$SHA256  $tmp/ghostty.zip" | shasum -a 256 -c - >/dev/null
unzip -q "$tmp/ghostty.zip" -d "$DEST"
echo "OK: $DEST/GhosttyKit.xcframework"
