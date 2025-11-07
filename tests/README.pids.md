# BATS Process Model and PID Safety

This document explains how BATS manages processes and why our PID-based safety mechanism works.

## BATS Process Architecture

BATS uses a parent-child process model when running tests:

```
.bats file execution
├─ Parent Process (PID X)
│  ├─ setup_file()
│  ├─ Spawn subprocess for test 1 (PID Y)
│  │  ├─ setup()
│  │  ├─ @test "test 1"
│  │  └─ teardown()
│  ├─ Spawn subprocess for test 2 (PID Z)
│  │  ├─ setup()
│  │  ├─ @test "test 2"
│  │  └─ teardown()
│  └─ teardown_file()
```

### Verified Behavior

We verified this with test code:

```bash
$ cat > /tmp/test-setup.bats << 'EOF'
#!/usr/bin/env bats

setup_file() {
  echo "setup_file - PID: $$"
}

setup() {
  echo "setup (before test $BATS_TEST_NUMBER) - PID: $$"
}

@test "test 1" {
  echo "test 1 - PID: $$"
}

@test "test 2" {
  echo "test 2 - PID: $$"
}

teardown() {
  echo "teardown (after test $BATS_TEST_NUMBER) - PID: $$"
}

teardown_file() {
  echo "teardown_file - PID: $$"
}
EOF

$ bats /tmp/test-setup.bats
setup_file - PID: 15917
setup (before test 1) - PID: 15923
test 1 - PID: 15923
teardown (after test 1) - PID: 15923
setup (before test 2) - PID: 15937
test 2 - PID: 15937
teardown (after test 2) - PID: 15937
teardown_file - PID: 15917
```

### Key Findings

1. **Each .bats file runs in a separate parent process**
   - `01-clone.bats` → one parent process
   - `02-setup.bats` → different parent process

2. **Within each .bats file:**
   - `setup_file()` runs in parent process
   - `teardown_file()` runs in same parent process
   - Each `@test` runs in its own subprocess
   - `setup()` and `teardown()` run in same subprocess as the test

3. **Parent process lifetime:**
   - Starts before `setup_file()`
   - Lives through all `@test` executions
   - Ends after `teardown_file()`

## How Our PID Safety Works

### Creating PID Files

In `mark_test_start()` (called from `setup_file()`):

```bash
mark_test_start() {
  local test_name=$1
  local state_dir="$TEST_DIR/.bats-state"

  # Capture parent process PID
  echo $$ > "$state_dir/.pid-$test_name"

  # Also create start marker
  touch "$state_dir/.start-$test_name"
}
```

**Why this works**: `$$` in `setup_file()` gives us the parent process PID, which lives for the entire test file execution.

### Removing PID Files

In `mark_test_complete()` (called from `teardown_file()`):

```bash
mark_test_complete() {
  local test_name=$1
  local state_dir="$TEST_DIR/.bats-state"

  # Create completion marker
  touch "$state_dir/.complete-$test_name"

  # Remove PID file (we're done)
  rm -f "$state_dir/.pid-$test_name"
}
```

**Why this works**: `teardown_file()` runs in the same parent process as `setup_file()`, so it has access to remove the PID file.

### Checking PID Files Before Cleanup

In `clean_env()`:

```bash
clean_env() {
  local env_name=$1
  local env_dir="$TOPDIR/.envs/$env_name"
  local state_dir="$env_dir/.bats-state"

  # Check for running tests
  if [ -d "$state_dir" ]; then
    for pid_file in "$state_dir"/.pid-*; do
      [ -f "$pid_file" ] || continue

      local pid=$(cat "$pid_file")
      local test_name=$(basename "$pid_file" | sed 's/^\.pid-//')

      # Check if process is still alive
      if kill -0 "$pid" 2>/dev/null; then
        echo "ERROR: Cannot clean $env_name - test $test_name is still running (PID $pid)" >&2
        return 1
      fi
    done
  fi

  # Safe to remove
  rm -rf "$env_dir"
}
```

**Why this works**:
- If the parent process is alive, `kill -0 $pid` succeeds
- If parent is alive, it means the test file is still running (could be in `setup_file`, any `@test`, or `teardown_file`)
- We refuse to clean the environment while any test is running

## Why This Design is Correct

### Per-Test PID Files (Current Design)

**Advantages:**
- ✅ Each .bats file tracked independently
- ✅ Can detect if specific test is running
- ✅ Handles partial test runs correctly
- ✅ Allows incremental testing (run one test at a time)
- ✅ Works correctly when BATS runs multiple .bats files sequentially

**Example scenario:**
```bash
# Terminal 1: Running one test
$ bats 02-setup.bats
# Creates .pid-02-setup with parent PID

# Terminal 2: Try to clean while test 1 is running
$ rm -rf .envs/sequential
# clean_env() checks .pid-02-setup, finds process alive, refuses

# Terminal 1: Test completes
# teardown_file() removes .pid-02-setup

# Terminal 2: Now safe to clean
$ rm -rf .envs/sequential
# clean_env() checks .pid-02-setup, finds it doesn't exist, proceeds
```

### Alternative: Suite-Level PID (Considered and Rejected)

**Problems with suite-level PID:**
- ❌ BATS runs each .bats file in separate process - no "suite process"
- ❌ Can't track individual test files
- ❌ Can't tell which specific test is running
- ❌ Doesn't work when running single test file
- ❌ Would need complex coordination between test files

**Example of failure:**
```bash
# If we tried to use suite-level PID:
$ bats 02-setup.bats    # What PID to write? There's no suite runner.
$ bats 03-meta.bats     # Different process, can't coordinate with 02
```

## Edge Cases and Safety

### Case 1: Test Crashes Mid-Execution

```bash
# Test 03 crashes during an @test block
.bats-state/:
  .start-03-meta      # exists (created in setup_file)
  .pid-03-meta        # exists (contains dead PID)
  .complete-03-meta   # missing (teardown_file never ran)

# Next run detects:
# 1. Pollution: .start-03-meta exists but no .complete-03-meta
# 2. PID check: kill -0 $pid fails (process dead)
# 3. Safe to clean and rebuild
```

### Case 2: Multiple Tests Running (Race Condition)

```bash
# Terminal 1: Running test 02
.bats-state/.pid-02-setup → 12345

# Terminal 2: Running test 03
.bats-state/.pid-03-meta → 12350

# Terminal 3: Try to clean
$ rm -rf .envs/sequential
# clean_env() checks ALL PID files:
#   - .pid-02-setup: PID 12345 alive → ERROR, refuse
#   - .pid-03-meta: PID 12350 alive → ERROR, refuse
```

### Case 3: Stale PID File (Process Died)

```bash
# System crash or kill -9 left stale PID file
.bats-state/.pid-02-setup → 99999

# Next run:
# kill -0 99999 → fails (process doesn't exist)
# clean_env() proceeds safely
```

### Case 4: PID Reuse (Theoretical)

**Concern**: What if a new process gets the same PID as an old test?

**Reality**: Not a problem because:
1. PID files are removed by `teardown_file()` when test completes normally
2. Stale PIDs (from crashes) are only checked with `kill -0`
3. If PID was reused by unrelated process, we'd detect it's alive and refuse to clean
4. This is conservative (safe) - worst case is refusing to clean when we could
5. User can manually clean if truly stale: `rm -rf .envs/`

## Implementation Notes

### Why Use `$$` Not `$BASHPID`?

- `$$` gives the top-level shell PID (parent process)
- `$BASHPID` gives the current subprocess PID
- We want parent PID because:
  - It lives for entire .bats file execution
  - It's consistent between `setup_file()` and `teardown_file()`
  - It represents the test file execution lifetime

### Why `kill -0` Not `ps` or `/proc`?

- `kill -0` is portable across Unix systems
- Doesn't actually send signal, just checks if process exists
- Returns 0 if process exists, non-zero if not
- Faster than parsing `ps` output
- More reliable than checking `/proc` (Linux-specific)

### Why Check All PID Files?

We iterate through all PID files, not just current test's:

```bash
for pid_file in "$state_dir"/.pid-*; do
  # Check each one
done
```

**Reason**: Environment is shared by all sequential tests. If ANY test is running in that environment, we must not clean it.

**Example:**
```bash
# User runs multiple tests in parallel (accidentally):
$ bats 02-setup.bats &    # Background
$ bats 03-meta.bats       # Foreground

# If 03 tries to clean environment:
# Must check BOTH .pid-02-setup and .pid-03-meta
# Both are using same environment!
```

## Debugging PID Issues

### Check Running Tests

```bash
cd .envs/sequential/.bats-state

for pid_file in .pid-*; do
  [ -f "$pid_file" ] || continue

  pid=$(cat "$pid_file")
  test=$(basename "$pid_file" | sed 's/^\.pid-//')

  if kill -0 "$pid" 2>/dev/null; then
    echo "Running: $test (PID $pid)"
  else
    echo "Stale: $test (PID $pid - process dead)"
  fi
done
```

### Check Process Details

```bash
# See what process is actually running
pid=$(cat .envs/sequential/.bats-state/.pid-02-setup)
ps -fp "$pid"

# See full process tree
pstree -p "$pid"
```

### Force Clean (Use with Caution)

```bash
# If you're SURE no tests are running but clean_env refuses:
rm -rf .envs/sequential
```

## Summary

The per-test PID file approach is the correct design because:

1. **Each .bats file runs in separate parent process** → need per-test tracking
2. **Parent PID lives for entire test execution** → captures full test lifetime
3. **`kill -0` reliably detects running processes** → safe cleanup checks
4. **Checking all PID files** → prevents destroying environment in use by any test
5. **Graceful handling of crashes** → stale PIDs detected and handled

The architecture is simple, robust, and handles all edge cases correctly.
