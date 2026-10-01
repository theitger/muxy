#!/usr/bin/env bash
# Adds muxy's agent hooks (UserPromptSubmit + Stop + Notification) to Claude Code's
# settings. Idempotent; existing hooks are left untouched. The hook is a
# no-op for claude sessions running outside muxy.
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
# settings.json is often a symlink into a dotfiles repo — follow it.
if [ -L "$SETTINGS" ]; then
    SETTINGS="$(readlink -f "$SETTINGS")"
fi
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claude-hook.sh"

python3 - "$SETTINGS" "$HOOK" <<'PY'
import json, os, sys
path, hook = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
hooks = data.setdefault("hooks", {})
changed = False
for event, arg in (("UserPromptSubmit", "prompt"), ("Stop", "stop"), ("Notification", "notify")):
    entries = hooks.setdefault(event, [])
    if not any("claude-hook.sh" in h.get("command", "")
               for e in entries for h in e.get("hooks", [])):
        entries.append({"hooks": [{"type": "command", "command": f"{hook} {arg}"}]})
        changed = True
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print("claude hooks " + ("installiert" if changed else "schon vorhanden"))
PY
