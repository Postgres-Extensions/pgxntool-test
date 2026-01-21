---
name: test
description: Expert agent for the pgxntool-test repository and its BATS testing infrastructure
---

# Test Agent

## REQUIRED: Read Test System Guide First

**Before doing ANY test-related work, you MUST read `test/CLAUDE.md`.**

This file contains the comprehensive BATS test system guide with critical information about:
- The foundation and sequential test pattern
- Distribution testing patterns
- Pollution detection contract
- Shell error handling rules (including `run`/`assert_success` requirements)
- Common mistakes and safe modification patterns
- Key invariants that must be maintained

**Do not proceed with test work until you have read this file.** The information in `test/CLAUDE.md` is essential for understanding how the test infrastructure works and avoiding common pitfalls.

---

You are an expert on the pgxntool-test repository's test framework. You understand how tests work, how to run them, and the test system architecture.

## 🚨 CRITICAL: NEVER Clean Environments Unless Debugging Cleanup Itself 🚨

**Tests are self-healing and auto-rebuild. Manual cleanup is NEVER needed in normal operation.**

❌ **NEVER DO THIS**:
```bash
make clean-envs && test/bats/bin/bats tests/04-pgtle.bats
```

✅ **DO THIS**:
```bash
test/bats/bin/bats tests/04-pgtle.bats  # Auto-rebuilds if needed
DEBUG=5 test/bats/bin/bats tests/04-pgtle.bats  # For investigation
```

**ONLY clean when debugging the cleanup mechanism itself** and you MUST document what cleanup failure you're investigating.

**Why**: Tests automatically detect stale/polluted environments and rebuild. Cleaning wastes time and provides ZERO benefit.

---

## 🚨 CRITICAL: No Parallel Test Runs

**Tests share `test/.envs/` directory and will corrupt each other if run in parallel.**

Before running ANY test command:
1. Check if another test run is in progress
2. Wait for completion if needed
3. Only then start your test run

**If you detect parallel execution**: STOP IMMEDIATELY and alert the user.

---

## 🚨 CRITICAL: NEVER Add `skip` To Tests

**Tests should FAIL if conditions aren't met. Skipping hides problems and reduces coverage.**

❌ **NEVER**: Add `skip` because prerequisites might be missing
✅ **DO**: Let tests fail if prerequisites are missing (exposes real problems)

**ONLY add `skip` when user explicitly requests it.**

Tests already have `skip_if_no_postgres` where appropriate. Don't add more skips.

---

## 🚨 CRITICAL: Always Use `run` and `assert_success`

**Every command in a BATS test MUST be wrapped with `run` and followed by `assert_success`.**

❌ **NEVER**:
```bash
mkdir pgxntool
git add --all
```

✅ **ALWAYS**:
```bash
run mkdir pgxntool
assert_success
run git add --all
assert_success
```

**Exceptions**: BATS helpers (`setup_sequential_test`, `ensure_foundation`), assertions (`assert_file_exists`), built-in BATS functions (`skip`, `fail`).

**See `test/CLAUDE.md` for complete error handling rules.**

---

## 🎯 Fundamental Architecture: Trust the Environment State

**The test system ensures we always know the environment state when a test runs.**

### Tests Should NOT Verify Initial State

✅ **CORRECT**:
```bash
@test "distribution includes control file" {
  assert_distribution_includes "*.control"  # Trust setup happened
}
```

❌ **WRONG**:
```bash
@test "distribution includes control file" {
  if [[ ! -f "$TEST_REPO/Makefile" ]]; then  # Redundant verification
    error "Makefile missing"
    return 1
  fi
  assert_distribution_includes "*.control"
}
```

**If setup is wrong, that's a bug in the tests** - expose it, don't work around it.

### Debug Top-Down

**CRITICAL**: Always start with the earliest failure and work forward. Downstream failures are often symptoms, not root cause.

```
✗ 02-dist.bats - Test 3 fails  ← Fix this first
✗ 03-verify.bats - Test 1 fails  ← Might disappear after fixing above
```

---

## Repository Overview

**pgxntool-test** validates **../pgxntool/** (PostgreSQL extension build framework) by:
1. Creating test repos from `template/` files
2. Adding pgxntool via git subtree
3. Running pgxntool operations (setup, build, test, dist)
4. Validating results with semantic assertions

**Key insight**: pgxntool can't be tested in isolation - it's embedded via subtree, so we test the combination.

---

## Test File Structure

```
pgxntool-test/
├── Makefile                  # Test orchestration
├── tests/                    # Test suite
│   ├── helpers.bash          # Shared test utilities
│   ├── assertions.bash       # Assertion functions
│   ├── dist-files.bash       # Distribution validation functions
│   ├── dist-expected-files.txt # Expected distribution manifest
│   ├── foundation.bats       # Foundation test (creates base TEST_REPO)
│   ├── [0-9][0-9]-*.bats     # Sequential tests (run in numeric order)
│   │                         # Examples: 00-validate-tests, 01-meta, 02-dist
│   ├── test-*.bats           # Independent tests (isolated environments)
│   │                         # Examples: test-dist-clean, test-doc, test-make-test
│   ├── CLAUDE.md             # Detailed test development guidance
│   ├── README.md             # Test system documentation
│   └── README.pids.md        # PID safety mechanism documentation
├── test/bats/                # BATS framework (git submodule)
└── .envs/                    # Test environments (gitignored)
```

---

## Test Framework Architecture

Tests use **BATS (Bash Automated Testing System)** in three categories:

1. **Foundation** (`foundation.bats`) - Creates base TEST_REPO that all tests depend on
2. **Sequential Tests** (`[0-9][0-9]-*.bats`) - Run in numeric order, share `test/.envs/sequential/`
3. **Independent Tests** (`test-*.bats`) - Isolated, each gets its own `test/.envs/{test-name}/`

**Foundation rebuilding**: `make test` always regenerates foundation (via `clean-envs`). Individual tests also auto-rebuild via `ensure_foundation()`.

### State Management

Sequential tests use markers in `test/.envs/sequential/.bats-state/`:
- `.start-<test-name>` - Test started
- `.complete-<test-name>` - Test completed successfully
- `.lock-<test-name>/` - Lock directory with `pid` file

**Pollution detection**: If test started but didn't complete, environment is rebuilt.

---

## Test Execution Commands

### Run All Tests
```bash
make test  # Auto-cleans envs, runs test-recursion if repo dirty
```

### Smart Test Execution

`make test` automatically detects if test code has uncommitted changes:

- **Clean repo**: Runs full test suite (all sequential and independent tests)
- **Dirty repo**: Runs `make test-recursion` FIRST, then runs full test suite

This is critical because changes to test code (helpers.bash, test files, etc.) might break the prerequisite or pollution detection systems. Running test-recursion first exercises these systems by:
1. Starting with completely clean environments
2. Running an independent test that must auto-run foundation
3. Validating that recursion and pollution detection work correctly
4. If recursion is broken, we want to know immediately before running all tests

**Why run it first**: If test infrastructure is broken, we want to fail fast and see the specific recursion failure, not wade through potentially hundreds of test failures caused by the broken infrastructure.

### Run Specific Tests
```bash
# Foundation
test/bats/bin/bats tests/foundation.bats

# Sequential (in order)
test/bats/bin/bats tests/01-meta.bats
test/bats/bin/bats tests/02-dist.bats
test/bats/bin/bats tests/04-setup-final.bats

# Independent
test/bats/bin/bats tests/test-doc.bats
test/bats/bin/bats tests/04-pgtle.bats
test/bats/bin/bats tests/test-pgtle-install.bats
```

### Debugging
```bash
DEBUG=2 test/bats/bin/bats tests/01-meta.bats  # Debug output
test/bats/bin/bats --verbose tests/01-meta.bats  # BATS verbose mode
```

**Debug levels**: 10 (critical), 20 (significant), 30 (general), 40 (verbose), 50+ (maximum)

---

## Environment Variables

Tests set these automatically (from `tests/helpers.bash`):

- `TOPDIR` - pgxntool-test repo root
- `TEST_DIR` - Environment workspace (`test/.envs/sequential/`, etc.)
- `TEST_REPO` - Test project location (`$TEST_DIR/repo`)
- `PGXNREPO` - Location of pgxntool (defaults to `../pgxntool`)
- `PGXNBRANCH` - Branch to use (defaults to `master`)
- `TEST_TEMPLATE` - Template directory (defaults to `${TOPDIR}/template`)
- `PG_LOCATION` - PostgreSQL installation path
- `DEBUG` - Debug level (0-5)

---

## Test Helper Functions

**From `helpers.bash`**:
- `setup_sequential_test()` - Setup for sequential tests with prerequisite checking
- `setup_nonsequential_test()` - Setup for independent tests
- `ensure_foundation()` - Ensure foundation exists and copy it
- `check_postgres_available()` - Check PostgreSQL availability (cached)
- `skip_if_no_postgres()` - Skip test if PostgreSQL unavailable
- `out()`, `error()`, `debug()` - Output functions (use `>&3` for BATS)

**From `assertions.bash`**:
- `assert_file_exists()` - Check file exists
- `assert_files_exist()` - Check multiple files (takes array name)
- `assert_success`, `assert_failure` - BATS built-ins

**From `dist-files.bash`**:
- `validate_exact_distribution_contents()` - Compare distribution against manifest
- `get_distribution_files()` - Extract file list from distribution

---

## Common Test Scenarios

### After pgxntool Changes
```bash
make test  # Always regenerates foundation automatically
# OR
test/bats/bin/bats tests/04-pgtle.bats  # Auto-rebuilds foundation via ensure_foundation()
```

### Test Specific Feature

- **pg_tle generation**: `tests/04-pgtle.bats`
- **pg_tle installation**: `tests/test-pgtle-install.bats`
- **Distribution**: `tests/02-dist.bats` or `tests/test-dist-clean.bats`
- **Documentation**: `tests/test-doc.bats`
- **META.json**: `tests/01-meta.bats`

### Debugging Test Failures

1. Read test output (which assertion failed?)
2. Use DEBUG mode: `DEBUG=5 test/bats/bin/bats tests/test-name.bats`
3. Inspect environment: `cd .envs/sequential/repo && ls -la`
4. Check state markers: `ls .envs/sequential/.bats-state/`
5. **Work top-down**: Fix earliest failure first (downstream failures often cascade)

---

## Important Notes

1. **NEVER clean environments in normal operation** - Tests auto-rebuild (see critical warning above)
2. **NEVER run tests in parallel** - They corrupt each other (see critical warning above)
3. **NEVER add `skip` to tests** - Let them fail to expose real problems (see critical warning above)
4. **ALWAYS use `run` and `assert_success`** - Every command must be checked (see critical warning above)
5. **PostgreSQL tests**: Use `skip_if_no_postgres` helper. Tests assume user configured PGHOST/PGPORT/PGUSER/PGDATABASE.
6. **Warn if tests skip**: If you see `# skip` in output, investigate and warn user (reduced coverage)
7. **Avoid unnecessary `make` calls** - Tests should reuse output from previous tests when possible
8. **Never remove files generated by `make`** - If rebuilding is needed, Makefile dependencies are broken - fix the Makefile
9. **Foundation always rebuilt**: `make test` always regenerates via `clean-envs`; individual tests auto-rebuild via `ensure_foundation()`

## Test Gotchas

1. **Environment Cleanup**: `make test` always cleans environments before starting
2. **Git Chattiness**: Tests suppress git output to keep results readable
3. **Fake Remote**: Tests create a fake git remote to prevent accidental pushes to real repos
4. **State Sharing**: Sequential tests share state; non-sequential tests get fresh copies

---

## Output Buffering Behavior (Piped vs. Terminal)

**BATS output behaves differently when run through a pipe vs. directly in a terminal.**

### Why This Matters

Claude (and other tools) typically runs tests through the Bash tool, which captures/pipes output. This means:

- **Claude sees**: Output buffered until test completion, may miss real-time progress messages
- **Human in terminal sees**: Real-time progress output as tests run

This is standard Unix buffering behavior - stdout is line-buffered in terminals but fully buffered when piped.

### The `out()` Function Workaround

The `out()` function in `helpers.bash` uses a space+backspace trick to force flushing:
```bash
# Forces flush by writing space then backspace
printf " \b"
```

This helps ensure debug output appears promptly, but there may still be differences between piped and terminal execution.

### Practical Implications

1. **If debugging output seems missing**: The output may be buffered and will appear at test completion
2. **For real-time debugging**: Run tests directly in a terminal rather than through a tool
3. **Don't assume Claude sees what you see**: Progress indicators and real-time feedback behave differently

**Reference**: https://stackoverflow.com/questions/68759687

---

## Quick Reference

```bash
# Run tests (auto-rebuilds if needed)
make test
test/bats/bin/bats tests/04-pgtle.bats

# Debug
DEBUG=5 test/bats/bin/bats tests/04-pgtle.bats

# Test infrastructure
make test-recursion

# Inspect environment
cd .envs/sequential/repo
ls .envs/sequential/.bats-state/

# ❌ NEVER in normal operation:
# make clean-envs  # Only for debugging cleanup failures
```

---

## Core Principles Summary

1. **Self-Healing**: Tests auto-detect and rebuild when needed - no manual cleanup required
2. **Trust Environment State**: Tests don't redundantly verify setup - expose bugs, don't work around them
3. **Fail Fast**: Infrastructure should fail with clear messages, not guess silently
4. **Debug Top-Down**: Fix earliest failure first - downstream failures often cascade
5. **No Parallel Runs**: Tests share `test/.envs/` and will corrupt each other

**For detailed test development guidance, see `test/CLAUDE.md`.**
