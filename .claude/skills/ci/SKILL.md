---
name: ci
description: |
  Monitor GitHub Actions CI runs for pgxntool and/or pgxntool-test after a push.
  Reports which branches are under test, per-job pass/fail, and failure details.
  Uses shell scripts for all heavy work to minimize context consumption.

  Use when: "monitor CI", "watch CI", "check CI", "/ci"
allowed-tools: Bash(bash .claude/skills/ci/scripts/*), Read
---

# CI Monitor Skill

Monitor GitHub Actions CI across both repos after a push. Always run in background.

## Usage

- `/ci` — monitor the most recent CI run on both repos for the current branch
- `/ci pgxntool-test` — monitor pgxntool-test only
- `/ci pgxntool` — monitor pgxntool only
- `/ci <branch> <pgxntool-sha> <pgxntool-test-sha>` — monitor specific push SHAs (most reliable)

## Workflow

### 1. Start Monitor (Background)

After every `git push`, immediately launch:

```bash
bash .claude/skills/ci/scripts/monitor-ci.sh [repos] [branch] [sha1] [sha2]
```

Arguments:
- `repos`: `both` (default), `pgxntool-test`, or `pgxntool`
- `branch`: the branch just pushed (default: current git branch)
- `sha1`: SHA pushed to pgxntool-test (optional but recommended)
- `sha2`: SHA pushed to pgxntool (optional but recommended)

When pushing to both repos, always pass the SHAs to avoid a race condition where
`--branch` might pick up a different concurrent push on the same branch.

> **Race condition note**: `gh run list --branch` returns the most recent run on
> that branch — if two pushes happen close together (e.g. two sessions pushing
> in parallel), it may pick up the wrong run. Passing `--commit SHA` targets the
> exact push and avoids this. When SHA is unavailable, always verify the
> `=== BRANCHES: ===` line in the output matches the code you pushed.

**Always use `run_in_background: true`.**

### 2. Read Results

When the background task completes, read the output. The script emits:

```text
[pgxntool-test] Run 12345678 found
[pgxntool-test] === BRANCHES: pgxntool-test=feature/foo pgxntool=feature/foo ===
[pgxntool-test] Polling... (running: 🐘 PostgreSQL 13, 🐘 PostgreSQL 15)
[pgxntool-test] PASS  🐘 PostgreSQL 12
[pgxntool-test] PASS  🐘 PostgreSQL 15
[pgxntool-test] FAIL  🐘 PostgreSQL 13
[pgxntool-test] Run completed: FAILURE
[pgxntool-test] === FAILURE: 🐘 PostgreSQL 13 ===
... failure log lines ...
OVERALL: FAIL
```

The **last line is always `OVERALL: <STATUS>`**. Check this first:

| OVERALL | Exit code | Meaning |
|---------|-----------|---------|
| `ALL_PASS` | 0 | All jobs green — safe to proceed |
| `FAIL` | 1 | One or more jobs failed — stop and report |
| `TIMEOUT` | 2 | Run(s) did not complete within timeout |

**Always verify the `=== BRANCHES ===` line** matches the code you just pushed —
this is your primary safeguard against the `--branch` race condition. If the
branches don't match, cancel the run and re-trigger: `gh run cancel <id> --repo
<repo>` then re-push or re-run via `gh run rerun`.

### 3. Enforce Results

**CRITICAL RULES:**

1. Any CI failure must be **reported to the user immediately**. Do not continue with other work.
2. Start diagnosis from the **first** `not ok` line to understand the root cause, but do not assume later failures are cascading or caused by it — treat each failure as likely real and needing its own investigation. Failures in separate test files are typically unrelated; even multiple failures within the same file may be independent.
3. Failures in our workflow files (dependency installs, git config, etc.) are our problem to fix.
4. Failures in test code (not ok from BATS) may be pre-existing — report to user and ask before touching test files.
5. Never rationalize failures as "pre-existing" or "unrelated" without explicitly telling the user.
6. If CI is taking longer than expected on pgxntool, it may be waiting up to 20 min for pgxntool-test CI to complete — that is normal.

## Key rules

1. **ALWAYS** monitor CI after every push — use this skill, never `gh run watch` directly
2. When pushing to both repos, start two background monitors simultaneously (one per repo)
3. Pass the exact push SHA when available — `--branch` has a race condition on rapid pushes
4. The `=== BRANCHES ===` line in the output confirms which code is under test — always verify it matches your intent
