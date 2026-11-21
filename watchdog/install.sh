#!/bin/bash
# Installs the session watchdog as a launchd user agent (macOS).
#
#   bash watchdog/install.sh            install or update, then start
#   bash watchdog/install.sh uninstall  stop and remove the agent (state stays)
#   bash watchdog/install.sh print      print the plist, change nothing
#
# Settings: WATCHDOG_INTERVAL_MINUTES (default 5), from the environment or the
# config file in the state folder. The other settings are read by the script.

set -euo pipefail

LABEL="orchestrator-skills.session-watchdog"
HERE=$(cd "$(dirname "$0")" && pwd)
STATE_DIR="${WATCHDOG_STATE_DIR:-$HOME/.claude/session-watchdog}"
CONFIG="$STATE_DIR/config"
BIN="$STATE_DIR/bin/session-watchdog.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
MODE="${1:-install}"

setting() { # <name> <default>
  local val
  val=$(printenv "$1" 2>/dev/null || true)
  if [ -z "$val" ] && [ -r "$CONFIG" ]; then val=$(sed -n "s/^$1=//p" "$CONFIG" | tail -n 1); fi
  printf '%s' "${val:-$2}"
}

xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

INTERVAL=$(setting WATCHDOG_INTERVAL_MINUTES 5)
case $INTERVAL in '' | *[!0-9]* | 0) echo "Invalid WATCHDOG_INTERVAL_MINUTES: $INTERVAL" >&2; exit 1 ;; esac
JQ=$(command -v jq || true)
case $JQ in /*) ;; *) echo "jq not found. Install it first (for example: brew install jq), then run this again." >&2; exit 1 ;; esac

plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$(xml "$BIN")</string></array>
  <key>StartInterval</key><integer>$((INTERVAL * 60))</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>WATCHDOG_STATE_DIR</key><string>$(xml "$STATE_DIR")</string>
    <key>WATCHDOG_JQ</key><string>$(xml "$JQ")</string>
  </dict>
  <key>StandardErrorPath</key><string>$(xml "$STATE_DIR/watchdog.log")</string>
</dict>
</plist>
EOF
}

case $MODE in
  print)
    plist
    ;;
  install)
    mkdir -p "$STATE_DIR/bin" "$HOME/Library/LaunchAgents"
    install -m 755 "$HERE/session-watchdog.sh" "$BIN"
    if [ ! -e "$CONFIG" ]; then
      cat >"$CONFIG" <<'EOF'
# Session watchdog settings. KEY=VALUE, one per line. Defaults shown.
WATCHDOG_INTERVAL_MINUTES=5
WATCHDOG_STALL_MINUTES=10
WATCHDOG_HEARTBEAT_MAX_AGE_MINUTES=15
WATCHDOG_TRANSCRIPT_ROOT=~/.claude/projects
WATCHDOG_WINDOW_HOURS=24
WATCHDOG_DNS_HOST=api.anthropic.com
EOF
    fi
    plist >"$PLIST"
    /usr/bin/plutil -lint "$PLIST" >/dev/null
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "Installed $LABEL. It runs every $INTERVAL minutes."
    echo "Settings: $CONFIG   Heartbeat: $STATE_DIR/heartbeat   Log: $STATE_DIR/watchdog.log"
    echo "After a change of WATCHDOG_INTERVAL_MINUTES, run this again."
    ;;
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed $LABEL. The state folder $STATE_DIR stays."
    ;;
  *)
    echo "Usage: bash watchdog/install.sh [install|uninstall|print]" >&2
    exit 1
    ;;
esac
