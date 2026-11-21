#!/bin/bash
# Session watchdog, phase 1: detect stalled Claude Code sessions and notify.
#
# A session counts as stalled when the last user or assistant entry of its
# main conversation is an API error, and its transcript has not changed for
# longer than the stall threshold.
#
# Privacy: the script reads only these fields of a transcript entry:
#   type, isSidechain, isApiErrorMessage, error, apiError, timestamp,
#   agentName / customTitle (the session name, for the notice).
# It never prints, logs or copies transcript content.
#
# Settings (environment overrides the config file, which overrides defaults):
#   WATCHDOG_STATE_DIR            ~/.claude/session-watchdog (environment only)
#   WATCHDOG_TRANSCRIPT_ROOT      ~/.claude/projects
#   WATCHDOG_STALL_MINUTES        10
#   WATCHDOG_WINDOW_HOURS         24   only transcripts changed in this window
#   WATCHDOG_DNS_HOST             api.anthropic.com
#   WATCHDOG_TAIL_LINES           300  lines read from the end of a transcript
#   WATCHDOG_JQ                   jq on PATH
# The config file is $WATCHDOG_STATE_DIR/config, KEY=VALUE lines. It is parsed,
# never sourced.

set -u
set -o pipefail

STATE_DIR="${WATCHDOG_STATE_DIR:-$HOME/.claude/session-watchdog}"
CONFIG="$STATE_DIR/config"
NOTIFIED="$STATE_DIR/notified"
HEARTBEAT="$STATE_DIR/heartbeat"

# Test hooks: write notices to a file instead of macOS, and fix the DNS result.
NOTIFY_LOG="${WATCHDOG_NOTIFY_LOG:-}"
DNS_OVERRIDE="${WATCHDOG_DNS_OK:-}"

setting() { # <name> <default>
  local name=$1 default=$2 val=""
  val=$(printenv "$name" 2>/dev/null || true)
  if [ -z "$val" ] && [ -r "$CONFIG" ]; then
    val=$(sed -n "s/^${name}=//p" "$CONFIG" | tail -n 1)
  fi
  val=${val:-$default}
  case $val in "~"*) val="$HOME${val#\~}" ;; esac
  printf '%s' "$val"
}

notify() { # <title> <body>
  local title=$1 body=$2
  case $body in -*) body=" $body" ;; esac
  if [ -n "$NOTIFY_LOG" ]; then
    printf '%s\t%s\n' "$title" "$body" >>"$NOTIFY_LOG"
    return
  fi
  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
    -e 'end run' "$title" "$body" >/dev/null 2>&1 \
    || printf '%s notify failed: %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$title" "$body" >&2
}

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

write_heartbeat() { date -u +%Y-%m-%dT%H:%M:%SZ >"$HEARTBEAT" 2>/dev/null || true; }

if ! mkdir -p "$STATE_DIR" 2>/dev/null || [ ! -w "$STATE_DIR" ]; then
  notify "Session watchdog" "watchdog cannot write its state folder $STATE_DIR"
  log "cannot write state folder $STATE_DIR"
  exit 1
fi
trap write_heartbeat EXIT

ROOT=$(setting WATCHDOG_TRANSCRIPT_ROOT "$HOME/.claude/projects")
STALL_MINUTES=$(setting WATCHDOG_STALL_MINUTES 10)
WINDOW_HOURS=$(setting WATCHDOG_WINDOW_HOURS 24)
DNS_HOST=$(setting WATCHDOG_DNS_HOST api.anthropic.com)
TAIL_LINES=$(setting WATCHDOG_TAIL_LINES 300)
JQ=$(setting WATCHDOG_JQ "$(command -v jq 2>/dev/null || true)")
case $ROOT in /*) ;; *) ROOT="$PWD/$ROOT" ;; esac

# Keys of everything that needs a notice this run. A key that was already in
# the previous run's file was notified before and stays quiet.
current_keys=""
add_key() { current_keys="${current_keys}$1"$'\n'; }
was_notified() { [ -r "$NOTIFIED" ] && grep -qxF -- "$1" "$NOTIFIED"; }
save_keys() { printf '%s' "$current_keys" >"$NOTIFIED.tmp" && mv "$NOTIFIED.tmp" "$NOTIFIED"; }

fail_loud() { # <reason>; notify once per failure state, log every run
  local key="fail|$1"
  add_key "$key"
  was_notified "$key" || notify "Session watchdog" "watchdog cannot read sessions: $1"
  log "cannot read sessions: $1"
}

problems=0
for pair in "WATCHDOG_STALL_MINUTES=$STALL_MINUTES" "WATCHDOG_WINDOW_HOURS=$WINDOW_HOURS" "WATCHDOG_TAIL_LINES=$TAIL_LINES"; do
  case ${pair#*=} in
    '' | *[!0-9]* | 0) fail_loud "invalid setting ${pair%%=*}"; problems=1 ;;
  esac
done
if [ -z "$JQ" ] || [ ! -x "$JQ" ]; then fail_loud "jq not found"; problems=1; fi
if [ ! -d "$ROOT" ] || [ ! -r "$ROOT" ] || [ ! -x "$ROOT" ]; then
  fail_loud "transcript folder not readable"; problems=1
fi
if [ "$problems" -ne 0 ]; then save_keys; exit 1; fi

if stat -f %m / >/dev/null 2>&1; then
  file_mtime() { stat -f %m -- "$1"; }
else
  file_mtime() { stat -c %Y -- "$1"; }
fi

dns_ok() { # 0 = resolves, 1 = does not, 2 = unknown
  case $DNS_OVERRIDE in 1) return 0 ;; 0) return 1 ;; esac
  if [ -x /usr/bin/host ]; then
    /usr/bin/host -W 3 "$DNS_HOST" >/dev/null 2>&1 && return 0 || return 1
  elif command -v getent >/dev/null 2>&1; then
    getent hosts "$DNS_HOST" >/dev/null 2>&1 && return 0 || return 1
  fi
  return 2
}

# Last main-conversation user/assistant entry, as: status <TAB> timestamp <TAB> kind
LAST_ENTRY_FILTER='
  fromjson?
  | select((.type == "user" or .type == "assistant") and ((.isSidechain // false) | not))
  | [ (if .isApiErrorMessage == true then "error" else "ok" end),
      (.timestamp // "" | tostring),
      ((.apiError // .error // "") | tostring | if test("^[a-z_]{1,40}$") then . else "" end) ]
  | @tsv'

# Session name: the last agent-name or custom-title entry. Control characters
# are dropped and the name is cut to 40 characters.
NAME_FILTER='
  fromjson?
  | select(.type == "agent-name" or .type == "custom-title")
  | (.agentName // .customTitle // empty) | tostring
  | gsub("[[:cntrl:]]"; "") | .[0:40]'

now=$(date +%s)
stall_secs=$((STALL_MINUTES * 60))
find_err="$STATE_DIR/find.err"
unreadable=0
stalled_names=""
earliest=""

while IFS= read -r -d '' f; do
  if [ ! -r "$f" ]; then unreadable=$((unreadable + 1)); continue; fi
  mtime=$(file_mtime "$f") || { unreadable=$((unreadable + 1)); continue; }
  [ $((now - mtime)) -gt "$stall_secs" ] || continue

  out=$(tail -n "$TAIL_LINES" -- "$f" | "$JQ" -R -r "$LAST_ENTRY_FILTER" 2>/dev/null) \
    || { unreadable=$((unreadable + 1)); continue; }
  last=${out##*$'\n'}
  [ "${last%%$'\t'*}" = "error" ] || continue
  rest=${last#*$'\t'}
  ts=${rest%%$'\t'*}

  name=$(grep -F -e '"type":"agent-name"' -e '"type":"custom-title"' -- "$f" 2>/dev/null \
    | "$JQ" -R -r "$NAME_FILTER" 2>/dev/null | tail -n 1)
  if [ -z "$name" ]; then
    id=$(basename -- "$f" .jsonl)
    name="session ${id:0:8}"
  fi

  since=$("$JQ" -n -r --arg t "$ts" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601' 2>/dev/null) || since=$mtime
  if [ -z "$earliest" ] || [ "$since" -lt "$earliest" ]; then earliest=$since; fi

  add_key "stall|$f|$ts"
  if [ -z "$stalled_names" ]; then stalled_names=$name; else stalled_names="$stalled_names, $name"; fi
done < <(find "$ROOT" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -mmin "-$((WINDOW_HOURS * 60))" -print0 2>"$find_err")

if [ -s "$find_err" ]; then unreadable=$((unreadable + $(wc -l <"$find_err"))); fi
rm -f "$find_err"
if [ "$unreadable" -gt 0 ]; then fail_loud "$unreadable transcript files or folders"; fi

new_stall=0
while IFS= read -r key; do
  case $key in stall\|*) was_notified "$key" || new_stall=1 ;; esac
done <<<"$current_keys"

if [ "$new_stall" -eq 1 ]; then
  at=$("$JQ" -n -r --argjson e "$earliest" '$e | strflocaltime("%H:%M")')
  dns_ok
  case $? in
    1) title="Network down: Claude sessions stalled" ;;
    *) title="Claude sessions stalled" ;;
  esac
  notify "$title" "$stalled_names: API error since $at"
fi

save_keys
exit 0
