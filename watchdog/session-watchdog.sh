#!/bin/bash
# Session watchdog, phase 1: detect stalled Claude Code sessions and notify.
#
# A session counts as stalled when the last user or assistant entry of its
# main conversation is an API error, and its transcript has not changed for
# longer than the stall threshold.
#
# Privacy: the script reads only these fields of a transcript entry:
#   type, isSidechain, isApiErrorMessage, timestamp,
#   agentName / customTitle (the session name, for the notice).
# Only a validated timestamp and the session name leave the transcript.
# It never prints, logs or copies transcript content.
#
# Settings (environment overrides the config file, which overrides defaults):
#   WATCHDOG_STATE_DIR            ~/.claude/session-watchdog (environment only)
#   WATCHDOG_TRANSCRIPT_ROOT      ~/.claude/projects
#   WATCHDOG_STALL_MINUTES        10
#   WATCHDOG_WINDOW_HOURS         24   only transcripts changed in this window
#   WATCHDOG_DNS_HOST             api.anthropic.com
#   WATCHDOG_TAIL_LINES           300  lines read from the end of a transcript
#   WATCHDOG_TAIL_BYTES           2000000  at most this many bytes of that end
#   WATCHDOG_LOG_MAX_LINES        500  watchdog.log is cut to this length
#   WATCHDOG_JQ                   jq on PATH
# The config file is $WATCHDOG_STATE_DIR/config, KEY=VALUE lines. It is parsed,
# never sourced.

set -u
set -o pipefail

STATE_DIR="${WATCHDOG_STATE_DIR:-$HOME/.claude/session-watchdog}"
CONFIG="$STATE_DIR/config"
NOTIFIED="$STATE_DIR/notified"
HEARTBEAT="$STATE_DIR/heartbeat"
LOGFILE="$STATE_DIR/watchdog.log"

# Test hooks, active only with WATCHDOG_TEST=1: write notices to a file
# instead of macOS (this silences the real alerts), make a notice fail, and fix
# the DNS result. Without WATCHDOG_TEST=1 they are ignored.
NOTIFY_LOG=""
NOTIFY_FAIL=""
DNS_OVERRIDE=""
if [ "${WATCHDOG_TEST:-}" = 1 ]; then
  NOTIFY_LOG="${WATCHDOG_NOTIFY_LOG:-}"
  NOTIFY_FAIL="${WATCHDOG_NOTIFY_FAIL:-}"
  DNS_OVERRIDE="${WATCHDOG_DNS_OK:-}"
fi

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

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

notify() { # <title> <body>; returns non-zero when the notice could not be shown
  local title=$1 body=$2
  case $body in -*) body=" $body" ;; esac
  if [ "$NOTIFY_FAIL" = 1 ]; then log "notify failed: $title: $body"; return 1; fi
  if [ -n "$NOTIFY_LOG" ]; then
    printf '%s\t%s\n' "$title" "$body" >>"$NOTIFY_LOG"
    return
  fi
  if /usr/bin/osascript \
    -e 'on run argv' \
    -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
    -e 'end run' "$title" "$body" >/dev/null 2>&1; then
    return 0
  fi
  log "notify failed: $title: $body"
  return 1
}

write_heartbeat() { date -u +%Y-%m-%dT%H:%M:%SZ >"$HEARTBEAT" 2>/dev/null || true; }

if ! mkdir -p "$STATE_DIR" 2>/dev/null || [ ! -w "$STATE_DIR" ]; then
  notify "Session watchdog" "watchdog cannot write its state folder $STATE_DIR" || true
  log "cannot write state folder $STATE_DIR"
  exit 1
fi
chmod 700 "$STATE_DIR" 2>/dev/null || true
trap write_heartbeat EXIT

ROOT=$(setting WATCHDOG_TRANSCRIPT_ROOT "$HOME/.claude/projects")
STALL_MINUTES=$(setting WATCHDOG_STALL_MINUTES 10)
WINDOW_HOURS=$(setting WATCHDOG_WINDOW_HOURS 24)
DNS_HOST=$(setting WATCHDOG_DNS_HOST api.anthropic.com)
TAIL_LINES=$(setting WATCHDOG_TAIL_LINES 300)
TAIL_BYTES=$(setting WATCHDOG_TAIL_BYTES 2000000)
LOG_MAX_LINES=$(setting WATCHDOG_LOG_MAX_LINES 500)
JQ=$(setting WATCHDOG_JQ "$(command -v jq 2>/dev/null || true)")
case $ROOT in /*) ;; *) ROOT="$PWD/$ROOT" ;; esac

# Keep watchdog.log short. It is cut in place, so launchd's open handle stays valid.
case $LOG_MAX_LINES in '' | *[!0-9]* | 0) LOG_MAX_LINES=500 ;; esac
if [ -f "$LOGFILE" ] && [ "$(wc -l <"$LOGFILE")" -gt "$LOG_MAX_LINES" ]; then
  tail -n "$LOG_MAX_LINES" "$LOGFILE" >"$LOGFILE.tmp" && cat "$LOGFILE.tmp" >"$LOGFILE"
  rm -f "$LOGFILE.tmp"
fi

# State: one key per line. "stall|<file>|<error time>" for a stall that was
# notified, "fail|<reason>" for a failure that was notified. A key is written
# only after its notice was shown, so a failed notice is retried next run.
saved_keys=""
keep_key() { saved_keys="${saved_keys}$1"$'\n'; }
was_notified() { [ -r "$NOTIFIED" ] && grep -qxF -- "$1" "$NOTIFIED"; }
previous_stall_keys() { # [file]: notified stall keys, all or of one file
  [ -r "$NOTIFIED" ] || return 0
  if [ $# -eq 0 ]; then grep '^stall|' "$NOTIFIED" || true; else grep -F -- "stall|$1|" "$NOTIFIED" || true; fi
}
save_keys() { # a lost state means duplicate notices, so a failed write is loud
  if printf '%s' "$saved_keys" >"$NOTIFIED.tmp" 2>/dev/null && mv -f "$NOTIFIED.tmp" "$NOTIFIED" 2>/dev/null; then
    return 0
  fi
  log "cannot save state file $NOTIFIED"
  notify "Session watchdog" "watchdog cannot save its state in $STATE_DIR" || true
  return 1
}

fail_loud() { # <reason>; notify once per failure state, log every run
  local key="fail|$1"
  log "cannot read sessions: $1"
  if was_notified "$key" || notify "Session watchdog" "watchdog cannot read sessions: $1"; then
    keep_key "$key"
  fi
}

problems=0
for pair in "WATCHDOG_STALL_MINUTES=$STALL_MINUTES" "WATCHDOG_WINDOW_HOURS=$WINDOW_HOURS" "WATCHDOG_TAIL_LINES=$TAIL_LINES" "WATCHDOG_TAIL_BYTES=$TAIL_BYTES"; do
  case ${pair#*=} in
    '' | *[!0-9]* | 0) fail_loud "invalid setting ${pair%%=*}"; problems=1 ;;
  esac
done
if [ -z "$JQ" ] || [ ! -x "$JQ" ]; then fail_loud "jq not found"; problems=1; fi
if [ ! -d "$ROOT" ] || [ ! -r "$ROOT" ] || [ ! -x "$ROOT" ]; then
  fail_loud "transcript folder not readable"; problems=1
fi
if [ "$problems" -ne 0 ]; then
  # Could not look at the sessions: keep the stalls notified so far.
  while IFS= read -r key; do [ -n "$key" ] && keep_key "$key"; done <<<"$(previous_stall_keys)"
  save_keys || true
  exit 1
fi

case $(stat -f %m / 2>/dev/null) in
  '' | *[!0-9]*) bsd_stat=0 ;; # GNU stat -f means --file-system, not a number
  *) bsd_stat=1 ;;
esac
if [ "$bsd_stat" = 1 ]; then
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

# Last main-conversation user/assistant entry, as: status <TAB> timestamp.
# The timestamp passes only if it looks like an ISO 8601 time.
LAST_ENTRY_FILTER='
  fromjson?
  | select((.type == "user" or .type == "assistant") and ((.isSidechain // false) | not))
  | [ (if .isApiErrorMessage == true then "error" else "ok" end),
      (.timestamp | if type == "string" and test("^[0-9T:.Z-]{20,30}$") then . else "" end) ]
  | @tsv'

# Session name: the last agent-name or custom-title entry whose name is a
# string. Control characters are dropped and the name is cut to 40 characters.
NAME_FILTER='
  fromjson?
  | select(.type == "agent-name" or .type == "custom-title")
  | (.agentName // .customTitle) | select(type == "string")
  | gsub("[[:cntrl:]]"; "") | .[0:40]'

last_entry() { # <file>: prints "status<TAB>timestamp", or nothing; non-zero if unreadable
  local f=$1 out
  # Bytes first: a single line with an embedded image can be megabytes. A line
  # cut at the start of the byte window is dropped by fromjson?.
  out=$(tail -c "$TAIL_BYTES" -- "$f" | tail -n "$TAIL_LINES" | "$JQ" -R -r "$LAST_ENTRY_FILTER" 2>/dev/null) || return 1
  if [ -z "$out" ]; then
    # Long non-conversation tail: look at the whole file.
    out=$(grep -F -e '"type":"user"' -e '"type":"assistant"' -- "$f" 2>/dev/null \
      | "$JQ" -R -r "$LAST_ENTRY_FILTER" 2>/dev/null)
    [ $? -le 1 ] || return 1
  fi
  printf '%s' "${out##*$'\n'}"
}

now=$(date +%s)
stall_secs=$((STALL_MINUTES * 60))
find_err="$STATE_DIR/find.err"
unreadable=0
no_entry=0
new_keys=""
stalled_names=""
earliest=""

while IFS= read -r -d '' f; do
  mtime=""
  if [ -r "$f" ]; then mtime=$(file_mtime "$f" 2>/dev/null); fi
  if [ -z "$mtime" ] || ! last=$(last_entry "$f"); then
    unreadable=$((unreadable + 1))
    # Not readable this run: keep its notified stalls.
    while IFS= read -r key; do [ -n "$key" ] && keep_key "$key"; done <<<"$(previous_stall_keys "$f")"
    continue
  fi
  if [ -z "$last" ]; then no_entry=$((no_entry + 1)); continue; fi
  [ "${last%%$'\t'*}" = "error" ] || continue # healthy: its old stall keys drop out

  ts=${last#*$'\t'}
  if [ -n "$ts" ]; then
    key="stall|$f|$ts"
    since=$("$JQ" -n -r --arg t "$ts" '$t | sub("\\.[0-9]+"; "") | fromdateiso8601' 2>/dev/null) || since=$mtime
  else
    key="stall|$f|m$mtime"
    since=$mtime
  fi

  if was_notified "$key"; then keep_key "$key"; continue; fi # same stall, already told
  [ $((now - mtime)) -gt "$stall_secs" ] || continue         # too fresh to call it stalled

  name=$(grep -F -e '"type":"agent-name"' -e '"type":"custom-title"' -- "$f" 2>/dev/null \
    | "$JQ" -R -r "$NAME_FILTER" 2>/dev/null | tail -n 1)
  if [ -z "$name" ]; then
    id=$(basename -- "$f" .jsonl)
    name="session ${id:0:8}"
  fi

  if [ -z "$earliest" ] || [ "$since" -lt "$earliest" ]; then earliest=$since; fi
  new_keys="${new_keys}${key}"$'\n'
  if [ -z "$stalled_names" ]; then stalled_names=$name; else stalled_names="$stalled_names, $name"; fi
done < <(find "$ROOT" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -mmin "-$((WINDOW_HOURS * 60))" -print0 2>"$find_err")

if [ -s "$find_err" ]; then unreadable=$((unreadable + $(wc -l <"$find_err"))); fi
rm -f "$find_err"
if [ "$unreadable" -gt 0 ]; then fail_loud "$unreadable transcript files or folders"; fi
if [ "$no_entry" -gt 0 ]; then fail_loud "$no_entry transcripts without a conversation entry"; fi

if [ -n "$new_keys" ]; then
  at=$("$JQ" -n -r --argjson e "$earliest" '$e | strflocaltime("%H:%M")')
  dns_ok
  case $? in
    1) title="Network down: Claude sessions stalled" ;;
    *) title="Claude sessions stalled" ;;
  esac
  if notify "$title" "$stalled_names: API error since $at"; then
    saved_keys="${saved_keys}${new_keys}"
  fi
fi

save_keys || exit 1
exit 0
