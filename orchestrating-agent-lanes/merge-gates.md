# Merge gates and ticket status

## Gates, in this order

1. **Re-read the ticket**, all comments and threaded replies. A ruling that came after the last push means: hold, and send it to the lane.
2. **Pipeline green** on the PR head commit. Use the full 40-character SHA in API queries. A short SHA can return an empty list without an error.
3. **Review record exists for the head commit.** A push after the review needs a review of the new diff (at least the in-house review of what changed).
   - In-house: three read-only `code-reviewer` subagents in parallel (correctness, security, tests and spec) on `git diff origin/main...HEAD > .scratch/review.diff`.
   - External reviewer (for example CodeRabbit) only for heavy topics: migrations, auth and permissions, money, infrastructure and secrets, public endpoints. Collect fixes into one push, then ask once.
   - Every finding is fixed or answered in its thread.
4. **Merge fallout.** Compute the merge against the current `origin/main` (`git merge-tree --write-tree origin/main HEAD`). Check conflicts, migration numbers and order, and code that changed under the branch.
5. **Browser check** for UI or money changes, against the design reference. Images must render, not only their alt text.
6. Merge (or ask the lead, if the lead keeps the merge).

"Ready to merge" without a review record is not allowed.

## After the merge

- Ticket to **In Review**. Re-check after about 30 s: the GitHub integration may have set Done.
- Remove the lane's worktree, archive its `.scratch/`.
- Update the status file.

## Ticket status

| Status | When |
|---|---|
| In Progress | A lane starts the ticket |
| In Review | Everything is built and merged |
| Done | Checked on the test environment |

- Open questions keep a ticket open.
- Brainstorm questions and rulings go on the ticket as they happen, one comment each, numbered, with the reason.
- Mention a stakeholder only on a comment that needs their ruling.
- Before the first write, check that the ticket tool points at the right workspace.
