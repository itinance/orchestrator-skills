# orchestrating-agent-lanes

An opinionated Claude Code skill for running one **orchestrator** session that leads several **lane** sessions for one human **lead**.

- Each lane is a long-lived terminal tab that works on one ticket at a time. A lane has no folder of its own.
- Each ticket gets its own git worktree. The lane creates it when it starts the ticket.
- The orchestrator talks to the lead, assigns tickets, writes the lane briefs and stages the input files.
- It also owns the shared resources, runs the merge gates and keeps the ticket status true.

The rules come from several months of daily multi-lane work on a real product. Most of them exist because something went wrong without them: a lane waited on a permission prompt that nobody saw, a merge ignored a late ruling, or a ticket was called Done before anyone checked it.

This is an opinionated approach, not a general framework. It assumes one human lead, one ticket at a time per lane, a git worktree per ticket, and merge gates that nobody skips. It works best when you adopt these choices as a whole. If they do not fit your team, take the parts that do, and change the rest in your own copy.

## What is in it

| File | Content |
|---|---|
| `orchestrating-agent-lanes/SKILL.md` | When the skill applies, the ten hard rules, a quick reference, red flags |
| `orchestrating-agent-lanes/lane-briefs.md` | Brief template, message format, handoff file, lane lifecycle |
| `orchestrating-agent-lanes/merge-gates.md` | Merge gates in order, after-merge steps, ticket status |
| `orchestrating-agent-lanes/setup-checklist.md` | Decisions for a new project, repository baseline, safety baseline |
| `tests/pressure-scenarios.md` | Six pressure scenarios with pass criteria, and how to run them with and without the skill |
| `watchdog/` | Session watchdog for macOS: notices sessions that stopped on an API error. See `watchdog/README.md` |
| `bin/cli.mjs` | The installer behind `npx` / `bunx`. Tests: `npm test` |
| `Makefile` | Release workflow: `make release BUMP=minor`, then `make publish OTP=<code>` |

## Requirements

- [Claude Code](https://docs.claude.com/en/docs/claude-code), with several sessions on one machine that can list and message each other (the `ListAgents` and `SendMessage` tools).
- A git repository. Each ticket gets one `git worktree`, created with Claude Code's `EnterWorktree` tool.
- Optional, as the files assume them: GitHub (`gh`) for PRs and CI, Linear for tickets, a read-only `code-reviewer` subagent for in-house reviews, and the [superpowers](https://github.com/obra/superpowers) plugin for brainstorming, plans and reviews. Other tools work too. Replace the names in the files.

## Setup

1. **Install the skill.** Use `npx` (Node 18.17 or later) or `bunx`. Both run the same installer.
   - For one project, committed with the repo. Run this in the repository root:
     ```bash
     npx orchestrator-skills@0.3.0 install
     # or
     bunx orchestrator-skills@0.3.0 install

     git add .claude/skills/orchestrating-agent-lanes
     ```
   - For all your projects (installs into `~/.claude/skills`):
     ```bash
     npx orchestrator-skills@0.3.0 install --global
     # or
     bunx orchestrator-skills@0.3.0 install --global
     ```
   The skill is available in the next Claude Code session.

   Pin the version as shown. A bare `npx orchestrator-skills` runs whatever version is newest on the day you run it. The package has no dependencies and no install scripts. The installer only copies the skill folders that ship with it and does not use the network.

   | Option | Effect |
   |---|---|
   | `install <skill>…` | Install only the named skills. Without names, all skills are installed. |
   | `-g`, `--global` | Install into `~/.claude/skills` instead of `./.claude/skills` |
   | `--dir <path>` | Install into `<path>` |
   | `-f`, `--force` | Replace a skill folder that already exists (for updates). Without it, the installer stops and changes nothing. |
   | `-n`, `--dry-run` | Print what would be copied, change nothing |
   | `list` | List the skills in the package |

   To update, run the install again with the new version and `--force`. To remove a skill, delete its folder from `.claude/skills`.
2. **Ignore the scratch folder.** Add `.scratch/` to `.gitignore`. Lanes keep their inputs, PR descriptions and review diffs there.
3. **Go through `setup-checklist.md` with the lead.** It lists the team decisions to make before the first lane starts: language, WIP limit, PR size, who creates tickets, which commands only the lead runs, and where design inputs live. Do not copy these decisions from another project.
4. **Grant the everyday commands** in `.claude/settings.json`: tests, lint, format, `git add/commit/push/fetch`, `gh pr` and `gh run`, your make targets. Lanes then get fewer permission prompts in tabs that nobody watches. Personal grants go in `.claude/settings.local.json`, which is not committed.

## Use

1. Open one terminal tab for the orchestrator. Tell it that it is the orchestrator for this repository and that you are the lead.
2. Open one tab per lane in the repository root and name the lanes by number: `lane1`, `lane2`, … A lane is a reusable slot, not a topic, so the orchestrator can give the next ticket to the next free lane, whatever its area. Give a role name (`review`, `tester`) only to a lane whose purpose never changes.
3. Give the orchestrator tickets. It reads them and sends each lane its brief. The lane creates a worktree for its ticket, and the orchestrator copies the inputs into it. Then it reports to you only when you must act: a decision, an approval, a command only you may run, or a lane that is waiting on a prompt.

## Customizing

The files are product-neutral. Adapt these points to your project:

- The tool names: ticket tool, external reviewer, CI.
- The allowlist of shell programs in the brief template.
- The list of heavy topics that need an external review.

Keep the hard rules in `SKILL.md` short. A rule that applies to every session belongs in the project's `CLAUDE.md`, not here.

## License

MIT, see [LICENSE](LICENSE).
