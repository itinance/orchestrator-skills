# Session watchdog

When the network drops (DNS error, Wi-Fi gone), each Claude Code session retries, then stops with "API error" and waits for a human. The orchestrator stops the same way, so nobody notices: eight quiet tabs look like a calm day. The watchdog runs outside the agents and notices the silence.

Phase 1 detects and notifies. It does not restart anything.

## What it does

Every 5 minutes, a launchd user agent runs `session-watchdog.sh`:

1. **Detect.** It reads the end of each transcript under `~/.claude/projects/*/` that changed in the last 24 hours. A session counts as **stalled** when the last user or assistant entry of its main conversation is an API error, and the transcript has not changed for more than 10 minutes. It also checks whether `api.anthropic.com` resolves, so that the notice can say "network down".
2. **Notify.** A macOS notification names the stalled sessions and the time of the earliest error, for example `lane6, orchestrator: API error since 09:32`. One notice per stall. A session notifies again only after it recovered and stalled again.
3. **Heartbeat.** Every run writes the current UTC time to `~/.claude/session-watchdog/heartbeat`. The orchestrator skill reads it when its session starts or resumes, and tells the lead when the watchdog is not running.

It fails closed and loud. If it cannot read the transcripts (folder missing or unreadable, jq missing, an invalid setting, unreadable files), it shows "watchdog cannot read sessions", once per failure, and logs it on every run.

## What it reads

Transcripts hold client data. The script never prints, logs or copies their content. It reads only these fields of a transcript entry:

| Field | Use |
|---|---|
| `type` | `user` / `assistant` entries are the conversation. Everything else (`system`, `queue-operation`, `last-prompt`, …) is skipped. |
| `isSidechain` | Subagent entries are skipped. |
| `isApiErrorMessage` | `true` marks an API error entry (an `assistant` entry written by Claude Code itself). |
| `timestamp` | Time of the error, for "since 09:32", and the key for "one notice per stall". Used only if it looks like an ISO 8601 time (`^[0-9T:.Z-]{20,30}$`), otherwise the file time is used. |
| `agentName` (`agent-name` entry), `customTitle` (`custom-title` entry) | The session name in the notice, only if it is a string. Control characters are dropped, the name is cut to 40 characters. Without one: `session <first 8 characters of the session id>`. `ai-title` is never used, because it summarizes the conversation. |

Only the validated timestamp and the session name leave the transcript.

Checked against real transcripts: after an API error, Claude Code often writes more entries (`system/turn_duration`, `system/informational`, `queue-operation`, `last-prompt`, `custom-title`, …). That is why the watchdog looks at the last user or assistant entry, not at the last line. If the last 300 lines hold no such entry, it reads the whole file. A transcript without any conversation entry gets a loud notice.

## One notice per stall

A stall is stored as notified only after its notice was shown, so a failed notice is retried on the next run. A notified stall stays stored while its transcript still ends on the same error, also when the file changes without a new message (for example a rename on resume) or when one run could not read it. It drops out when the session is healthy again, the file is gone, or it is outside the window.

`display notification` can exit without an error even when notifications are turned off for the app that runs it. The heartbeat and the log show that the watchdog runs, not that you see its notices. So test the notices once after the install (see "Make the notices visible").

## Install

Requirements: macOS, `bash`, `jq` (for example `brew install jq`). No other dependencies.

```bash
bash watchdog/install.sh            # install or update, and start
bash watchdog/install.sh print      # show the launchd plist, change nothing
bash watchdog/install.sh uninstall  # stop and remove (the state folder stays)
```

The installer copies the script to `~/.claude/session-watchdog/bin/`, writes the config file with the defaults if it does not exist, and loads `~/Library/LaunchAgents/orchestrator-skills.session-watchdog.plist`. The plist holds the absolute path of `jq`, because launchd starts agents with a minimal `PATH`.

Check that it runs: `cat ~/.claude/session-watchdog/heartbeat` shows a UTC time from the last few minutes.

### Make the notices visible

The watchdog shows its notices with `osascript`, the same way as this test:

```bash
osascript -e 'display notification "Test" with title "Session watchdog"'
```

- **No banner, but the entry is in Notification Center:** the app's alert style is "None". Open *System Settings → Notifications*, select the app the test notice came from (usually *Script Editor*), and set the style to **Alerts**. Alerts stay on screen until you close them, so a stall is not missed while you are away. *Banners* disappear after a few seconds.
- **Nothing at all:** turn on *Allow notifications* for that app.
- **A Focus mode (Do Not Disturb, Work, …)** holds back banners too. Allow the app in that Focus, or accept that notices wait in Notification Center.

Run the test again until the notice appears on screen.

## Settings

In `~/.claude/session-watchdog/config` (`KEY=VALUE`, parsed, never sourced). An environment variable of the same name takes precedence.

| Setting | Default | Read by |
|---|---|---|
| `WATCHDOG_INTERVAL_MINUTES` | 5 | installer (run it again after a change) |
| `WATCHDOG_STALL_MINUTES` | 10 | script |
| `WATCHDOG_HEARTBEAT_MAX_AGE_MINUTES` | 15 | orchestrator skill |
| `WATCHDOG_TRANSCRIPT_ROOT` | `~/.claude/projects` | script |
| `WATCHDOG_WINDOW_HOURS` | 24 | script |
| `WATCHDOG_DNS_HOST` | `api.anthropic.com` | script |
| `WATCHDOG_TAIL_LINES` | 300 | script |
| `WATCHDOG_TAIL_BYTES` | 2000000 | script (at most this many bytes of the end, because a line with an image can be megabytes) |
| `WATCHDOG_LOG_MAX_LINES` | 500 | script (cuts `watchdog.log` to this length) |
| `WATCHDOG_STATE_DIR` | `~/.claude/session-watchdog` | both (environment only) |

The tests use hooks that write notices to a file instead of showing them (`WATCHDOG_NOTIFY_LOG`), make a notice fail, or fix the DNS result. The script accepts them only together with `WATCHDOG_TEST=1`, so a stray environment variable cannot silence the real alerts.

## Files in the state folder

The folder is private to the user (mode 700).

| File | Content |
|---|---|
| `heartbeat` | UTC time of the last run |
| `notified` | Keys of the stalls and failures already notified (transcript path and error time). No content. |
| `config` | Settings |
| `watchdog.log` | The watchdog's own failure messages, capped at `WATCHDOG_LOG_MAX_LINES` |

## Tests

```bash
bash tests/watchdog.test.sh
```

Synthetic fixture tails in `tests/fixtures/watchdog/` for stalled, healthy, recovered, re-stalled, network down, subagent error before and after the main error, broken last line, missing and crafted names, an invalid timestamp and a transcript without conversation. The tests also cover a failed notice, a long non-conversation tail, an mtime refresh, a failed run between two runs, and the installer with a fake `launchctl`. Their content fields hold a canary string, and the tests check that it never appears in a notice, log or state file.

## Known limits

- A session whose tab was closed right after an API error counts as stalled too. It notifies once, then stays quiet.
- The DNS check only qualifies the notice. A DNS failure without a stalled session shows nothing.
- The DNS check uses `/usr/bin/host`, which reads `resolv.conf` and bypasses the macOS resolver. With a VPN or split DNS, the "network down" part of the title can be wrong in either direction (not verified). The stall itself is detected from the transcripts either way.
- A notice names only the sessions that stalled since the last notice, with the earliest of their error times. Sessions that are still stalled from an earlier notice are not repeated.
