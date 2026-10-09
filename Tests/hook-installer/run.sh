#!/usr/bin/env bash
# Tests HookInstaller (the JSON merge behind Settings → Agents) in scratch
# homes, and checks it means the same JSON as Scripts/install-claude-hook.sh
# and install-codex-hook.sh. Never touches your real ~/.claude or ~/.codex.
#
# Usage: Tests/hook-installer/run.sh [<scratch dir>] [<json file to round-trip, read only> …]
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="${1:-$(mktemp -d)}"
shift || true
mkdir -p "$SCRATCH"
BIN="$SCRATCH/hook-installer-test"
swiftc -O -o "$BIN" "$REPO/Sources/muxy/HookInstaller.swift" "$REPO/Tests/hook-installer/main.swift"
"$BIN" "$SCRATCH/cases" "$@"

# The shell installers on the same input; they copy the script to the same
# stable path the app uses.
compare() { # <agent> <installer> <input json or ""> <swift result>
    local home="$SCRATCH/shell-$1"
    rm -rf "$home"
    mkdir -p "$home/.claude" "$home/.codex"
    local file="$home/.claude/settings.json"
    [ "$1" = codex ] && file="$home/.codex/hooks.json"
    [ -n "$3" ] && cp "$3" "$file"
    HOME="$home" CODEX_HOME="$home/.codex" bash "$REPO/Scripts/$2" >/dev/null
    cmp -s "$REPO/Scripts/agent-hook.sh" "$home/.local/share/muxy/agent-hook.sh" \
        && [ -x "$home/.local/share/muxy/agent-hook.sh" ] \
        || { echo "FAIL $2 did not copy agent-hook.sh"; exit 1; }
    # Same JSON once the scratch home in each path is the same.
    python3 - "$file" "$4" "$home" "$5" <<'PY'
import json, sys
a = open(sys.argv[1]).read().replace(sys.argv[3], "HOME")
b = open(sys.argv[2]).read().replace(sys.argv[4], "HOME")
same = json.loads(a) == json.loads(b)
print(("ok   " if same else "FAIL ") + "same JSON as the shell installer: " + sys.argv[2])
sys.exit(0 if same else 1)
PY
}
compare claude install-claude-hook.sh "$SCRATCH/cases/busy-python.json" "$SCRATCH/cases/busy/.claude/settings.json" "$SCRATCH/cases/busy"
compare claude install-claude-hook.sh "" "$SCRATCH/cases/fresh/.claude/settings.json" "$SCRATCH/cases/fresh"
compare codex install-codex-hook.sh "" "$SCRATCH/cases/linked/.codex/hooks.json" "$SCRATCH/cases/linked"
