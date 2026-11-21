# Setup checklist for a new project

## Decide with the lead (do not copy them from another project)

- [ ] Language and tone for the lead. Language for lanes, tickets, commits and PRs.
- [ ] How many numbered lanes (`lane1` … `laneN`), and which fixed-role lanes, if any (for example `review`, `tester`). No lanes named after an area.
- [ ] WIP limit per lane. PR size policy (bundle by area or small PRs; the external reviewer may skip PRs above a file limit).
- [ ] Who creates tickets.
- [ ] External reviewer yes or no, and its allowance.
- [ ] One shared local runtime stack for all worktrees? If yes: one owner at a time and a guard on every command that changes it.
- [ ] Heavy local runs one at a time on the machine?
- [ ] Where the orchestrator's status file lives. Claude memory is personal and not in git. A gitignored `.scratch/orchestrator/` file in the main checkout is visible on the machine.
- [ ] Commands only the lead runs: infrastructure apply, deploys, secrets, messages to other people.
- [ ] Host interpreters allowed, or containers only (then a PreToolUse hook that refuses them).
- [ ] Session watchdog yes or no (`watchdog/README.md` in the skill repo). It notices sessions that stopped on an API error, for example when the network drops.
- [ ] Where design inputs live: committed in the repo (recommended) or staged per lane.

## Repository baseline

- `.scratch/` in `.gitignore`. MR/PR descriptions, review diffs and staged inputs go there.
- `.claude/settings.json` (committed): the commands lanes need every day, so they get no prompts: tests, lint, format, `git add/commit/push/fetch`, `gh pr`, `gh run`, `gh api`, the project's make targets. No destructive grants.
- `.claude/settings.local.json` (gitignored): personal and one-off grants. Never commit it.
- `.claude/agents/code-reviewer.md`: read-only reviewer (Read, Grep, Glob), input a diff path and a focus, output findings with `file:line`, a failure scenario and a severity.
- A PreToolUse isolation hook that refuses commands aimed at another worktree (for example `git -C <other worktree>`). Without it, "read only inside your own worktree" is discipline only.
- Git hooks: pre-commit (format, lint), pre-push (tests of the changed area; a path nobody mapped means more checks, never none).
- CI: fast jobs on every PR, heavy jobs only on PRs that are ready for review, and branch protection with required checks. Test that a draft PR cannot merge: a skipped job passes a required check by default.
- Linear's GitHub integration on, and its "Done on merge" behavior known.
- Every hook that rewrites commands tested together with the permission mode in use.

## Safety baseline for every session

- Pin exact versions and image digests. Never fetch-and-execute (`curl … | sh`). Fail closed when something cannot be pinned or verified.
- Secrets never in a URL, log, commit or chat. The lead creates them.
- Never log request or response bodies that carry personal data.
- Confirm destructive or outward-facing steps with the lead: force-push, deleting tracked files, deploys, messages to other people.

## Install

- Per project: run `npx orchestrator-skills@<version> install` (or `bunx`) in the repository root, then commit `.claude/skills/orchestrating-agent-lanes/`.
- Personal, all projects: add `--global`. It installs into `~/.claude/skills/`.
- The skill loads in a new session, or when the skill list refreshes.
