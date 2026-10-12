# Commit Message Format Guide

## Closing GitHub Issues (CRITICAL)

When a commit fixes one or more issues, give each its own `Fixes #N` /
`Closes #N` / `Resolves #N` line -- never combine them into a single
comma-separated list like `Fixes #7, #14, #19`. **GitHub's auto-close only
recognizes the first issue number in that pattern and silently drops every
issue after it, with no error or warning.** This caused real drift in the
2.2.0 release: one commit's `Fixes #7, #14, #19, #28, #50, #53` line only
auto-closed #7 -- the other four issues were genuinely fixed but stayed
open on GitHub until a manual post-release audit caught it.

Correct:
```
Fixes #7.
Fixes #14.
Fixes #19.
```

Incorrect:
```
Fixes #7, #14, #19.
```

## Maintaining the HISTORY.asc fixed-issues line (pgxntool changes)

Whenever a commit's `Fixes #N` / `Closes #N` / `Resolves #N` refers to a
pgxntool issue, add that issue number to the STABLE section's fixed-issues
line in `../pgxntool/HISTORY.asc` -- regardless of whether the change is
significant enough for its own narrative `==` entry. These are two separate
decisions: "does this need a bullet explaining what changed" (maybe not) vs
"was a numbered issue closed" (if yes, it always goes on the list). See the
commit skill's step 3b for the mechanics.

## Item Ordering (CRITICAL)

Order all items (changes, bullet points) by **decreasing importance**:
- Importance = impact of the change x likelihood someone reading history will care
- Most impactful/interesting changes first, minor details last
- Think: "What would I want to see first when reading this in git log 2 years from now?"

## pgxntool Commit Format

```
Subject line

[Main changes in pgxntool, ordered by decreasing importance...]

Related changes in pgxntool-test:
- [RELEVANT test change 1]
- [RELEVANT test change 2]

Co-Authored-By: Claude <noreply@anthropic.com>
```

**Relevance filter for test changes:**

| Include | Exclude |
|---------|---------|
| Tests for new features | Test refactoring |
| Template updates | Infrastructure changes |
| User documentation | Internal improvements |

Keep to 1-3 bullets max. Wrap code references in backticks (e.g., `helpers.bash`, `make test`).
No hash placeholder needed - pgxntool doesn't reference test hash.

## pgxntool-test Commit Format

```
Subject line

Add tests/updates for pgxntool commit [PGXNTOOL_COMMIT_HASH] (brief description):
- [Key pgxntool change 1]
- [Key pgxntool change 2]

[pgxntool-test specific changes, ordered by decreasing importance...]

Co-Authored-By: Claude <noreply@anthropic.com>
```

- Use placeholder `[PGXNTOOL_COMMIT_HASH]` (replaced with actual hash during execution). The hash is a pointer for review only: squash and rebase merges both create new commits, so no branch commit's hash reaches master.
- **The cross-reference that has to survive the merge goes in the PR description, preferably as the pgxntool PR's URL** (e.g. `https://github.com/Postgres-Extensions/pgxntool/pull/63`). With squash merges the PR body becomes master's commit message, and a PR link stays valid when the referenced commit is rebased or amended; a bare hash goes stale silently. The same URL is also the preferred substitute for the hash in the commit message once the PR exists.
- If a raw hash was used and the referenced pgxntool commit is rebased/amended before your pgxntool-test PR merges, update the reference to the new hash.
- Include brief summary (2-3 bullets) of pgxntool changes near top
- Wrap code references in backticks

## Single-Repo Case

If only one repo has changes:
- Skip the repo with no changes
- In the commit message for the repo that has changes, add before Co-Authored-By:
  ```
  Changes only in [repo]. No related changes in [other repo].
  ```

---

## Two-Phase Commit Execution

Both phases commit to PR branches for review (the skill's step 2 stops on `master`/`main`).

### Phase 1: Commit pgxntool

1. `cd ../pgxntool`
2. Stage changes: `git add` specific files
   - Check `git status` for untracked files
   - ALL untracked files that are part of the feature/change MUST be staged
   - New scripts, documentation, helper files should all be included
   - Do NOT leave new files uncommitted unless explicitly told to exclude them
3. Verify staged files: `git status`
   - Confirm ALL modified AND untracked files are staged
   - STOP and ask user if staging doesn't match intent
4. Commit:
   ```bash
   git commit -m "$(cat <<'EOF'
   [approved pgxntool message]
   EOF
   )"
   ```
5. Capture hash: `PGXNTOOL_HASH=$(git log -1 --format=%h)`
6. Verify: `git status`
7. Handle pre-commit hooks if needed:
   - Check if hooks modified files
   - Check authorship: `git log -1 --format='%an %ae'`
   - Check branch status
   - Amend if safe or create new commit

### Phase 2: Commit pgxntool-test

1. Return to pgxntool-test directory
2. Replace `[PGXNTOOL_COMMIT_HASH]` in approved message with `$PGXNTOOL_HASH`
   - Keep everything else EXACTLY the same
3. Stage changes: `git add` specific files (include ALL new files)
4. Verify staged files: `git status`
5. Commit:
   ```bash
   git commit -m "$(cat <<'EOF'
   [approved message with actual pgxntool hash]
   EOF
   )"
   ```
6. Capture hash: `TEST_HASH=$(git log -1 --format=%h)`
7. Verify: `git status`
8. Handle pre-commit hooks if needed

### Important Notes

- If only one repo has changes, skip the phase for the other repo
- Always use HEREDOC format for commit messages
- Never use `-i` flags (git commit -i, git rebase -i)

## Repository Context

The two repositories:
- **pgxntool** (`../pgxntool/`) - The framework being tested. Main Makefile is `base.mk`, scripts in root, docs in `README.asc`.
- **pgxntool-test** (this repo) - Test harness with template files in `template/` directory.

Commit pgxntool first (no placeholder), capture hash, then commit pgxntool-test (inject hash).
Result: during review, the pgxntool-test commit references the pgxntool commit it
corresponds to; the PR description carries that reference through the merge.
