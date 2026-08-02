#!/usr/bin/env bash
# Builds Muxy.app and zips it for a GitHub release.
# Output: dist/Muxy-<version>.zip (+ sha256 on stdout)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO/Packaging/Info.plist")"

"$REPO/Scripts/make-app.sh"

DIST="$REPO/dist"
mkdir -p "$DIST"
ZIP="$DIST/Muxy-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$HOME/Applications/Muxy.app" "$ZIP"
echo "release: $ZIP"
shasum -a 256 "$ZIP"
