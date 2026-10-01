#!/usr/bin/env bash
# Claude Code hook (UserPromptSubmit/Stop/Notification): tells muxy what
# this session's agent is doing. muxy injects MUXY_SESSION into every
# terminal it spawns; the hook inherits it through claude's environment.
# Outside muxy: no-op. Prints nothing — UserPromptSubmit output would be
# added to the prompt.
cat > /dev/null 2>&1 || true
[ -n "${MUXY_SESSION:-}" ] || exit 0
state="$HOME/.local/state/muxy"
mkdir -p "$state/events" "$state/tmp"
# Write aside, then rename: muxy must never see a half-written event.
tmp="$state/tmp/$$-$RANDOM"
printf '%s %s %s\n' "$MUXY_SESSION" "claude" "${1:-stop}" > "$tmp"
mv "$tmp" "$state/events/"
exit 0
