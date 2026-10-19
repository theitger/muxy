#!/usr/bin/env bash
# One-time setup for self-updates: creates the EdDSA key that signs every
# release (the private half stays in your login keychain) and writes the
# public half into Packaging/Info.plist. Run it again any time: an existing
# key is reused, never replaced.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$REPO/Packaging/Info.plist"
"$REPO/Scripts/fetch-sparkle.sh" >/dev/null
BIN="$REPO/Vendor/Sparkle/bin"

current="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null || true)"

# Creates the key, or finds the one already in the keychain. macOS may ask
# to allow keychain access.
"$BIN/generate_keys" >/dev/null
key="$("$BIN/generate_keys" -p)"

if [ -n "$current" ] && [ "$current" != "$key" ]; then
    cat >&2 <<MSG
Info.plist already has a different public key:
  Info.plist: $current
  keychain:   $key
Installed copies only accept updates signed with the key in Info.plist.
Import that private key (generate_keys -f <file>) instead of replacing it.
MSG
    exit 1
fi

/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $key" "$PLIST"
cat <<MSG
Public key in Packaging/Info.plist: $key
Commit that change.

Back up the private key now, somewhere safe (a password manager):
  $BIN/generate_keys -x ~/Desktop/muxy-update-key.txt
Without it no installed Muxy can be updated again; delete the file once stored.
MSG
