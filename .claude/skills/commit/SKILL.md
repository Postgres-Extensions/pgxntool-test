---
name: commit
description: |
  Create git commits across pgxntool and pgxntool-test repositories following project
  standards. Preprocesses repo info, runs tests, drafts cross-referenced commit messages,
  and executes two-phase commits with hash injection.

  Use when: "commit", "create commit", "commit changes", "/commit"
allowed-tools: Bash(git status:*), Bash(git log:*), Bash(git add:*), Bash(git diff:*), Bash(git commit:*), Bash(git branch:*), Bash(bash .claude/skills/commit/scripts/*), Read, Edit, Task, Skill(test)
---

# Commit Skill

Create git commits following project standards and safety protocols for pgxntool-test.

## Critical Requirements

| Rule | Details |
|------|---------|
| **Git Safety** | Never update git config. Never force push. Never skip hooks unless requested. |
| **Attribution** | No "Generated with Claude Code" in body. Co-Authored-By trailer is OK. |
| **Multi-Repo** | Commit BOTH repos if both have changes (unless told otherwise). No empty commits. Never create a branch on a repo that has no changes. |
| **Testing** | ALL tests must pass. ANY failure = STOP and ask user. No rationalizing failures. |
| **HISTORY.asc** | Update for significant user-visible pgxntool changes. Propose entry, get confirmation. |

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

Review output. Identify which repos have changes.

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
   - Replace `[PGXNTOOL_COMMIT_HASH]` with captured hash
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

## Restrictions

- DO NOT push unless explicitly asked
- DO NOT commit files with secrets (.env, credentials.json)
- Never use `-i` flags (git commit -i, git rebase -i)
