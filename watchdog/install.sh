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
LAUNCHCTL="${WATCHDOG_LAUNCHCTL:-/bin/launchctl}" # tests replace it
DOMAIN="gui/$(id -u)"
MODE="${1:-install}"

setting() { # <name> <default>
  local val
  val=$(printenv "$1" 2>/dev/null || true)
  if [ -z "$val" ] && [ -r "$CONFIG" ]; then val=$(sed -n "s/^$1=//p" "$CONFIG" | tail -n 1); fi
  printf '%s' "${val:-$2}"
}

xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

check_install_settings() { # install and print only; uninstall must work without them
  INTERVAL=$(setting WATCHDOG_INTERVAL_MINUTES 5)
  case $INTERVAL in '' | *[!0-9]* | 0) echo "Invalid WATCHDOG_INTERVAL_MINUTES: $INTERVAL" >&2; exit 1 ;; esac
  JQ=$(command -v jq || true)
  case $JQ in /*) ;; *) echo "jq not found. Install it first (for example: brew install jq), then run this again." >&2; exit 1 ;; esac
}

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
    check_install_settings
    plist
    ;;
  install)
    check_install_settings
    mkdir -p "$STATE_DIR/bin" "$HOME/Library/LaunchAgents"
    chmod 700 "$STATE_DIR"
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
WATCHDOG_TAIL_LINES=300
WATCHDOG_TAIL_BYTES=2000000
WATCHDOG_LOG_MAX_LINES=500
EOF
    fi
    plist >"$PLIST"
    /usr/bin/plutil -lint "$PLIST" >/dev/null
    # bootout is asynchronous: wait until the old agent is gone, then load,
    # with one retry. A failed load says so, and the plist stays for a manual start.
    "$LAUNCHCTL" bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      "$LAUNCHCTL" print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
      sleep 0.5
    done
    if ! "$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
      sleep 1
      "$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST" || {
        echo "Could not load the agent. Start it with: launchctl bootstrap $DOMAIN $PLIST" >&2
        exit 1
      }
    fi
    echo "Installed $LABEL. It runs every $INTERVAL minutes."
    echo "Settings: $CONFIG   Heartbeat: $STATE_DIR/heartbeat   Log: $STATE_DIR/watchdog.log"
    echo "After a change of WATCHDOG_INTERVAL_MINUTES, run this again."
    ;;
  uninstall)
    "$LAUNCHCTL" bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed $LABEL. The state folder $STATE_DIR stays."
    ;;
  *)
    echo "Usage: bash watchdog/install.sh [install|uninstall|print]" >&2
    exit 1
    ;;
esac
