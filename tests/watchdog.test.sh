#!/bin/bash
# Tests for watchdog/session-watchdog.sh. Run: bash tests/watchdog.test.sh
# The fixtures are synthetic. Their content fields hold a canary string that
# must never show up in any output, state file or notice.

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
SCRIPT="$REPO/watchdog/session-watchdog.sh"
INSTALL="$REPO/watchdog/install.sh"
FIX="$HERE/fixtures/watchdog"
CANARY="CANARY-CONTENT-MUST-NOT-LEAK"
export TZ=UTC

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
not_ok() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

if date -r 0 >/dev/null 2>&1; then
  stamp() { date -r "$1" +%Y%m%d%H%M.%S; }
else
  stamp() { date -d "@$1" +%Y%m%d%H%M.%S; }
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A fresh sandbox: transcript root with one project folder whose name starts
# with a dash (as real project folders do), a state folder and a notice log.
new_sandbox() {
  SB="$TMP/$1"
  ROOT="$SB/projects"
  PROJ="$ROOT/-Users-test-project"
  STATE="$SB/state"
  NOTICES="$SB/notices.log"
  mkdir -p "$PROJ" "$STATE"
  : >"$NOTICES"
}

# place <fixture> <session-id> <age in minutes>
place() {
  cp "$FIX/$1.jsonl" "$PROJ/$2.jsonl"
  touch -t "$(stamp $(($(date +%s) - $3 * 60)))" "$PROJ/$2.jsonl"
}

run() { # extra env assignments as arguments
  env WATCHDOG_STATE_DIR="$STATE" WATCHDOG_TRANSCRIPT_ROOT="$ROOT" \
    WATCHDOG_NOTIFY_LOG="$NOTICES" WATCHDOG_DNS_OK=1 "$@" \
    bash "$SCRIPT" >"$SB/stdout" 2>"$SB/stderr"
  RC=$?
}

notice_count() { wc -l <"$NOTICES" | tr -d ' '; }
last_notice() { tail -n 1 "$NOTICES"; }

expect_notices() { # <name> <count>
  if [ "$(notice_count)" = "$2" ]; then ok "$1"; else not_ok "$1" "expected $2 notices, got $(notice_count): $(cat "$NOTICES")"; fi
}
expect_last() { # <name> <exact line>
  if [ "$(last_notice)" = "$2" ]; then ok "$1"; else not_ok "$1" "got: $(last_notice)"; fi
}
expect_no_canary() { # <name>
  if grep -rqF "$CANARY" "$STATE" "$NOTICES" "$SB/stdout" "$SB/stderr"; then not_ok "$1" "canary leaked"; else ok "$1"; fi
}

# --- stalled
new_sandbox stalled
place stalled 11111111-aaaa 20
run
expect_notices "stalled: one notice" 1
expect_last "stalled: names the session and the error time" $'Claude sessions stalled\tlane6: API error since 09:32'
[ "$RC" = 0 ] && ok "stalled: exit 0" || not_ok "stalled: exit 0" "rc=$RC"
expect_no_canary "stalled: no content in any output"

run
expect_notices "stalled: no second notice on the next run" 1

# --- healthy, recovered, too fresh, sidechain only, outside the window
new_sandbox quiet
place healthy 22222222-aaaa 30
place recovered 33333333-aaaa 30
place stalled 44444444-aaaa 5
place sidechain-error 55555555-aaaa 30
place stalled 66666666-aaaa $((30 * 60))
run
expect_notices "healthy, recovered, fresh error, sidechain error, old file: no notice" 0
expect_no_canary "quiet: no content in any output"

# --- network down
new_sandbox network
place stalled 11111111-bbbb 20
run WATCHDOG_DNS_OK=0
expect_last "network down: title says so" $'Network down: Claude sessions stalled\tlane6: API error since 09:32'

# --- two stalls in one notice, earliest time
new_sandbox two
place stalled 11111111-cccc 20
place stalled-earlier 22222222-cccc 25
run
expect_notices "two stalls: one notice" 1
if last_notice | grep -q 'lane6' && last_notice | grep -q 'orchestrator' && last_notice | grep -q 'since 09:25$'; then
  ok "two stalls: both names, earliest time"
else
  not_ok "two stalls: both names, earliest time" "got: $(last_notice)"
fi

# --- recovery, then a new stall in the same session
new_sandbox restall
place stalled 77777777-aaaa 20
run
place recovered 77777777-aaaa 15
run
expect_notices "recovered: no notice" 1
place restalled 77777777-aaaa 12
run
expect_notices "new stall after recovery: notified again" 2
expect_last "new stall after recovery: new error time" $'Claude sessions stalled\tlane2: API error since 09:51'

# --- name fallbacks and a half-written last line
new_sandbox names
place broken-tail 88888888-aaaa 20
run
expect_last "custom-title name, broken last line still parsed" $'Claude sessions stalled\tlane4: API error since 09:32'
new_sandbox unnamed
place unnamed 9abcdef0-1234 20
run
expect_last "no name: short session id" $'Claude sessions stalled\tsession 9abcdef0: API error since 09:32'

# --- fail closed and loud
new_sandbox noroot
rm -rf "$ROOT"
run
expect_last "missing transcript folder: loud notice" $'Session watchdog\twatchdog cannot read sessions: transcript folder not readable'
[ "$RC" = 1 ] && ok "missing transcript folder: exit 1" || not_ok "missing transcript folder: exit 1" "rc=$RC"
[ -s "$STATE/heartbeat" ] && ok "missing transcript folder: heartbeat still written" || not_ok "missing transcript folder: heartbeat still written"
run
expect_notices "missing transcript folder: notified once, not every run" 1
grep -q 'transcript folder not readable' "$SB/stderr" && ok "missing transcript folder: logged on every run" || not_ok "missing transcript folder: logged on every run"

new_sandbox nojq
place stalled 11111111-dddd 20
run WATCHDOG_JQ=/nonexistent/jq
expect_last "jq missing: loud notice" $'Session watchdog\twatchdog cannot read sessions: jq not found'

new_sandbox badconfig
place stalled 11111111-eeee 20
printf 'WATCHDOG_STALL_MINUTES=ten\n' >"$STATE/config"
run
expect_last "invalid setting: loud notice" $'Session watchdog\twatchdog cannot read sessions: invalid setting WATCHDOG_STALL_MINUTES'

new_sandbox unreadable
place stalled 11111111-ffff 20
chmod 000 "$PROJ/11111111-ffff.jsonl"
run
if [ "$(id -u)" = 0 ]; then
  ok "unreadable file: skipped as root"
else
  grep -q 'cannot read sessions: 1 transcript files or folders' "$NOTICES" && ok "unreadable file: loud notice" || not_ok "unreadable file: loud notice" "$(cat "$NOTICES")"
fi
chmod 600 "$PROJ/11111111-ffff.jsonl"

# --- settings from the config file
new_sandbox config
place stalled 11111111-0000 20
printf 'WATCHDOG_STALL_MINUTES=30\n' >"$STATE/config"
run
expect_notices "config file: stall threshold 30 min, 20 min old error is not stalled yet" 0

# --- heartbeat
new_sandbox heartbeat
run
if grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$STATE/heartbeat"; then ok "heartbeat: UTC timestamp only"; else not_ok "heartbeat: UTC timestamp only" "$(cat "$STATE/heartbeat")"; fi

# --- installer renders a valid launchd plist
if [ -x /usr/bin/plutil ]; then
  new_sandbox install
  plist=$(env WATCHDOG_STATE_DIR="$STATE" WATCHDOG_INTERVAL_MINUTES=7 bash "$INSTALL" print 2>"$SB/stderr")
  if printf '%s' "$plist" | /usr/bin/plutil -lint - >/dev/null; then ok "installer: valid plist"; else not_ok "installer: valid plist" "$(cat "$SB/stderr")"; fi
  printf '%s' "$plist" | grep -q '<integer>420</integer>' && ok "installer: interval from settings (7 min = 420 s)" || not_ok "installer: interval from settings"
  printf '%s' "$plist" | grep -q '<key>WATCHDOG_JQ</key>' && ok "installer: absolute jq path in the plist" || not_ok "installer: absolute jq path in the plist"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
