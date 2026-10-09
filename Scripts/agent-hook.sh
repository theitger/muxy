#!/usr/bin/env bash
# Agent hook for Claude Code and Codex (see install-claude-hook.sh and
# install-codex-hook.sh for the events): tells muxy what this session's agent
# is doing. muxy injects MUXY_SESSION into every terminal it spawns; the hook
# inherits it through the agent's environment. Outside muxy: no-op. Prints
# nothing: SessionStart and UserPromptSubmit output would reach the model.
#
# Usage: agent-hook.sh <event> [claude|codex]
input="$(cat 2>/dev/null || true)"
[ -n "${MUXY_SESSION:-}" ] || exit 0
agent="${2:-claude}"
case "$agent" in claude|codex) ;; *) exit 0 ;; esac
# The agent's own session id (muxy resumes it after a restart) and its
# conversation log (muxy's remote shows it as a chat).
session="-"
if [[ $input =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9._-]+)\" ]]; then
    session="${BASH_REMATCH[1]}"
fi
transcript=""
if [[ $input =~ \"transcript_path\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
    transcript="${BASH_REMATCH[1]}"
fi
state="$HOME/.local/state/muxy"
mkdir -p "$state/events" "$state/tmp"
# Write aside, then rename: muxy must never see a half-written event.
tmp="$state/tmp/$$-$RANDOM"
printf '%s %s %s %s %s\n' "$MUXY_SESSION" "$agent" "${1:-stop}" "$session" "$transcript" > "$tmp"
mv "$tmp" "$state/events/"
exit 0
