# BATS Test System Architecture

This directory contains the BATS (Bash Automated Testing System) test suite for validating pgxntool functionality.

## Overview

The BATS test system uses **semantic assertions** instead of string-based output comparison. This makes tests more maintainable and easier to understand.

## Two Types of Tests

### Sequential Tests (Foundation Chain)

**Naming pattern**: `[0-9][0-9]-*.bats` (e.g., `01-clone.bats`, `02-setup.bats`)

**Characteristics**:
- Run in numerical order (00, 01, 02, ...)
- Share a single test environment (`test/.envs/sequential/`)
- Build state incrementally (each test depends on previous)
- Use state markers to track execution
- Detect environment pollution

**Purpose**: Test the core pgxntool workflow that users follow:
1. Clone extension repo
2. Run setup.sh
3. Generate META.json
4. Create distribution
5. Final validation

**Example**: `02-setup.bats` expects that `01-clone.bats` has already created TEST_REPO with pgxntool embedded.

### Independent Tests (Feature Tests)

**Naming pattern**: `test-*.bats` (e.g., `test-doc.bats`, `test-make-results.bats`)

**Characteristics**:
- Run in isolation with fresh environments
- Each test gets its own environment (`test/.envs/doc/`, `test/.envs/results/`)
- Can run in parallel (no shared state)
- Rebuild prerequisites from scratch each time
- No pollution detection needed

**Purpose**: Test specific features that can be validated independently:
- Documentation generation
- `make results` behavior
- Error handling
- Edge cases

**Example**: `test-doc.bats` creates a fresh environment, runs the clone→setup→meta chain, then tests documentation generation.

## State Management

### State Markers

Sequential tests use marker files and lock directories in `test/.envs/<env>/.bats-state/`:

1. **`.start-<test-name>`** - Test has started
2. **`.complete-<test-name>`** - Test has completed successfully
3. **`.lock-<test-name>/`** - Lock directory containing `pid` file (prevents concurrent execution)

**Example state after running 01-03**:
```
.envs/sequential/.bats-state/
├── .start-01-clone
├── .complete-01-clone
├── .start-02-setup
├── .complete-02-setup
├── .start-03-meta
└── .complete-03-meta
```

**Note**: Lock directories (`.lock-*`) only exist while a test is running and are automatically cleaned up when the test completes.

### Pollution Detection

**Why it matters**: If test 03 fails and you re-run tests 01-02, you don't want to accidentally use state from the failed test 03 run.

**How it works**:
1. When a sequential test starts, it checks for pollution
2. Pollution is detected if:
   - Any test started but didn't complete (incomplete state)
   - Any "later" sequential test has run (out-of-order execution)
3. If pollution detected:
   - Environment is cleaned and recreated
   - All prerequisite tests are re-run
   - Fresh state is built

**Example pollution scenarios**:

**Scenario 1: Incomplete test**
```bash
# First run: 03-meta crashes mid-execution
.bats-state/:
  .start-03-meta   # exists
  .complete-03-meta  # missing

# Next run: Starting 02-setup detects incomplete 03-meta
# Result: Environment cleaned, prerequisites rebuilt
```

**Scenario 2: Out-of-order execution**
```bash
# First run: Complete test suite (01-05)
# Second run: Run only tests 01-03
# Test 01 finds .start-04-dist exists (runs after 03)
# Result: Environment cleaned to ensure clean state
```

### Process Safety (PID Files)

**Purpose**: Prevent destroying test environments while tests are running.

**How it works**:
1. Test starts → writes PID to `.pid-<test-name>`
2. Test completes → removes `.pid-<test-name>`
3. Before cleaning environment → check all PID files
4. If process still running → refuse to clean
5. If PID stale (process dead) → safe to clean

**Example**:
```bash
# Terminal 1: Running 02-setup (PID 12345)
.bats-state/.pid-02-setup contains "12345"

# Terminal 2: Try to clean environment
clean_env "sequential"
# → Checks kill -0 12345
# → Still running, refuses to clean
# → Error: "Cannot clean sequential - test 02-setup is still running"
```

## Helper Functions

### Test Setup Functions

#### `setup_sequential_test "test-name" ["prereq1" "prereq2" ...]`

Sets up a sequential sequential test.

**What it does**:
1. Loads the `sequential` environment (auto-creates if needed)
2. Checks for environment pollution
3. If polluted: cleans environment and rebuilds prerequisites
4. Ensures all prerequisite tests have completed
5. Marks this test as started

**Usage**:
```bash
setup_file() {
  setup_sequential_test "02-setup" "01-clone"
}
```

#### `setup_independent_test "test-name" "env-name" ["prereq1" "prereq2" ...]`

Sets up an independent feature test.

**What it does**:
1. Creates fresh isolated environment
2. Runs prerequisite chain from scratch
3. Exports environment variables

**Usage**:
```bash
setup_file() {
  setup_independent_test "test-doc" "doc" "01-clone" "02-setup" "03-meta"
}
```

### Environment Functions

#### `load_test_env "env-name"`

Loads or creates a test environment.

**What it does**:
1. If environment doesn't exist → creates it
2. Sources `.env` file (sets TEST_DIR, TEST_REPO, etc.)
3. Sources `lib.sh` (utilities)
4. Exports variables for use in tests

#### `clean_env "env-name"`

Safely removes a test environment.

**What it does**:
1. Checks all PID files for running processes
2. If any test still running → refuses to clean
3. If all PIDs stale → removes environment directory

#### `create_env "env-name"`

Creates a new test environment.

**What it does**:
1. Calls `clean_env` to safely remove existing environment
2. Creates directory structure: `test/.envs/<env-name>/.bats-state/`
3. Writes `.env` file with TEST_DIR, TEST_REPO, etc.

### State Marker Functions

#### `mark_test_start "test-name"`

Marks test as started (called automatically by `setup_sequential_test`).

**What it does**:
1. Creates `.start-<test-name>` marker
2. Creates `.pid-<test-name>` with current PID

#### `mark_test_complete "test-name"`

Marks test as completed (call in `teardown_file()`).

**What it does**:
1. Creates `.complete-<test-name>` marker
2. Removes `.pid-<test-name>` file

#### `detect_dirty_state "test-name"`

Checks if environment has been polluted.

**Returns**:
- 0 if clean
- 1 if polluted

### Assertion Helpers

#### Basic File/Directory Checks
- `assert_file_exists <path>`
- `assert_file_not_exists <path>`
- `assert_dir_exists <path>`
- `assert_dir_not_exists <path>`

#### Git State Checks
- `assert_git_clean [repo]` - Repo has no uncommitted changes
- `assert_git_dirty [repo]` - Repo has uncommitted changes

#### String Checks
- `assert_contains <haystack> <needle>`
- `assert_not_contains <haystack> <needle>`

#### Semantic Validators (preferred)
- `assert_valid_meta_json [file]` - Validates JSON structure and required fields
- `assert_valid_distribution <zipfile>` - Validates distribution structure
- `assert_json_field <file> <field> <expected>` - Validates specific JSON value

## Writing a New Test

### Sequential Test

```bash
#!/usr/bin/env bats

load helpers

setup_file() {
  # List prerequisites (tests that must run first)
  setup_sequential_test "03-new-test" "01-clone" "02-setup"
}

setup() {
  load_test_env "sequential"
}

teardown_file() {
  # ALWAYS mark complete, even if tests fail
  mark_test_complete "03-new-test"
}

@test "description of what you're testing" {
  # Use semantic assertions, not string comparisons
  assert_file_exists "$TEST_REPO/somefile"

  # Check behavior, not output format
  run make some-target
  [ "$status" -eq 0 ]

  # Use helpers for complex validations
  assert_valid_meta_json "$TEST_REPO/META.json"
}
```

### Independent Test

```bash
#!/usr/bin/env bats

load helpers

setup_file() {
  # Create fresh environment, run prerequisite chain
  setup_independent_test "test-feature" "feature" "01-clone" "02-setup"
}

setup() {
  load_test_env "feature"
}

# No teardown_file needed (no state markers for independent tests)

@test "test your feature" {
  # Test runs in complete isolation
  assert_file_exists "$TEST_REPO/feature-file"
}
```

## Running Tests

### Run All Tests (Sequential Order)
```bash
cd /path/to/pgxntool-test
test/bats/bin/bats tests/00-validate-tests.bats
test/bats/bin/bats tests/01-clone.bats
test/bats/bin/bats tests/02-setup.bats
test/bats/bin/bats tests/03-meta.bats
test/bats/bin/bats tests/04-dist.bats
```

### Run Single Test
```bash
# Automatically runs prerequisites if needed
test/bats/bin/bats tests/03-meta.bats
```

### Run with Debug Output
```bash
DEBUG=1 test/bats/bin/bats tests/02-setup.bats  # Basic debug
DEBUG=5 test/bats/bin/bats tests/02-setup.bats  # Verbose debug
```

### Clean Environments
```bash
rm -rf .envs/  # Remove all test environments
```

## Test Development Tips

### 1. Start with the Test Name

Choose a number that reflects execution order:
- `00-validate-tests.bats` - Meta-test (validates test structure)
- `01-clone.bats` - First real test (creates repo)
- `02-setup.bats` - Depends on clone
- `03-meta.bats` - Depends on setup
- etc.

### 2. List Prerequisites Explicitly

Even if you only depend on the previous test, list it explicitly:
```bash
setup_sequential_test "03-meta" "02-setup"  # Not just implicit dependency
```

### 3. Always Mark Complete

Even if tests fail, `teardown_file()` should mark completion:
```bash
teardown_file() {
  mark_test_complete "02-setup"  # Always runs, even on failure
}
```

### 4. Use Semantic Assertions

**Bad** (fragile string comparison):
```bash
@test "setup creates makefile" {
  output=$(cat Makefile)
  [ "$output" = "include pgxntool/base.mk" ]  # Breaks if whitespace changes
}
```

**Good** (semantic check):
```bash
@test "setup creates makefile" {
  assert_file_exists "$TEST_REPO/Makefile"
  grep -q "include pgxntool/base.mk" "$TEST_REPO/Makefile"
}
```

### 5. Test Behavior, Not Output Format

**Bad**:
```bash
@test "make dist produces output" {
  run make dist
  [ "${lines[0]}" = "Creating distribution..." ]  # Fragile
}
```

**Good**:
```bash
@test "make dist creates zip file" {
  cd "$TEST_REPO"
  run make dist
  [ "$status" -eq 0 ]
  assert_valid_distribution "../pgxntool-test-*.zip"
}
```

## Debugging Test Failures

### Check State Markers
```bash
ls -la .envs/sequential/.bats-state/
# Shows which tests started/completed and any PID files
```

### Inspect Test Environment
```bash
# After test failure, inspect the environment
cd .envs/sequential/repo
git status
ls -la
cat META.json
```

### Run with Verbose Debug
```bash
DEBUG=5 test/bats/bin/bats tests/02-setup.bats
```

### Check for Pollution
```bash
# Look for incomplete tests
cd .envs/sequential/.bats-state
for start in .start-*; do
  test=$(echo $start | sed 's/^.start-//')
  if [ ! -f ".complete-$test" ]; then
    echo "Incomplete: $test"
  fi
done
```

### Check for Running Tests
```bash
# Look for active PID files
cd .envs/sequential/.bats-state
for pidfile in .pid-*; do
  [ -f "$pidfile" ] || continue
  pid=$(cat "$pidfile")
  test=$(echo $pidfile | sed 's/^.pid-//')
  if kill -0 "$pid" 2>/dev/null; then
    echo "Running: $test (PID $pid)"
  else
    echo "Stale: $test (PID $pid - process dead)"
  fi
done
```

## Special Case: 00-validate-tests.bats

This test is a meta-test that validates all other tests follow required structure. It's numbered `00-` so it runs first.

**Important**: Even though it doesn't use the test environment (TEST_REPO, etc.), it **must** still follow sequential test rules because its filename matches the `[0-9][0-9]-*.bats` pattern. If it didn't follow these rules, it would break pollution detection and test ordering.

The test includes a comment explaining this:
```bash
# IMPORTANT: This test doesn't actually use the test environment (TEST_REPO, etc.)
# since it only validates test file structure by reading .bats files from disk.
# However, it MUST still follow sequential test rules (setup_sequential_test,
# mark_test_complete) because its filename matches the [0-9][0-9]-*.bats pattern.
# If it didn't follow these rules, it would break pollution detection and test ordering.
```

## Common Issues

### Issue: "Environment polluted"

**Cause**: A previous test run left incomplete state markers.

**Fix**: Clean environments and re-run:
```bash
rm -rf .envs/
test/bats/bin/bats tests/01-clone.bats
```

### Issue: "Cannot clean sequential - test X is still running"

**Cause**: A test is actually running in another terminal.

**Fix**: Wait for test to complete, or kill the process if it's stuck.

### Issue: Test passes individually but fails in suite

**Cause**: Test doesn't properly declare prerequisites.

**Fix**: Add prerequisites to `setup_sequential_test()` or `setup_independent_test()`.

### Issue: Test fails with "TEST_REPO not found"

**Cause**: Prerequisite tests didn't run or failed.

**Fix**: Check that prerequisites are declared and passing:
```bash
# Run prerequisites manually
test/bats/bin/bats tests/01-clone.bats
test/bats/bin/bats tests/02-setup.bats
```

## Architecture Decisions

### Why Sequential + Independent?

- **Sequential tests** = fast when running full suite (no duplicate work)
- **Independent tests** = safe when running individually (no hidden dependencies)
- Best of both worlds

### Why Pollution Detection?

Without it, you'd get false positives/negatives when:
- Running partial test suite after failed run
- Running tests out of order during development
- Recovering from test crashes

### Why Per-Test PID Files?

- Handles individual test crashes gracefully
- Allows inspecting environment after test failure
- Prevents race conditions during cleanup
- Supports incremental testing (don't need full suite)

### Why Not Suite-Level PID?

BATS runs each .bats file in a separate process, so:
- Can't reliably track "suite PID" across files
- Per-test PIDs are more granular and robust
- Handles partial test runs better

## Future Improvements

1. **Suite completion marker** - Add `.suite-complete` to detect incomplete previous runs
2. **Automatic stale cleanup** - First test cleans stale environments automatically
3. **Parallel independent tests** - Run `test-*.bats` concurrently for speed
4. **Test timing** - Track and report slow tests
5. **Better error messages** - Show which prerequisite failed and why
