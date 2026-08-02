#!/usr/bin/env bash
# Claude Code hook (Stop/Notification): tells muxy that this session wants
# attention. muxy injects MUXY_SESSION into every terminal it spawns; the
# hook inherits it through claude's environment. Outside muxy: no-op.
cat > /dev/null 2>&1 || true
[ -n "${MUXY_SESSION:-}" ] || exit 0
dir="$HOME/.local/state/muxy/events"
mkdir -p "$dir"
printf '%s %s %s\n' "$MUXY_SESSION" "claude" "${1:-event}" > "$dir/$$-$RANDOM"
exit 0
