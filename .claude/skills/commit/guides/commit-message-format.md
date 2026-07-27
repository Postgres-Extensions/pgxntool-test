# Commit Message Format Guide

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

- Use placeholder `[PGXNTOOL_COMMIT_HASH]` (replaced with actual hash during execution)
- **A direct GitHub URL to the pgxntool PR or commit (e.g. `https://github.com/Postgres-Extensions/pgxntool/pull/63`) is an acceptable, and preferred, substitute for a raw commit hash.** A PR link stays valid even if the referenced commit is later rebased or amended (its hash changes, but the PR URL doesn't); a bare hash embedded in already-committed text goes stale silently in that case. Prefer linking the PR once one exists.
- If a raw hash was used and the referenced pgxntool commit is later rebased/amended (changing its hash) before your pgxntool-test PR merges, update the reference to the new hash before merging. This only matters pre-merge — once a commit has landed on master, don't rewrite it to fix a stale reference without explicit instruction from the user; rewriting shared history on a protected branch is a different (and much riskier) class of action than amending your own open PR branch.
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
Result: pgxntool-test commit references the pgxntool commit it corresponds to.
