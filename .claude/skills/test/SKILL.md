---
name: test
description: |
  Run tests with TAP parsing, progress tracking, and strict failure/skip enforcement.
  Parses output into compact summaries to reduce token consumption.

  Use when: "run tests", "test", "/test"
allowed-tools: Bash(bash .claude/skills/test/scripts/*), Read
---

# Test Runner Skill

Run tests with structured output parsing. Both failures AND skips are problems.

## Usage

- `/test` - Run `test-all` (default)
- `/test test` - Run `make test` (standard tests only)
- `/test test-extra` - Run extra tests only
- `/test test/standard/doc.bats` - Run a specific test file

## Workflow

### 1. Launch Tests (Background)

Run `run-tests.sh` in background:

```bash
bash .claude/skills/test/scripts/run-tests.sh [target]
```

Use `run_in_background: true` by default so work can continue.

### 2. Check Progress (Optional)

Read the status file to check mid-run progress:
- Path: `/tmp/pgxntool-test-logs<encoded-cwd>/status`
- Shows: state, suite count, pass/fail/skip counts, current test

### 3. Read Results

When the background task completes, read the summary from the task output.

### 4. Enforce Results

**CRITICAL RULES:**

1. If STATUS is `FAIL`: **STOP immediately**. Report failures to user. Do not proceed with any other work. `FAIL` also covers a non-zero command exit, zero tests run, and a TAP plan/count mismatch, even with no `not ok` lines; the `REASON:` line after `STATUS:` says which applied.
2. If STATUS is `PASS_WITH_SKIPS`: **STOP and report**. Skips are test problems that need investigation, not things to dismiss.
3. Only STATUS `PASS` with zero skips is acceptable.
4. **Never rationalize** failures or skips as "pre-existing", "expected", or "unrelated".
5. This applies to ALL test runs - smoke tests, verification runs, everything. There are no "informational" test runs where failures are OK.
6. To investigate: read the errors log or skips log (paths are in the summary).
7. For full raw output: read the full log file.

## Key Rules

1. **ALWAYS** use this skill to run tests - never `make test*` or `bats` directly
2. Both failures AND skips are test problems - never dismiss either
3. Run in background by default
4. The summary is compact by design - avoid reading the full log unless investigating a specific failure
