---
name: crossref-audit
description: |
  Audit master in both pgxntool and pgxntool-test for paired commits (a code
  change plus its corresponding test coverage) that are missing a
  cross-reference to each other. Fixes safely when it's a single, recent,
  tip-of-master commit; otherwise stops and asks.

  Use when: at the end of each round of work in this project (not just
  session start — sessions run long), before rebasing a branch onto a fresh
  master fetch, or when asked to check/audit cross-references.
allowed-tools: Bash(git:*), Bash(gh:*), Bash(bash .claude/skills/crossref-audit/scripts/audit.sh:*), Read
---

# /crossref-audit

Check whether commits that landed on master in pgxntool and pgxntool-test
since the last release properly cross-reference their paired counterpart in
the other repo, per `.claude/skills/commit/guides/commit-message-format.md`.

## Why this exists, and how it differs from `/commit`

PRs merge via the GitHub website, by the user, outside AI control — Claude
doesn't see the merge happen, so a missing cross-reference can only be
caught *after the fact* by auditing what actually landed on master. This is
a different problem from `/commit`, which only covers composing a PR
branch's own commits *before* merge.

## Running it cheaply, every round

Run `bash .claude/skills/crossref-audit/scripts/audit.sh <pgxntool-dir> <pgxntool-test-dir>`.
This does steps 1 and most of step 3 below as a plain script — no LLM
tokens — and caches the last-checked master SHAs in
`/tmp/pgxntool-crossref-audit-state`, updated only on a clean result. That
means most rounds cost nothing more than reading one line of output:

- `crossref-audit: no new commits on either master since last clean check.` — done, nothing to interpret
- `crossref-audit: clean. Checked N / M commit(s)...` — done
- `crossref-audit: FLAGGED -- ...` — read the flagged list and apply the judgment in Step 2/Step 4 below

A flagged result is a heuristic, not a verdict — the script correlates
commits via the "(issue #N)" phrasing this project's commits use for
cross-repo issue references (not bare "(#N)", which is usually just the
local PR number), and only checks for the *presence* of a plausible
hash/URL pattern. It can both over-flag (a real pairing that already has a
reference in an unusual phrasing) and under-flag (a pairing it didn't
correlate). Treat "clean" as "nothing obviously wrong", not a guarantee.

## Step 2: Identify genuinely paired commits (only needed when something is flagged, or you're doing a manual review)

Not every commit needs a cross-reference. It's only expected when a commit
in one repo is a *functional* code+test pairing with a commit in the
other — e.g. a pgxntool bug fix with dedicated pgxntool-test BATS coverage
for it. It is NOT expected for:
- Single-repo, doc-only changes with no test implications
- Two commits that happen to fix similar-sounding problems independently in
  each repo (e.g. each repo has its own separate `claude-code-review.yml` —
  fixing both is two unrelated commits, not a pairing)

Use issue numbers, PR descriptions, and commit content to judge whether a
pairing is real. When genuinely unsure, ask the user rather than guessing.

## Step 3: Check for a cross-reference (the script does this automatically; use this if reviewing manually)

For each side of a genuine pairing, confirm the commit message references
the other repo — either a raw commit hash or (preferred, per the
commit-message-format guide) a GitHub PR/commit URL. Note: by convention
the pgxntool side only needs to describe related pgxntool-test changes in
prose (no hash required); the pgxntool-test side is expected to reference
pgxntool via hash or URL.

## Step 4: Handle what you find

**Nothing missing:** report that briefly and move on.

**Exactly one commit missing a reference, and it's the current tip of
master, and it's newer than the last release tag:** you may fix it
directly:
1. Create an isolated worktree tracking `upstream/master` detached — do NOT
   edit the shared checkout.
2. `git commit --amend` to add the missing cross-reference. Verify
   `git diff <old-sha> <new-sha>` is empty (message-only change, no content
   drift) before pushing.
3. `git fetch upstream master` again immediately before pushing, to catch
   any race, then
   `git push --force-with-lease=master:<old-sha> upstream HEAD:master`.
4. Report the old and new SHA clearly.
5. Check whether any open PR branch (in either repo) was already rebased
   onto the old, now-superseded SHA. If so, it needs re-rebasing onto the
   new tip — git will typically recognize the old commit as
   patch-equivalent and skip re-applying it cleanly, but re-run the full
   test suite on the result before pushing the re-rebase.

**More than one commit missing a reference:** STOP. Do not fix anything
automatically. Report the full list to the user and wait for direction —
amending multiple non-contiguous commits requires real history surgery
(interactive rebase), which is much higher-risk than touching a single tip
commit.

**Any affected commit is at or before the last release tag:** NEVER amend
it, regardless of how many commits are affected, unless the user explicitly
tells you to for that specific commit.

## Constraints

- This audit only ever touches already-merged master commits, and only ever
  the single tip commit under the conditions above. It never touches an
  open PR's own commits as part of the audit itself — fixing an open PR's
  commit (not yet shared/protected history) is a normal, low-risk edit and
  doesn't need this skill's caution, just do it directly.
- Always re-run the full test suite after any amend-and-force-push, and
  after any resulting PR-branch rebase, before considering the fix done.
