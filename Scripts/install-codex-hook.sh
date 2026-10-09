#!/usr/bin/env bash
# Adds muxy's agent hooks to Codex (~/.codex/hooks.json). Idempotent: muxy's
# own entries are replaced on every run, everything else is left untouched.
# The hook is a no-op for codex sessions running outside muxy.
#
# Codex runs a new hook only once you trust it: open codex, type /hooks and
# trust muxy's entries (once, and again after this script changed them).
set -euo pipefail

HOOKS="${CODEX_HOME:-$HOME/.codex}/hooks.json"
# ~/.codex is often a symlink into a dotfiles repo; follow a linked file.
if [ -L "$HOOKS" ]; then
    HOOKS="$(readlink -f "$HOOKS")"
fi
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-hook.sh"

python3 - "$HOOKS" "$HOOK" <<'PY'
import json, os, sys
path, hook = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
hooks = data.setdefault("hooks", {})

# (event, argument): what each means to muxy.
WANTED = [
    ("SessionStart", "start"),
    ("UserPromptSubmit", "prompt"),
    ("PreToolUse", "tool"),
    ("PostToolUse", "tool"),
    ("PermissionRequest", "notify"),
    ("Interrupt", "idle"),
    ("Stop", "stop"),
]

before = json.dumps(hooks, sort_keys=True)
for event in list(hooks):
    kept = []
    for entry in hooks[event]:
        entry["hooks"] = [h for h in entry.get("hooks", [])
                          if "agent-hook.sh" not in h.get("command", "")]
        if entry["hooks"]:
            kept.append(entry)
    hooks[event] = kept
for event, arg in WANTED:
    hooks.setdefault(event, []).append(
        {"hooks": [{"type": "command", "command": f"{hook} {arg} codex", "timeout": 10}]}
    )
for event in [e for e, entries in hooks.items() if not entries]:
    del hooks[event]

changed = json.dumps(hooks, sort_keys=True) != before
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print("codex hooks " + ("updated: trust them once with /hooks in codex" if changed else "already up to date"))
PY
