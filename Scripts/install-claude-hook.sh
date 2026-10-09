#!/usr/bin/env bash
# Adds muxy's agent hooks to Claude Code's settings, as the app does from
# Settings → Agents. Idempotent: muxy's own entries are replaced on every
# run (so updates reach existing installs), everything else is left
# untouched. The hook is a no-op for claude sessions running outside muxy.
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
# settings.json is often a symlink into a dotfiles repo — follow it.
if [ -L "$SETTINGS" ]; then
    SETTINGS="$(readlink -f "$SETTINGS")"
fi
# The same stable copy the app installs (Settings → Agents), so moving or
# deleting this checkout never breaks the agent's settings.
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-hook.sh"
HOOK="$HOME/.local/share/muxy/agent-hook.sh"
if [ "$SOURCE" != "$HOOK" ]; then
    mkdir -p "$(dirname "$HOOK")"
    cp "$SOURCE" "$HOOK.tmp" && chmod 755 "$HOOK.tmp" && mv "$HOOK.tmp" "$HOOK"
fi

python3 - "$SETTINGS" "$HOOK" <<'PY'
import json, os, sys
path, hook = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
hooks = data.setdefault("hooks", {})

# (event, matcher, argument). Notification types not listed (auth_success,
# agent_completed, quota_*, …) say nothing about whether Claude needs you.
WANTED = [
    ("SessionStart", None, "start"),
    ("UserPromptSubmit", None, "prompt"),
    ("PreToolUse", None, "tool"),
    ("Notification", "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input", "notify"),
    ("Notification", "idle_prompt", "idle"),
    ("StopFailure", None, "error"),
    ("Stop", None, "stop"),
]

before = json.dumps(hooks, sort_keys=True)
for event in list(hooks):
    kept = []
    for entry in hooks[event]:
        entry["hooks"] = [h for h in entry.get("hooks", [])
                          if "claude-hook.sh" not in h.get("command", "")
                          and "agent-hook.sh" not in h.get("command", "")]
        if entry["hooks"]:
            kept.append(entry)
    hooks[event] = kept
for event, matcher, arg in WANTED:
    entry = {"hooks": [{"type": "command", "command": f"{hook} {arg} claude"}]}
    if matcher:
        entry = {"matcher": matcher, **entry}
    hooks.setdefault(event, []).append(entry)
for event in [e for e, entries in hooks.items() if not entries]:
    del hooks[event]

changed = json.dumps(hooks, sort_keys=True) != before
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print("claude hooks " + ("updated" if changed else "already up to date"))
PY
