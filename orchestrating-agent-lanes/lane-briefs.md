# Lane briefs, messages and lifecycle

## Brief template (orchestrator → lane)

The limits come first, in bold, and say that a breach stops the task. Limits that were in the middle of a list were broken again and again.

```
<orchestrator> → <lane>: <ticket id> <title>
LIMITS (a breach stops the task):
- Worktree: <new: create one for this ticket with EnterWorktree from a freshly fetched origin/main. It goes under .claude/worktrees/, never next to the repository. Report its path, then wait for my inputs | resume: <existing worktree path>>. Work only in that worktree.
- <allowed shell programs, or the forbidden host programs>
- On the first permission prompt, denial or hook refusal: stop and tell me in one line. Do not try another command.
- Only origin/main and your own worktree count as truth. Never read another session's branch or worktree.
Goal: <one or two sentences>
Ticket: <id>. Read all comments. Rulings so far: <list or "none">
Inputs: <.scratch paths only; for a new worktree I send them after you report its path>
Scope: <in>. Out of scope: <out>
Done when: <checks>
First deliverable: <plan to me | draft PR>. No code before my OK on the plan.
```

Give subagents the same limits, and an allowlist of shell programs instead of a blocklist.

## Message format (any direction)

- Status: `<from> → <to>: <ticket>: <state>. <next step>. <blocker or "no blocker">.`
- A question carries the options and a recommendation.
- A command result is reported after the result, never before.
- Lanes send questions for stakeholders (designer, PM, client) to the orchestrator. The orchestrator takes them to the lead, one open question at a time (`SKILL.md`, rule 4). A lane whose question is queued gets one line back: queued, and what to do meanwhile.

## Handoff file

When a lane stops for the day or hands over, it writes `.scratch/handoff.md` in its worktree: branch, head commit, PR, done, next, open questions, held shared resources.

## Lane lifecycle

### Start
1. Pick the lowest-numbered free lane (`SKILL.md`, Lanes, names and worktrees). Record lane and ticket in the status file.
2. Read the ticket fully. Set it to In Progress. Collect the inputs in your own `.scratch/`.
3. Send the brief. It names the ticket, not a path that does not exist yet.
4. The lane fetches `origin/main` and creates the worktree from it with `EnterWorktree`, under `.claude/worktrees/` (`SKILL.md`, rule 12). It names the branch after the ticket. Never stack on an unmerged branch. If the work depends on one, the lead merges it first.
5. In the new worktree, the lane runs install and sets up the git hooks. Without them the first commit fails.
6. The lane reports the worktree path. Copy the inputs into its `.scratch/` and send the paths.
7. Non-trivial ticket: plan first, then your OK.

**Resume** a ticket that already has a worktree: the brief names its path. The lane leaves its current worktree with `ExitWorktree`. That returns it to its previous directory, which can be another worktree. It checks its current directory and calls `EnterWorktree` with the path only if it is not in that worktree yet. It never reaches into another worktree with `cd`, `git -C` or absolute paths.

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
- The lane reports "merged + tree clean".
- Archive the worktree's `.scratch/` in the main checkout's `.scratch/archive/<ticket>/`.
- The lane leaves the merged worktree with `ExitWorktree` and checks where it landed: its previous directory, which can be another worktree. Then the orchestrator removes the merged worktree (`git worktree remove`).
- Mark the lane as free in the status file. The lane keeps its tab and name, and takes the next ticket of any area, through the orchestrator. It creates the worktree for that ticket with `EnterWorktree`.
