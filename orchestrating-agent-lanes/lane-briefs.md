# Lane briefs, messages and lifecycle

## Brief template (orchestrator → lane)

The limits come first, in bold, and say that a breach stops the task. Limits that were in the middle of a list were broken again and again.

```
<orchestrator> → <lane>: <ticket id> <title>
LIMITS (a breach stops the task):
- Work only in <absolute worktree path>. Inputs are in .scratch/<…>.
- <allowed shell programs, or the forbidden host programs>
- On the first permission prompt, denial or hook refusal: stop and tell me in one line. Do not try another command.
- Only origin/main and your own worktree count as truth. Never read another session's branch or worktree.
Goal: <one or two sentences>
Ticket: <id>. Read all comments. Rulings so far: <list or "none">
Inputs: <.scratch paths only>
Scope: <in>. Out of scope: <out>
Done when: <checks>
First deliverable: <plan to me | draft PR>. No code before my OK on the plan.
```

Give subagents the same limits, and an allowlist of shell programs instead of a blocklist.

## Message format (any direction)

- Status: `<from> → <to>: <ticket>: <state>. <next step>. <blocker or "no blocker">.`
- A question carries the options and a recommendation.
- A command result is reported after the result, never before.
- Lanes send questions for stakeholders (designer, PM, client) to the orchestrator. The orchestrator takes them to the lead.

## Handoff file

When a lane stops for the day or hands over, it writes `.scratch/handoff.md` in its worktree: branch, head commit, PR, done, next, open questions, held shared resources.

## Lane lifecycle

### Start
1. Pick the lowest-numbered free lane (`SKILL.md`, Lane names). Record lane and ticket in the status file.
2. Read the ticket fully. Set it to In Progress.
3. Fetch `origin/main`. Create the worktree and branch from it. Never stack on an unmerged branch. If the work depends on one, the lead merges it first.
4. In the new worktree: install, git hooks. Without them the first commit fails.
5. Stage the inputs in `.scratch/`.
6. Send the brief. Non-trivial ticket: plan first, then your OK.

### During the work
- Commit at once, in small steps. No `git stash`; make a WIP commit to set work aside.
- Push alone: never in a parallel tool call, and never commit while a push runs.
- Open a draft PR right after the first push.
- Merge main in. Never rebase a pushed branch.
- Test locally only what the change touches. The full suite belongs to CI.
- A local test that uses a stub is reported as such, loudly.
- A gap found during the work becomes a new ticket. The PR stays in scope.
- Never `--no-verify`.

### End
- Merge gates (`merge-gates.md`), then the merge.
- Remove the worktree. Archive its `.scratch/` in the main checkout's `.scratch/archive/<ticket>/`.
- Mark the lane as free in the status file. It keeps its name and takes the next ticket of any area, through the orchestrator.
