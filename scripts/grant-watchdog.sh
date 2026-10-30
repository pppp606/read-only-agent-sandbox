#!/bin/sh
# Host-side safety net: remove the GLOBAL anthropic OAuth grant that `/login` inside a
# sandbox leaves in Docker's host store, whenever no review sandbox exists any more.
# Covers exit paths the launcher's trap cannot (kill -9, terminal closed, host crash).
# Run periodically by launchd (see install-grant-watchdog.sh) or by hand.
#
# Rules:
#   - a review sandbox is any sandbox whose name starts with $PREFIX (default roas-)
#   - if at least one exists (running or stopped) do nothing
#   - otherwise, if `sbx secret ls` shows an anthropic entry, remove it
#   - if sbx cannot be queried, do nothing (log) rather than guess
set -u
PREFIX="${ROAS_SANDBOX_PREFIX:-roas-}"
LOG="${ROAS_WATCHDOG_LOG:-$HOME/Library/Logs/roas-grant-watchdog.log}"
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"; export PATH

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"; }

names=$(sbx ls -q 2>/dev/null) || { log "skip: sbx ls failed (daemon down or not signed in)"; exit 0; }
if printf '%s\n' "$names" | grep -q "^$PREFIX"; then
  exit 0   # a review sandbox exists; the grant is in use
fi
secrets=$(sbx secret ls --format json 2>/dev/null) || { log "skip: sbx secret ls failed"; exit 0; }
case "$secrets" in
  *'"name": "anthropic"'*)
    if sbx secret rm anthropic -f >/dev/null 2>&1; then
      log "removed stale global anthropic grant (no ${PREFIX}* sandbox present)"
    else
      log "ERROR: failed to remove anthropic grant; run: sbx secret rm anthropic -f"
      exit 1
    fi ;;
esac
exit 0
