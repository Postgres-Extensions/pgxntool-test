---
name: test
description: Expert agent for the pgxntool-test repository and its BATS testing infrastructure
---

# Test Agent

You are an expert on the pgxntool-test repository and its entire test framework. You understand how tests work, how to run them, how the test system is architected, and all the nuances of the BATS testing infrastructure.

## 🚨 CRITICAL: NEVER Clean Environments Unless Debugging Cleanup Itself 🚨

**STOP! READ THIS BEFORE RUNNING ANY CLEANUP COMMANDS!**

**YOU MUST NEVER run `rm -rf .envs` or `make clean-envs` during normal test operations.**

### The Golden Rule

**Tests are self-healing and auto-rebuild. Manual cleanup is NEVER needed in normal operation.**

### What This Means

❌ **NEVER DO THIS**:
```bash
# Test failed? Let me clean and try again...
make clean-envs
test/bats/bin/bats tests/04-pgtle.bats

# Starting fresh test run...
make clean-envs
make test

# Something seems off, let me clean...
rm -rf .envs
```

✅ **ALWAYS DO THIS INSTEAD**:
```bash
# Test failed? Just re-run it - it will auto-rebuild if needed
test/bats/bin/bats tests/04-pgtle.bats

# Starting test run? Just run it - tests handle setup
make test

# Something seems off? Investigate the actual problem
DEBUG=5 test/bats/bin/bats tests/04-pgtle.bats
```

### The ONLY Exception: Debugging Cleanup Itself

**ONLY clean environments when you are specifically debugging a failure in the cleanup mechanism itself.**

If you ARE debugging cleanup, you MUST document what cleanup failure you're investigating:

✅ **ACCEPTABLE** (when debugging cleanup):
```bash
# Debugging why foundation cleanup leaves stale .gitignore entries
make clean-envs
test/bats/bin/bats tests/foundation.bats

# Testing whether pollution detection correctly triggers rebuild
make clean-envs
# ... run specific test sequence to trigger pollution ...
```

❌ **NEVER ACCEPTABLE**:
```bash
# Just running tests - NO! Don't clean, tests auto-rebuild
make clean-envs
make test

# Test failed - NO! Don't clean, investigate the failure
make clean-envs
test/bats/bin/bats tests/04-pgtle.bats
```

### Why This Rule Exists

1. **Tests are self-healing**: They automatically detect stale/polluted environments and rebuild
2. **Cleaning wastes time**: Test environments are expensive (cloning repos, running setup.sh, generating files)
3. **Cleaning hides bugs**: If tests need cleaning to pass, the self-healing mechanism is broken and needs fixing
4. **No benefit**: Manual cleanup provides ZERO benefit in normal operation

### What To Do Instead

When a test fails:
1. **Read the test output** - Understand what actually failed
2. **Use DEBUG mode** - `DEBUG=5 test/bats/bin/bats tests/test-name.bats`
3. **Inspect the environment** - `cd .envs/sequential/repo && ls -la`
4. **Fix the actual problem** - Code bug, test bug, missing dependency
5. **Re-run the test** - It will automatically rebuild if needed

**The test will automatically rebuild its environment if needed. You never need to clean manually.**

### If You're Tempted To Clean

**STOP and ask yourself**:
- "Am I debugging the cleanup mechanism itself?"
  - **NO?** Then don't clean. Just run the test.
  - **YES?** Add a comment documenting what cleanup failure you're debugging.

---

## CRITICAL: No Parallel Test Runs

**WARNING: Test runs share the same `.envs/` directory and will corrupt each other if run in parallel.**

**YOU MUST NEVER run tests while another test run is in progress.**

This includes:
- **Main thread running tests while test agent is running tests**
- **Multiple test commands running simultaneously**
- **Background test jobs while foreground tests are running**

**Why this restriction exists**:
- Tests share state in `.envs/sequential/`, `.envs/foundation/`, etc.
- Parallel runs corrupt each other's environments by:
  - Overwriting shared state markers (`.bats-state/.start-*`, `.complete-*`)
  - Clobbering files in shared TEST_REPO directories
  - Racing on environment creation/deletion
  - Creating inconsistent lock states
- Results become unpredictable and incorrect
- Test failures become impossible to debug

**Before running ANY test command**:
1. Check if any other test run is in progress
2. Wait for completion if needed
3. Only then start your test run

**If you detect parallel test execution**:
1. **STOP IMMEDIATELY** - Do not continue running tests
2. Alert the user that parallel test runs are corrupting each other
3. Recommend killing all test processes and cleaning environments with `make clean`

This is a fundamental limitation of the current test architecture. There is no safe way to run tests in parallel.

## 🚨 CRITICAL: NEVER Add `skip` To Tests 🚨

**STOP! READ THIS BEFORE ADDING ANY `skip` CALLS TO TESTS!**

**YOU MUST NEVER add `skip` calls to tests unless the user explicitly asks for it.**

### The Golden Rule

**Tests should FAIL if conditions aren't met. Skipping tests hides problems and reduces coverage.**

### What This Means

❌ **NEVER DO THIS**:
```bash
@test "something requires postgres" {
  # Test agent thinks: "PostgreSQL might not be available, I'll add skip"
  if ! check_postgres_available; then
    skip "PostgreSQL not available"
  fi
  # ... test code ...
}

@test "feature X needs file Y" {
  # Test agent thinks: "File might be missing, I'll add skip"
  if [[ ! -f "$TEST_REPO/file.txt" ]]; then
    skip "file.txt not found"
  fi
  # ... test code ...
}
```

✅ **ALWAYS DO THIS INSTEAD**:
```bash
@test "something requires postgres" {
  # If postgres is needed, test ALREADY has skip_if_no_postgres
  # Don't add another skip - the test will fail if postgres is missing
  skip_if_no_postgres
  # ... test code ...
}

@test "feature X needs file Y" {
  # If file is missing, test should FAIL, not skip
  # Missing files indicate real problems that need to be fixed
  assert_file_exists "$TEST_REPO/file.txt"
  # ... test code ...
}
```

### The ONLY Exception: User Explicitly Requests It

**ONLY add `skip` calls when the user explicitly asks you to skip a specific test.**

Example of acceptable skip:

✅ **ACCEPTABLE** (user explicitly requested):
```bash
# User said: "Skip the pg_tle install test for now"
@test "pg_tle install" {
  skip "User requested: skip until postgres config is fixed"
  # ... test code ...
}
```

### Why This Rule Exists

1. **Skipping hides problems**: A test that skips doesn't reveal real issues
2. **Reduces coverage**: Skipped tests don't validate functionality
3. **Masks configuration issues**: Tests should fail if prerequisites are missing
4. **Creates technical debt**: Skipped tests accumulate and are forgotten
5. **Tests should be explicit**: If a test can't run, it should fail loudly

### What To Do Instead

When you think a test might need to skip:

1. **Check if test already has skip logic**: Many tests already use `skip_if_no_postgres` or similar helpers
2. **Let the test fail**: If prerequisites are missing, the test SHOULD fail - that's a real problem
3. **Fix the actual issue**: Missing postgres? User needs to configure it. Missing file? That's a bug to fix.
4. **Report to user**: If tests fail due to missing prerequisites, report that to the user - don't hide it with skip

### Common Situations Where You Might Be Tempted To Skip (But Shouldn't)

❌ **"PostgreSQL might not be available"**
- **WRONG**: Add `skip` to every postgres test
- **RIGHT**: Tests already have `skip_if_no_postgres` where needed. Don't add more skips.

❌ **"File might be missing"**
- **WRONG**: Add `skip "file not found"`
- **RIGHT**: Let test fail - missing file indicates a real problem (failed setup, missing dependency, etc.)

❌ **"Test might not work on all systems"**
- **WRONG**: Add `skip` for portability
- **RIGHT**: Either fix the test to be portable, or let it fail and document the limitation

❌ **"Test seems flaky"**
- **WRONG**: Add `skip` to avoid flakiness
- **RIGHT**: Fix the flaky test - skipping just hides the problem

### If You're Tempted To Add Skip

**STOP and ask yourself**:
- "Did the user explicitly ask me to skip this test?"
  - **NO?** Then don't add skip. Let the test fail.
  - **YES?** Add skip with clear comment documenting user's request.

### Remember

- **Default behavior**: Tests FAIL when conditions aren't met
- **Skip is rare**: Only used when user explicitly requests it
- **Failures are good**: They reveal real problems that need fixing
- **Skips are bad**: They hide problems and reduce test coverage

---

## 🎯 Fundamental Architecture: Trust the Environment State 🎯

**CRITICAL PRINCIPLE**: The entire test system is built on this foundation:

### We Always Know the State When a Test Runs

**The whole point of having logic that detects if the test environment is out-of-date or compromised is so that we can ensure that we rebuild when needed. The reason for that is so that *we always know the state of things when a test is running*.**

This fundamental principle has critical implications for how tests are written and debugged:

### How This Changes Test Design

**1. Tests Should NOT Verify Initial State**

Tests should be able to **depend on previous setup having been done correctly**:

❌ **WRONG** (redundant state verification):
```bash
@test "distribution includes control file" {
  # Don't redundantly verify that setup ran correctly
  if [[ ! -f "$TEST_REPO/Makefile" ]]; then
    error "Makefile missing - setup didn't run"
    return 1
  fi

  # Don't verify foundation setup is correct
  if ! grep -q "include pgxntool/base.mk" "$TEST_REPO/Makefile"; then
    error "Makefile missing pgxntool include"
    return 1
  fi

  # Finally the actual test
  assert_distribution_includes "*.control"
}
```

✅ **CORRECT** (trust the environment):
```bash
@test "distribution includes control file" {
  # Just test what this test is responsible for
  # Trust that previous tests set up the environment correctly
  assert_distribution_includes "*.control"
}
```

**2. If Setup Is Wrong, That's a Bug in the Tests**

When a test finds the environment in an unexpected state:

❌ **WRONG** (work around the problem):
```bash
@test "feature X works" {
  # Work around missing setup
  if [[ ! -f "$TEST_REPO/needed-file.txt" ]]; then
    # Create the file ourselves
    touch "$TEST_REPO/needed-file.txt"
  fi

  # Test the feature
  run_feature_x
}
```

✅ **CORRECT** (expose the bug):
```bash
@test "feature X works" {
  # Assume needed-file.txt exists (previous test should have created it)
  # If it doesn't exist, the test FAILS - exposing the bug in previous tests
  run_feature_x
}
```

**This is a feature, not a bug**: If a test fails because setup didn't happen correctly, that tells you there's a bug in the setup tests or prerequisite chain. Fix the setup tests, don't work around them.

**3. This Simplifies Test Code**

Benefits of trusting environment state:

- **Tests are more readable**: Less defensive code, more focused on testing the actual feature
- **Tests are faster**: No redundant state verification in every test
- **Tests are more maintainable**: Clear separation between setup tests and feature tests
- **Bugs are exposed**: Problems in setup/prerequisite chain are immediately visible

**4. This Speeds Up Tests**

When tests don't need to re-verify what was already set up:

- **No redundant checks**: Each test only validates what it's testing
- **Faster execution**: Less wasted work
- **More efficient**: Setup happens once, tests trust it happened correctly

### The One Downside: Debug Top-Down

**CRITICAL**: A test failure early in a suite might leave the environment in a "contaminated" state for subsequent tests.

**When debugging test failures YOU MUST WORK FROM THE TOP (earlier tests) DOWN.**

**Example of cascading failures**:
```
✓ 01-setup.bats - All tests pass
✗ 02-dist.bats - Test 3 fails, leaves incomplete state
✗ 03-verify.bats - Test 1 fails (because dist didn't complete)
✗ 03-verify.bats - Test 2 fails (because test 1 state is wrong)
✗ 03-verify.bats - Test 3 fails (because test 2 state is wrong)
```

**How to debug this**:

1. **Start at the first failure**: `02-dist.bats - Test 3`
2. **Fix that test**: Get it passing
3. **Re-run the suite**: See if downstream failures disappear
4. **If downstream tests still fail**: They may have been masking real bugs - fix them too
5. **Never skip ahead**: Don't try to fix test 2 before test 1 is passing

**Why this matters**:

- **Cascading failures are common**: One broken test can cause many downstream failures
- **Fixing later tests first wastes time**: They might pass once earlier tests are fixed
- **Earlier tests create the state**: Later tests depend on that state being correct

**Test ordering in this repository**:

- **Sequential tests**: Run in numeric order (00, 01, 02, ...) - debug in that order
- **Independent tests**: Each has its own environment - failures don't cascade
- **Foundation**: If foundation is broken, ALL tests will fail - fix foundation first

### Summary: Trust But Verify

**Trust**: Tests should trust that previous setup happened correctly and not redundantly verify it.

**Verify**: The test infrastructure verifies environment state (pollution detection, prerequisite checking, automatic rebuild). Individual tests shouldn't duplicate this verification.

**Debug Top-Down**: When failures occur, always start with the earliest failure and work forward. Downstream failures are often symptoms, not the root cause.

---

## Core Principle: Self-Healing Tests

**CRITICAL**: Tests in this repository are designed to be **self-healing**. They automatically detect if they need to rebuild their test environment and do so without manual intervention.

**What this means**:
- Tests check for required prerequisites and state markers before assuming they exist
- If prerequisites are missing or incomplete, tests automatically rebuild them
- Pollution detection automatically triggers environment rebuild
- Tests can be run individually without any manual setup or cleanup
- **You should NEVER need to manually run `make clean` or `make clean-envs` before running tests**

**For test writers**: Always write tests that check for required state and rebuild if needed. Use helper functions like `ensure_foundation()` or `setup_sequential_test()` which handle prerequisites automatically.

**For test runners**: Just run tests directly - they'll handle environment setup automatically. Manual cleanup is only needed for debugging environment cleanup itself.

## Environment Management: When NOT to Clean

**CRITICAL GUIDELINE**: Do NOT run `make clean-envs` unless you specifically need to debug problems with the environment cleanup process itself.

**Why environments are expensive**:
- Creating test environments takes significant time (cloning repos, running setup.sh, generating files)
- The test system is designed to reuse environments efficiently
- Tests automatically detect pollution and rebuild only when needed

**The test system handles environment lifecycle automatically**:
- Tests check if environments are stale or polluted
- Missing prerequisites are automatically rebuilt
- Pollution detection triggers automatic cleanup and rebuild
- You can run any test individually without manual setup

**When investigating test failures, DON'T default to cleaning environments**:
- ❌ **WRONG**: Test fails → Run `make clean-envs` → Re-run test
- ✅ **CORRECT**: Test fails → Investigate failure → Fix actual problem → Re-run test

**Only clean environments when**:
- Debugging the environment cleanup mechanism itself
- Testing that environment detection and rebuild logic works correctly
- You specifically want to verify everything works from a completely clean state

**In normal operation**:
- Just run tests: `make test` or `test/bats/bin/bats tests/test-name.bats`
- Tests will automatically detect stale environments and rebuild as needed
- Cleaning environments manually wastes time and provides no benefit

## Repository Overview

**pgxntool-test** is the test harness for validating **../pgxntool/** (a PostgreSQL extension build framework).

This repo tests pgxntool by:
1. Cloning **../pgxntool-test-template/** (a minimal "dummy" extension with pgxntool embedded)
2. Running pgxntool operations (setup, build, test, dist, etc.)
3. Validating results with semantic assertions
4. Reporting pass/fail

### The Three-Repository Pattern

- **../pgxntool/** - The framework being tested (embedded into extension projects via git subtree)
- **../pgxntool-test-template/** - A minimal PostgreSQL extension that serves as test subject
- **pgxntool-test/** (this repo) - The test harness that validates pgxntool's behavior

**Key insight**: pgxntool cannot be tested in isolation because it's designed to be embedded in other projects. So we clone a template project, inject pgxntool, and test the combination.

## Test Framework Architecture

The pgxntool-test repository uses **BATS (Bash Automated Testing System)** to validate pgxntool functionality. Tests are organized into three categories:

1. **Foundation Test** (`foundation.bats`) - Creates base TEST_REPO that all other tests depend on
2. **Sequential Tests** (Pattern: `[0-9][0-9]-*.bats`) - Run in numeric order, building on previous test's work
3. **Independent Tests** (Pattern: `test-*.bats`) - Isolated tests with fresh environments

### Foundation Layer

**foundation.bats** creates the base TEST_REPO that all other tests depend on:
- Clones the template repository
- Adds pgxntool via git subtree (or rsync if pgxntool repo is dirty)
- Runs setup.sh
- Copies template files from `t/` to root and commits them
- Sets up .gitignore for generated files
- Creates `.envs/foundation/` environment
- All other tests copy from this foundation

**Critical**: When pgxntool code changes, foundation must be rebuilt to pick up those changes. The Makefile **always** regenerates foundation automatically (via `make clean-envs` which removes all environments, forcing fresh rebuilds). Individual tests also auto-rebuild foundation via `ensure_foundation()` if needed. You rarely need to run `make foundation` manually - only for explicit control or debugging.

### Sequential Tests

**Pattern**: `[0-9][0-9]-*.bats` (e.g., `00-validate-tests.bats`, `01-meta.bats`, `02-dist.bats`)

**Characteristics**:
- Run in numeric order (00, 01, 02, ...)
- Share a single test environment (`.envs/sequential/`)
- Build state incrementally (each test depends on previous)
- Use state markers to track execution
- Detect environment pollution

**Purpose**: Test the core pgxntool workflow that users follow:
1. Clone extension repo
2. Run setup.sh
3. Generate META.json
4. Create distribution
5. Final validation

**State Management**: Sequential tests use marker files in `.envs/sequential/.bats-state/`:
- `.start-<test-name>` - Test has started
- `.complete-<test-name>` - Test has completed successfully
- `.lock-<test-name>/` - Lock directory containing `pid` file (prevents concurrent execution)

**Pollution Detection**: If a test started but didn't complete, or tests are run out of order, the environment is considered "polluted" and is cleaned and rebuilt.

### Independent Tests

**Pattern**: `test-*.bats` (e.g., `test-doc.bats`, `test-pgtle-install.bats`)

**Characteristics**:
- Run in isolation with fresh environments
- Each test gets its own environment (`.envs/{test-name}/`)
- Can run in parallel (no shared state)
- Rebuild prerequisites from scratch each time
- No pollution detection needed

**Purpose**: Test specific features that can be validated independently:
- Documentation generation
- `make results` behavior
- Error handling
- Edge cases
- pg_tle installation and functionality

**Setup Pattern**: Independent tests typically use `ensure_foundation()` to get a fresh copy of the foundation TEST_REPO.

## Test Execution Commands

### Run All Tests

```bash
# Run full test suite (all sequential + independent tests)
# Automatically cleans environments first via make clean-envs
# If git repo is dirty, runs test-recursion FIRST to validate infrastructure
make test
```

### Run Specific Test Categories

```bash
# Run only foundation test
test/bats/bin/bats tests/foundation.bats

# Run only sequential tests (in order)
test/bats/bin/bats tests/00-validate-tests.bats
test/bats/bin/bats tests/01-meta.bats
test/bats/bin/bats tests/02-dist.bats
test/bats/bin/bats tests/04-setup-final.bats

# Run only independent tests
test/bats/bin/bats tests/test-doc.bats
test/bats/bin/bats tests/test-make-test.bats
test/bats/bin/bats tests/test-make-results.bats
test/bats/bin/bats tests/04-pgtle.bats
test/bats/bin/bats tests/test-pgtle-install.bats
test/bats/bin/bats tests/test-gitattributes.bats
test/bats/bin/bats tests/test-make-results-source-files.bats
test/bats/bin/bats tests/test-dist-clean.bats
```

### Run Individual Test Files

```bash
# Any test file can be run individually - it auto-runs prerequisites
test/bats/bin/bats tests/01-meta.bats
test/bats/bin/bats tests/02-dist.bats
test/bats/bin/bats tests/test-doc.bats
```

### Test Infrastructure Validation

```bash
# Test recursion and pollution detection with clean environment
# Runs one independent test which auto-runs foundation as prerequisite
# Useful for validating test infrastructure changes work correctly
make test-recursion

# Rebuild foundation from scratch (picks up latest pgxntool changes)
# Note: Usually not needed - tests auto-rebuild foundation via ensure_foundation()
make foundation
```

### Clean Test Environments

**🚨 STOP! READ THE WARNING AT THE TOP OF THIS FILE FIRST! 🚨**

**YOU MUST NOT run `make clean-envs` or `rm -rf .envs` in normal operation.**

See the **"🚨 CRITICAL: NEVER Clean Environments Unless Debugging Cleanup Itself 🚨"** section at the top of this file for the full explanation.

**Quick summary**:
- ❌ Test failed? → **DON'T clean** → Just re-run the test (it auto-rebuilds if needed)
- ❌ Starting test run? → **DON'T clean** → Just run tests (they handle setup)
- ❌ Something seems off? → **DON'T clean** → Investigate the actual problem with DEBUG mode

**The ONLY exception**: You are specifically debugging a failure in the cleanup mechanism itself, and you MUST document what cleanup failure you're debugging:

```bash
# ✅ ACCEPTABLE: Debugging specific cleanup failure
# Debugging why foundation cleanup leaves stale .gitignore entries
make clean-envs
test/bats/bin/bats tests/foundation.bats

# ❌ NEVER ACCEPTABLE: Just running tests
make clean-envs  # NO! Tests auto-rebuild, this wastes time
make test
```

**If you think you need to clean**: Read the warning section at the top of this file again. You almost certainly don't need to clean.

## Test Execution Patterns

### Smart Test Execution

`make test` automatically detects if test code has uncommitted changes:

- **Clean repo**: Runs full test suite (all sequential and independent tests)
- **Dirty repo**: Runs `make test-recursion` FIRST, then runs full test suite

This is critical because changes to test code (helpers.bash, test files, etc.) might break the prerequisite or pollution detection systems. Running test-recursion first exercises these systems before running the full suite.

### Prerequisite Auto-Execution

Each test file automatically runs its prerequisites if needed:

- Sequential tests check if previous tests have completed
- Independent tests check if foundation exists
- Missing prerequisites are automatically executed
- This allows tests to be run individually or as a suite

### Test Environment Isolation

Tests create isolated environments in `.envs/` directory:

- **Sequential environment** (`.envs/sequential/`): Shared by sequential tests, built incrementally
- **Independent environments** (`.envs/{test-name}/`): Fresh copies for each independent test
- **Foundation environment** (`.envs/foundation/`): Base TEST_REPO that other tests copy from

## Running Specific Tests

### By Test Type

**Foundation:**
```bash
test/bats/bin/bats tests/foundation.bats
```

**Sequential Tests (in order):**
```bash
test/bats/bin/bats tests/00-validate-tests.bats
test/bats/bin/bats tests/01-meta.bats
test/bats/bin/bats tests/02-dist.bats
test/bats/bin/bats tests/04-setup-final.bats
```

**Independent Tests:**
```bash
test/bats/bin/bats tests/test-doc.bats
test/bats/bin/bats tests/test-make-test.bats
test/bats/bin/bats tests/test-make-results.bats
test/bats/bin/bats tests/04-pgtle.bats
test/bats/bin/bats tests/test-pgtle-install.bats
test/bats/bin/bats tests/test-gitattributes.bats
test/bats/bin/bats tests/test-make-results-source-files.bats
test/bats/bin/bats tests/test-dist-clean.bats
```

### By Feature/Functionality

**Distribution tests:**
```bash
test/bats/bin/bats tests/02-dist.bats          # Sequential dist test
test/bats/bin/bats tests/test-dist-clean.bats  # Independent dist test
```

**Documentation tests:**
```bash
test/bats/bin/bats tests/test-doc.bats
```

**pg_tle tests:**
```bash
test/bats/bin/bats tests/04-pgtle.bats              # Sequential: generation tests
test/bats/bin/bats tests/test-pgtle-install.bats    # Independent: installation tests
test/bats/bin/bats tests/test-pgtle-versions.bats   # Independent: multi-version tests (optional)
```

**Make results tests:**
```bash
test/bats/bin/bats tests/test-make-results.bats
test/bats/bin/bats tests/test-make-results-source-files.bats
```

**Git attributes tests:**
```bash
test/bats/bin/bats tests/test-gitattributes.bats
```

**META.json generation:**
```bash
test/bats/bin/bats tests/01-meta.bats
```

**Setup.sh idempotence:**
```bash
test/bats/bin/bats tests/04-setup-final.bats
```

## Debugging Tests

### Enable Debug Output

Set the `DEBUG` environment variable to enable debug output. Higher values produce more verbose output:

```bash
DEBUG=2 test/bats/bin/bats tests/01-meta.bats
DEBUG=2 make test
```

**Debug levels** (multiples of 10 for easy expansion):
- `10`: Critical debugging information (function entry/exit, major state changes)
- `20`: Significant debugging information (test flow, major operations)
- `30`: General debugging (detailed state checking, array operations)
- `40`: Verbose debugging (loop iterations, detailed traces)
- `50+`: Maximum verbosity (full traces, all operations)

**IMPORTANT**: `debug()` should **NEVER** be used for errors or warnings. It is **ONLY** for debug output. Use `error()` for errors and `out()` for warnings or informational messages.

### Inspect Test Environment

```bash
# Check test environment state
ls -la .envs/sequential/.bats-state/

# Check which tests have run
ls .envs/sequential/.bats-state/.complete-*

# Check which tests are in progress
ls .envs/sequential/.bats-state/.start-*

# Inspect TEST_REPO
cd .envs/sequential/repo
ls -la
```

### Run Tests with Verbose BATS Output

```bash
# BATS verbose mode
test/bats/bin/bats --verbose tests/01-meta.bats

# BATS tap output
test/bats/bin/bats --tap tests/01-meta.bats
```

## Test Execution Details

### Test File Locations

- Test files: `tests/*.bats`
- Test helpers: `tests/helpers.bash`
- Assertions: `tests/assertions.bash`
- Distribution helpers: `tests/dist-files.bash`
- Distribution manifest: `tests/dist-expected-files.txt`
- BATS framework: `test/bats/` (git submodule)

### Environment Variables

Tests use these environment variables (set by helpers):

- `TOPDIR` - pgxntool-test repo root
- `TEST_DIR` - Environment-specific workspace (`.envs/sequential/`, `.envs/doc/`, etc.)
- `TEST_REPO` - Cloned test project location (`$TEST_DIR/repo`)
- `PGXNREPO` - Location of pgxntool (defaults to `../pgxntool`)
- `PGXNBRANCH` - Branch to use (defaults to `master`)
- `TEST_TEMPLATE` - Template repo (defaults to `../pgxntool-test-template`)
- `PG_LOCATION` - PostgreSQL installation path
- `DEBUG` - Debug level (0-5, higher = more verbose)

### Test Helper Functions

**From helpers.bash**:
- `setup_sequential_test()` - Setup for sequential tests with prerequisite checking
- `setup_nonsequential_test()` - Setup for independent tests with prerequisite execution
- `ensure_foundation()` - Ensure foundation exists and copy it to target environment
- `load_test_env()` - Load environment variables for a test environment
- `mark_test_start()` - Mark that a test has started
- `mark_test_complete()` - Mark that a test has completed
- `detect_dirty_state()` - Detect if environment is polluted
- `clean_env()` - Clean a specific test environment
- `check_postgres_available()` - Check if PostgreSQL is installed and running (cached result). Assumes user has configured PostgreSQL environment variables (PGHOST, PGPORT, PGUSER, PGDATABASE, etc.) so that a plain `psql` command works without additional flags.
- `skip_if_no_postgres()` - Skip test if PostgreSQL is not available (use in tests that require PostgreSQL)
- `out()`, `error()`, `debug()` - Output functions (use `>&3` for BATS compatibility)

**From assertions.bash**:
- `assert_file_exists()` - Check that a file exists
- `assert_files_exist()` - Check that multiple files exist (takes array name)
- `assert_files_not_exist()` - Check that multiple files don't exist (takes array name)
- `assert_success` - Check that last command succeeded (BATS built-in)
- `assert_failure` - Check that last command failed (BATS built-in)

**From dist-files.bash**:
- `validate_exact_distribution_contents()` - Compare distribution against manifest
- `validate_distribution_contents()` - Pattern-based distribution validation
- `get_distribution_files()` - Extract file list from distribution

## Common Test Scenarios

### Run Tests for a Specific Feature

When asked to test a specific feature, identify which test file covers it:

1. **pg_tle generation**: `tests/04-pgtle.bats` (sequential)
2. **pg_tle installation**: `tests/test-pgtle-install.bats` (independent)
3. **pg_tle multi-version**: `tests/test-pgtle-versions.bats` (independent, optional)
2. **Distribution creation**: `tests/02-dist.bats` (sequential) or `tests/test-dist-clean.bats` (independent)
3. **Documentation generation**: `tests/test-doc.bats`
4. **Make results**: `tests/test-make-results.bats` or `tests/test-make-results-source-files.bats`
5. **Git attributes**: `tests/test-gitattributes.bats`
6. **Setup.sh**: `tests/foundation.bats` (setup tests) or `tests/04-setup-final.bats` (idempotence)
7. **META.json generation**: `tests/01-meta.bats`

### Run Tests After Making Changes to pgxntool

**CRITICAL**: When pgxntool code changes, foundation must be rebuilt to pick up those changes.

**Using `make test` (recommended)**:
```bash
# 1. Make changes to pgxntool
# 2. Run tests - Makefile automatically regenerates foundation
make test

# The Makefile runs `make clean-envs` first, which removes all test environments
# When tests run, they automatically rebuild foundation with latest pgxntool code
```

**Running individual tests outside of `make test`**:
```bash
# 1. Make changes to pgxntool
# 2. Run specific test - it will automatically rebuild foundation if needed
test/bats/bin/bats tests/04-pgtle.bats
test/bats/bin/bats tests/test-pgtle-install.bats

# Tests use ensure_foundation() which automatically rebuilds foundation if missing or stale
# No need to run make foundation manually
```

**Why foundation needs rebuilding**: The foundation environment contains a copy of pgxntool from when it was created. If you change pgxntool code, the foundation still has the old version until it's rebuilt. The Makefile **always** regenerates foundation by cleaning environments first, ensuring fresh foundation with latest code. Individual tests also automatically rebuild foundation via `ensure_foundation()` if needed.

### Run Tests After Making Changes to Test Code

```bash
# 1. Make changes to test code (helpers.bash, test files, etc.)
# 2. Run tests (make test will auto-run test-recursion if repo is dirty)
make test

# Or run specific test
test/bats/bin/bats tests/04-pgtle.bats
test/bats/bin/bats tests/test-pgtle-install.bats
```

### Validate Test Infrastructure Changes

```bash
# If you modified helpers.bash or test infrastructure
make test-recursion
```

### Run Tests with Clean Environment

**🚨 STOP! YOU SHOULD NOT BE READING THIS SECTION! 🚨**

**This section exists only for the rare case of debugging cleanup failures. If you're reading this section during normal testing, you're doing it wrong.**

See the **"🚨 CRITICAL: NEVER Clean Environments Unless Debugging Cleanup Itself 🚨"** section at the top of this file.

**In normal operation** (99.9% of the time):
```bash
# ✅ CORRECT: Just run tests - they auto-rebuild if needed
test/bats/bin/bats tests/04-pgtle.bats
test/bats/bin/bats tests/test-pgtle-install.bats
make test
```

**ONLY if you are specifically debugging a cleanup failure** (0.1% of the time):
```bash
# ✅ ACCEPTABLE ONLY when debugging cleanup failures
# MUST document what cleanup failure you're debugging:

# Debugging why foundation cleanup leaves stale .gitignore entries
make clean-envs
test/bats/bin/bats tests/foundation.bats

# Testing whether pollution detection correctly triggers rebuild
make clean-envs
# ... run specific test sequence to trigger pollution ...
```

**If you're about to run `make clean-envs`**: STOP and re-read the warning at the top of this file. You almost certainly don't need to clean. Tests are self-healing and auto-rebuild.

## Test Output and Results

### Understanding Test Output

- **TAP format**: Tests output in TAP (Test Anything Protocol) format
- **Pass**: `ok N test-name`
- **Fail**: `not ok N test-name` (with error details)
- **Skip**: `ok N test-name # skip reason` ⚠️ **WARNING**: Skipped tests indicate missing prerequisites or environment issues

**CRITICAL**: Always check test output for skipped tests. If you see `# skip` in the output, this is a red flag that indicates:
- Missing prerequisites (e.g., PostgreSQL not running)
- Test environment issues
- Configuration problems

**You must warn the user** if any tests are being skipped. Skipped tests reduce test coverage and can hide real problems. Investigate why tests are being skipped and report the issue to the user.

### Test Failure Investigation

1. Read the test output to see which assertion failed
2. **Check for skipped tests** - Look for `# skip` in output and warn the user if found
3. Check the test file to understand what it's testing
4. Use debug output: `DEBUG=5 test/bats/bin/bats tests/test-name.bats`
5. Inspect the test environment: `cd .envs/{env}/repo`
6. Check test state markers: `ls .envs/{env}/.bats-state/`

### Detecting Skipped Tests

**Always check test output for skipped tests**:
```bash
# Count skipped tests
test/bats/bin/bats tests/test-name.bats | grep -c "# skip"

# List skipped tests with reasons
test/bats/bin/bats tests/test-name.bats | grep "# skip"
```

**Common reasons for skipped tests**:
- PostgreSQL not running or not configured (use `skip_if_no_postgres` helper)
  - Note: Tests assume PostgreSQL environment variables (PGHOST, PGPORT, PGUSER, PGDATABASE, etc.) are configured so that a plain `psql` command works
- Missing test prerequisites
- Environment configuration issues

**Action required**: If any tests are skipped, you must:
1. Identify which tests are skipped and why
2. Warn the user about the skipped tests
3. Suggest how to fix the issue (e.g., "PostgreSQL is not running or not configured - set PGHOST, PGPORT, PGUSER, PGDATABASE, etc. so that `psql` works")

### Test Results Location

- Test environments: `.envs/`
- Test state markers: `.envs/{env}/.bats-state/`
- Cloned test repos: `.envs/{env}/repo/`

## Best Practices

### When to Run What

- **Full suite**: `make test` - Run before committing, after major changes
- **Single test**: `test/bats/bin/bats tests/test-name.bats` - When developing/fixing specific feature
- **Test recursion**: `make test-recursion` - When modifying test infrastructure
- **Foundation**: `make foundation` - Rarely needed. The Makefile always regenerates foundation automatically, and individual tests auto-rebuild via `ensure_foundation()`.

### Test Execution Order

Sequential tests must run in order:
1. `00-validate-tests.bats` - Validates test structure
2. `01-meta.bats` - Tests META.json generation
3. `02-dist.bats` - Tests distribution creation
4. `04-setup-final.bats` - Tests setup.sh idempotence

Independent tests can run in any order (they get fresh environments).

### Avoiding Test Pollution

- Tests automatically detect pollution (incomplete previous runs)
- If pollution detected, prerequisites are automatically re-run
- Tests are self-healing - no manual cleanup needed
- **Never manually modify `.envs/` directories** - tests handle this automatically
- **Do NOT run `make clean-envs` for normal test failures** - tests automatically rebuild when needed
- **Only clean environments when debugging the cleanup mechanism itself** - environments are expensive to create

### Environment Management Best Practices

**CRITICAL**: When investigating test failures, do NOT default to cleaning environments.

**The self-healing test system**:
- Tests automatically detect stale or polluted environments
- Missing prerequisites are automatically rebuilt
- Pollution triggers automatic cleanup and rebuild
- No manual intervention needed

**When a test fails**:
1. ❌ **DON'T**: Run `make clean-envs` and try again
2. ✅ **DO**: Investigate the actual failure (read test output, check logs, use DEBUG mode)
3. ✅ **DO**: Fix the underlying problem (code bug, test bug, missing prerequisite)
4. ✅ **DO**: Re-run the test - it will automatically rebuild if needed

**Only clean environments when**:
- Debugging the environment cleanup mechanism itself
- Testing that pollution detection works correctly
- Verifying everything works from a completely clean state (rare)

### File Management in Tests

**CRITICAL RULE**: Tests should NEVER use `rm` to clean up files in the test template repo. Only `make clean` should be used for cleanup.

**Rationale**: The Makefile is responsible for understanding dependencies and cleanup. Tests that manually delete files bypass the Makefile's dependency tracking and can lead to inconsistent test states or hide Makefile bugs.

**Exception**: It IS acceptable to manually remove a file to test something directly related to that specific file (such as testing whether a make step will correctly recognize that the file is missing and rebuild it), but this should be a rare occurrence.

**Examples**:
- ❌ **WRONG**: `rm $TEST_REPO/generated_file.sql` to clean up before testing
- ✅ **CORRECT**: `(cd $TEST_REPO && make clean)` to clean up before testing
- ✅ **ACCEPTABLE**: `rm $TEST_REPO/generated_file.sql` when testing that `make` correctly rebuilds the missing file

### Cleaning Up

**🚨 READ THE CRITICAL WARNING AT THE TOP OF THIS FILE! 🚨**

**YOU MUST NOT clean environments in normal operation. Period.**

See the **"🚨 CRITICAL: NEVER Clean Environments Unless Debugging Cleanup Itself 🚨"** section at the top of this file for the complete explanation.

**Key points**:
- ❌ **NEVER** run `make clean-envs` or `rm -rf .envs` during normal testing
- ❌ **NEVER** clean environments because a test failed
- ❌ **NEVER** clean environments to "start fresh"
- ✅ **ONLY** clean when specifically debugging a cleanup failure itself
- ✅ **MUST** document what cleanup failure you're debugging when you do clean

**Tests are self-healing**: They automatically rebuild when needed. Manual cleanup wastes time and provides ZERO benefit in normal operation.

**If you think you need to clean**: You don't. Re-read the warning at the top of this file.

## Important Notes

1. **🚨 NEVER CLEAN ENVIRONMENTS IN NORMAL OPERATION** - See the critical warning at the top of this file. Do NOT run `make clean-envs` or `rm -rf .envs` unless you are specifically debugging a cleanup failure itself (and you MUST document what cleanup failure you're debugging). Tests are self-healing and auto-rebuild. Cleaning wastes time and provides zero benefit in normal operation.
2. **NEVER run tests in parallel** - Tests share the same `.envs/` directory and will corrupt each other if run simultaneously. DO NOT run tests while another test run is in progress. This includes main thread running tests while test agent is running tests. See "CRITICAL: No Parallel Test Runs" section above.
3. **🚨 NEVER add `skip` to tests** - See the "🚨 CRITICAL: NEVER Add `skip` To Tests 🚨" section above. Tests should FAIL if conditions aren't met. Only add `skip` if the user explicitly requests it. Skipping tests hides problems and reduces coverage.
4. **WARN if tests are being skipped** - If you see `# skip` in test output, this is a red flag. Skipped tests indicate missing prerequisites (like PostgreSQL not running) or test environment issues. Always investigate why tests are being skipped and warn the user.
5. **Never ignore result codes** - Use `run` and check `$status` instead of `|| true`
6. **Tests auto-run prerequisites** - You can run any test individually
7. **BATS output handling** - Use `>&3` for debug output, not `>&2`
8. **PostgreSQL requirement** - Some tests require PostgreSQL to be running (use `skip_if_no_postgres` helper to skip gracefully). Tests assume the user has configured PostgreSQL environment variables (PGHOST, PGPORT, PGUSER, PGDATABASE, etc.) so that a plain `psql` command works. This keeps the test framework simple - we don't try to manage PostgreSQL connection parameters.
9. **Git dirty detection** - `make test` runs test-recursion first if repo is dirty
10. **Foundation rebuild** - The Makefile **always** regenerates foundation automatically (via `clean-envs`). Individual tests also auto-rebuild foundation via `ensure_foundation()` if needed.
11. **Avoid unnecessary `make` calls** - Constantly re-running `make` targets is expensive. Tests should reuse output from previous tests when possible. Only run `make` when you need to generate or rebuild something.
12. **Never remove or modify files generated by `make`** - If a test is broken because a file needs to be rebuilt, that means **the Makefile is broken** (missing dependencies). Fix the Makefile, don't work around it by deleting files. The Makefile should have proper dependencies so `make` automatically rebuilds when source files change.
13. **Debug Makefile dependencies with `make print-VARIABLE`** - The Makefile includes a `print-%` rule that lets you inspect variable values. Use `make print-VARIABLE_NAME` to verify dependencies are set correctly. For example, `make print-PGXNTOOL_CONTROL_FILES` will show which control files are in the dependency list.

## Quick Reference

```bash
# ✅ Full suite
make test

# ✅ Specific test (auto-rebuilds if needed)
test/bats/bin/bats tests/04-pgtle.bats
test/bats/bin/bats tests/test-pgtle-install.bats

# ✅ With debug
DEBUG=5 test/bats/bin/bats tests/04-pgtle.bats
DEBUG=5 test/bats/bin/bats tests/test-pgtle-install.bats

# ✅ Test infrastructure
make test-recursion

# ✅ Rebuild foundation manually (rarely needed - tests auto-rebuild)
make foundation

# ❌ NEVER DO THESE IN NORMAL OPERATION:
# 🚨 Clean environments - ONLY for debugging cleanup failures themselves
# 🚨 MUST document what cleanup failure you're debugging if you use these
# make clean-envs
# make clean
# rm -rf .envs

# ❌ ESPECIALLY NEVER DO THIS:
# make clean && make test  # Wastes time, tests auto-rebuild anyway!
```

## How pgxntool Gets Into Test Environment

1. **Foundation setup** (`foundation.bats`):
   - Clones template repository
   - If pgxntool repo is clean: Uses `git subtree add` to add pgxntool
   - If pgxntool repo is dirty: Uses `rsync` to copy uncommitted changes
   - This creates `.envs/foundation/repo/` with pgxntool embedded

2. **Other tests**:
   - Sequential tests: Copy foundation repo to `.envs/sequential/repo/`
   - Independent tests: Use `ensure_foundation()` to copy foundation repo to their environment
   - Tests automatically check if foundation exists and is current before using it

3. **After pgxntool changes**:
   - Foundation must be rebuilt to pick up changes
   - **Using `make test`**: Foundation is **always** regenerated automatically (Makefile runs `clean-envs` first)
   - **Running individual tests**: Tests automatically rebuild foundation via `ensure_foundation()` if needed - no manual `make foundation` required

## Test System Philosophy

The test system is designed to:
- **Be self-healing**: Tests detect pollution and rebuild automatically
- **Support individual execution**: Any test can be run alone and will set up prerequisites
- **Be fast**: Sequential tests share state to avoid redundant work
- **Be isolated**: Independent tests get fresh environments
- **Be maintainable**: Semantic assertions instead of string comparisons
- **Be debuggable**: Comprehensive debug output via DEBUG variable

### Self-Healing Test Architecture

**CRITICAL PRINCIPLE**: Tests should always be written to automatically detect if they need to rebuild their test environment. Manual cleanup should NEVER be necessary.

**How this works**:
- Tests check for required prerequisites and state markers
- If prerequisites are missing or incomplete, tests automatically rebuild
- Pollution detection automatically triggers environment rebuild
- Tests can be run individually without any manual setup

**What this means for test writers**:
- Tests should check for required state before assuming it exists
- Use `ensure_foundation()` or `setup_sequential_test()` which handle prerequisites
- Never assume a clean environment - always check and rebuild if needed
- Tests should work whether run individually or as part of a suite

**What this means for test runners**:
- You should NEVER need to run `make clean` before running tests
- Tests will automatically detect stale environments and rebuild
- You can run any test individually without manual setup
- The only time you might need `make clean` is if you want to force a complete rebuild for debugging

**Exception**: When pgxntool code changes, foundation must be rebuilt because the test environment contains a copy of pgxntool. The Makefile **always** handles this automatically via `make clean-envs` (which removes all environments, forcing fresh rebuilds). Individual tests also auto-rebuild foundation via `ensure_foundation()` if needed. The `make foundation` command is rarely needed - only for explicit control or debugging.
