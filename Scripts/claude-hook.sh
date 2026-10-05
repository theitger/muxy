#!/usr/bin/env bash
# Claude Code hook (see install-claude-hook.sh for the events): tells muxy what
# this session's agent is doing. muxy injects MUXY_SESSION into every
# terminal it spawns; the hook inherits it through claude's environment.
# Outside muxy: no-op. Prints nothing — UserPromptSubmit output would be
# added to the prompt.
input="$(cat 2>/dev/null || true)"
[ -n "${MUXY_SESSION:-}" ] || exit 0
# The conversation's transcript — muxy's remote shows it as a chat.
transcript=""
if [[ $input =~ \"transcript_path\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
    transcript="${BASH_REMATCH[1]}"
fi
state="$HOME/.local/state/muxy"
mkdir -p "$state/events" "$state/tmp"
# Write aside, then rename: muxy must never see a half-written event.
tmp="$state/tmp/$$-$RANDOM"
printf '%s %s %s %s\n' "$MUXY_SESSION" "claude" "${1:-stop}" "$transcript" > "$tmp"
mv "$tmp" "$state/events/"
exit 0
