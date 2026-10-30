#!/bin/sh
# Install/remove the launchd agent that runs scripts/grant-watchdog.sh every INTERVAL seconds.
#   sh scripts/install-grant-watchdog.sh install [INTERVAL_SECONDS]   (default 60)
#   sh scripts/install-grant-watchdog.sh status
#   sh scripts/install-grant-watchdog.sh run        # one immediate run via launchd
#   sh scripts/install-grant-watchdog.sh uninstall
set -eu
LABEL=com.roas.grant-watchdog
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HERE=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HERE/scripts/grant-watchdog.sh"
LOG="$HOME/Library/Logs/roas-grant-watchdog.log"
DOMAIN="gui/$(id -u)"
cmd="${1:-status}"

case "$cmd" in
  install)
    INTERVAL="${2:-60}"
    [ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 1; }
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>$SCRIPT</string></array>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
EOF
    launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "installed $LABEL (every ${INTERVAL}s) -> $PLIST"
    echo "log: $LOG"
    ;;
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "removed $LABEL"
    ;;
  run)
    launchctl kickstart -k "$DOMAIN/$LABEL"
    sleep 2
    tail -n 3 "$LOG" 2>/dev/null || true
    ;;
  status)
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      echo "$LABEL: loaded"
      launchctl print "$DOMAIN/$LABEL" | grep -E 'state|last exit|run interval' | head -4
    else
      echo "$LABEL: not loaded"
    fi
    tail -n 5 "$LOG" 2>/dev/null || true
    ;;
  *) echo "usage: $0 install [seconds] | uninstall | run | status" >&2; exit 2 ;;
esac
