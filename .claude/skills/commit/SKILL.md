---
name: commit
description: |
  Compose git commits on PR branches across pgxntool and pgxntool-test for review,
  following project standards. Preprocesses repo info, runs tests, drafts cross-referenced
  commit messages, and executes two-phase commits with hash injection.

  Use when: "commit", "create commit", "commit changes", "/commit"
allowed-tools: Bash(git status:*), Bash(git log:*), Bash(git add:*), Bash(git diff:*), Bash(git commit:*), Bash(git branch:*), Bash(bash .claude/skills/commit/scripts/*), Read, Edit, Task, Skill(test)
---

# Commit Skill

Compose commits on a PR branch for review, following project standards and safety
protocols. Commits never land on master directly; what reaches master is the merge
result (see CLAUDE.md "Git Commit Guidelines").

## Critical Requirements

| Rule | Details |
|------|---------|
| **Git Safety** | Never update git config. Never skip hooks unless requested. Never force-push without asking -- see Restrictions. |
| **Attribution** | No "Generated with Claude Code" in body. Co-Authored-By trailer is OK. |
| **Multi-Repo** | Commit BOTH repos if both have changes (unless told otherwise). No empty commits. Never create a branch on a repo that has no changes. |
| **Testing** | ALL tests must pass. ANY failure = STOP and ask user. No rationalizing failures. |
| **HISTORY.asc** | Update for significant user-visible pgxntool changes. Propose entry, get confirmation. Separately and always: any `Fixes #N`/`Closes #N`/`Resolves #N` for a pgxntool issue must be added to the running "Issues fixed" line, even when the change is too minor for its own bullet (see step 3b). |

## Workflow

### 1. Launch Tests (Background)

Invoke the `/test` skill (runs `test-all` by default).
The test skill runs in background, parses TAP output, and enforces strict pass/fail.
Skip only if user explicitly says to.

### 2. Gather Repository Info

Run the preprocessing script to collect all git data in one call:

```bash
bash .claude/skills/commit/scripts/gather-repo-info.sh ../pgxntool .
```

Review output. Identify which repos have changes. If either repo with changes is on
`master`/`main`, STOP and ask -- never commit there.

### 2b. Check Debug Level Distribution (pgxntool .sh changes only)

If `../pgxntool/*.sh` files are in the diff, scan each changed file:

1. Collect all `debug N` call levels
2. Note whether the file contains loops (`for`, `while`)
3. Flag if: file has loops AND every debug call uses a single-digit level (1-9)
4. Flag if: file has 5+ debug calls AND they all use the exact same level

This is **advisory only** — present any findings in Step 5 and let the user decide.
If nothing looks off, say nothing (don't add noise to the common case).

### 3. Check HISTORY.asc (pgxntool changes only)

Read `../pgxntool/HISTORY.asc`. Determine if changes are significant and user-visible:
- Yes: New features, behavior changes, bug fixes users would notice
- No: Internal refactoring, test changes, cleanup, documentation fixes

If update needed:
1. Propose entry in AsciiDoc format (use `==` for heading)
2. Ask for confirmation BEFORE proceeding
3. Add to STABLE section at TOP of file (create section if missing):
   ```
   STABLE
   ------
   == [Entry heading]
   [Entry description]

   [existing content...]
   ```

### 3b. Update the "Issues fixed" line (pgxntool changes only, whenever an issue is fixed)

Independent of the bullet-entry decision above: if this commit's message
contains a `Fixes #N` / `Closes #N` / `Resolves #N` for a pgxntool issue, that
issue number belongs on the STABLE section's running fixed-issues line --
even when the change is too minor to warrant its own `==` entry. Don't defer
this to release time; maintain it incrementally, one commit at a time. (The
`/release` skill's own "Compile the complete fixed-issues line" step is a
final audit/safety net for anything that slipped through this per-commit
step -- e.g. a commit made outside this skill -- not the primary mechanism.)

- Line lives at the end of the STABLE section (last line before the next
  version's heading), format: `Issues fixed in this release: #7, #14, #19`
- If it doesn't exist yet, create it. If it exists, add the new number(s),
  keep the list deduped and in ascending numeric order.
- pgxntool issues only -- pgxntool-test has no equivalent list.

### 4. Draft Commit Messages

Read the format guide for detailed templates and rules:
**`.claude/skills/commit/guides/commit-message-format.md`**

Key principles:
- Order items by **decreasing importance** (impact x likelihood someone cares)
- pgxntool message includes relevant test changes (1-3 bullets)
- pgxntool-test message uses `[PGXNTOOL_COMMIT_HASH]` placeholder
- Single-repo: note "Changes only in [repo]. No related changes in [other repo]."
- Wrap code references in backticks

### 5. Present for Approval

Show proposed commit messages. Wait for user approval.
Mention any files intentionally excluded and why.
If only one repo has changes, show only that message (with note about other repo).

### 6. Verify Tests Passed (MANDATORY)

Check test skill output for completion.
- Verify STATUS is `PASS` with zero skips
- **If STATUS is `FAIL` or `PASS_WITH_SKIPS`: STOP. Do NOT commit. Ask user what to do.**
- There is NO such thing as an "acceptable" failing or skipped test
- Do NOT rationalize failures or skips as "pre-existing" or "unrelated"
- Only proceed if STATUS is `PASS` with zero skips

### 7. Execute Two-Phase Commit

After tests pass AND receiving user approval:

1. **Phase 1: Commit pgxntool** (if it has changes)
   - Stage files: `git add` specific files (include ALL new files for the feature)
   - Verify staging: `git status` (STOP if mismatch)
   - Commit with approved message using HEREDOC
   - Capture hash: `PGXNTOOL_HASH=$(git log -1 --format=%h)`
   - Verify: `git status`

2. **Phase 2: Commit pgxntool-test** (if it has changes)
   - Replace `[PGXNTOOL_COMMIT_HASH]` with captured hash -- a pointer during review only,
     since merging creates new commits; the reference that must survive the merge goes in
     the PR description (see the guide)
   - Stage, verify, commit, verify (same pattern)

For detailed execution steps including pre-commit hook handling, read:
**`.claude/skills/commit/guides/commit-message-format.md`** -> "Two-Phase Commit Execution"

Always use HEREDOC format:
```bash
git commit -m "$(cat <<'EOF'
[message]
EOF
)"
```

## After Pushing: Monitor CI

After any `git push`, monitor CI with the `/ci` skill, per CLAUDE.md "CI Monitoring
After Every Push". Report any CI failures to the user immediately — do not assume they are pre-existing or unrelated.

## Restrictions

- DO NOT push unless explicitly asked
- Force-pushing master/the default branch is never an agent's call (sole exception:
  `crossref-audit` Step 4).
- DO NOT force-push a PR branch without asking first. It is lower risk (unmerged history
  belonging only to that PR), but in this repo pairing ask a literal question ("this needs a
  force-push to `<branch>` -- go ahead?") and wait for a real reply, every time -- including
  for your own unreviewed draft PR, and including when a rebase/restructure task seems to
  require rewriting history. A task *implying* a rewrite is a signal to ask, never a
  substitute for asking. Otherwise add a new commit. This is a deliberate exception to
  `../ai/PR.md`'s "Force-push / history rewriting" section.
- DO NOT commit files with secrets (.env, credentials.json)
- Never use `-i` flags (git commit -i, git rebase -i)
