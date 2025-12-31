#!/usr/bin/env bats

# Meta-test: Validate test structure
#
# This test validates that all sequential tests follow the required structure:
# - Sequential tests (01-*.bats, 02-*.bats, etc.) must call mark_test_start()
# - Sequential tests must call mark_test_complete()
# - Standalone tests must NOT use state markers
# - Sequential tests must be numbered consecutively

load ../lib/helpers

setup_file() {
  debug 1 ">>> ENTER setup_file: 00-validate-tests (PID=$$)"
  # This is the first sequential test (00), but it doesn't use the test environment
  #
  # IMPORTANT: This test doesn't actually use the test environment (TEST_REPO, etc.)
  # since it only validates test file structure by reading .bats files from disk.
  # However, it MUST still follow sequential test rules (setup_sequential_test,
  # mark_test_complete) because its filename matches the [0-9][0-9]-*.bats pattern.
  # If it didn't follow these rules, it would break pollution detection and test ordering.
  #
  # Test 01-meta is the first sequential test to actually use the test environment.
  # See comments in 01-meta.bats for how it copies foundation to the sequential environment.
  setup_sequential_test "00-validate-tests"
  debug 1 "<<< EXIT setup_file: 00-validate-tests (PID=$$)"
}

setup() {
  load_test_env "sequential"
}

teardown_file() {
  debug 1 ">>> ENTER teardown_file: 00-validate-tests (PID=$$)"
  # Validate PID file assumptions before marking complete
  #
  # This validates our critical assumption that setup_file() and teardown_file()
  # run in the same parent process. Our PID-based safety mechanism (which prevents
  # destroying test environments while tests are running) depends on this being true.
  #
  # See test/README.pids.md for detailed explanation of BATS process model.

  local test_name="00-validate-tests"
  local state_dir="$TEST_DIR/.bats-state"
  local lockdir="$state_dir/.lock-$test_name"
  local pid_file="$lockdir/pid"

  # Check lock directory exists
  if [ ! -d "$lockdir" ]; then
    echo "FAIL: Lock directory $lockdir does not exist" >&2
    echo "This indicates create_pid_file() was not called or didn't create the lock" >&2
    return 1
  fi

  # Check PID file exists
  if [ ! -f "$pid_file" ]; then
    echo "FAIL: PID file $pid_file does not exist" >&2
    echo "This indicates create_pid_file() didn't write the PID file" >&2
    return 1
  fi

  # Read PID from file
  local recorded_pid=$(cat "$pid_file")

  # Check PID matches current process
  if [ "$recorded_pid" != "$$" ]; then
    echo "FAIL: PID mismatch!" >&2
    echo "  Recorded PID (from create_pid_file in setup_file): $recorded_pid" >&2
    echo "  Current PID (in teardown_file): $$" >&2
    echo "This indicates setup_file() and teardown_file() are NOT running in the same process" >&2
    echo "Our PID safety mechanism relies on this assumption being correct" >&2
    echo "See test/README.pids.md for details" >&2
    return 1
  fi

  # Validation passed, safe to mark complete
  mark_test_complete "$test_name"
  debug 1 "<<< EXIT teardown_file: 00-validate-tests (PID=$$)"
}

@test "all sequential tests call mark_test_start()" {
  cd "$BATS_TEST_DIRNAME"

  for test_file in [0-9][0-9]-*.bats; do
    [ -f "$test_file" ] || continue

    # Skip this validation test itself
    [ "$test_file" = "00-validate-tests.bats" ] && continue

    # Check if mark_test_start is called (either directly or via setup_sequential_test)
    # setup_sequential_test() calls mark_test_start internally
    if ! grep -q "setup_sequential_test\|mark_test_start" "$test_file"; then
      echo "FAIL: Foundation test $test_file missing mark_test_start() or setup_sequential_test() call" >&2
      return 1
    fi
  done
}

@test "all sequential tests call mark_test_complete()" {
  cd "$BATS_TEST_DIRNAME"

  for test_file in [0-9][0-9]-*.bats; do
    [ -f "$test_file" ] || continue

    # Skip this validation test itself
    [ "$test_file" = "00-validate-tests.bats" ] && continue

    if ! grep -q "mark_test_complete" "$test_file"; then
      echo "FAIL: Foundation test $test_file missing mark_test_complete() call" >&2
      return 1
    fi

    # Check that it's called in teardown_file
    if ! awk '/^teardown_file\(\)/,/^}/ {if (/mark_test_complete/) found=1} END {exit !found}' "$test_file"; then
      echo "FAIL: Foundation test $test_file doesn't call mark_test_complete() in teardown_file()" >&2
      return 1
    fi
  done
}

@test "standalone tests don't use state markers" {
  cd "$BATS_TEST_DIRNAME"

  for test_file in *.bats; do
    [ -f "$test_file" ] || continue

    # Skip sequential tests (start with 2 digits)
    [[ "$test_file" =~ ^[0-9][0-9]- ]] && continue

    # Skip this validation test itself
    [ "$test_file" = "00-validate-tests.bats" ] && continue

    # Skip foundation test (special case - base for all tests, uses state markers)
    [ "$test_file" = "foundation.bats" ] && continue

    if grep -q "mark_test_start\|mark_test_complete" "$test_file"; then
      echo "FAIL: Non-sequential test $test_file incorrectly uses state markers (should use setup_nonsequential_test instead)" >&2
      return 1
    fi
  done
}

@test "sequential tests are numbered sequentially" {
  cd "$BATS_TEST_DIRNAME"

  local expected=0
  for test_file in [0-9][0-9]-*.bats; do
    [ -f "$test_file" ] || continue

    # Extract number from filename
    local num=$(echo "$test_file" | sed 's/^\([0-9][0-9]\)-.*/\1/' | sed 's/^0*//')
    [ -z "$num" ] && num=0

    if [ "$num" -ne "$expected" ]; then
      echo "FAIL: Foundation tests not sequential: expected $expected, found $num in $test_file" >&2
      return 1
    fi

    expected=$((expected + 1))
  done
}

@test "all sequential tests use setup_sequential_test()" {
  cd "$BATS_TEST_DIRNAME"

  for test_file in [0-9][0-9]-*.bats; do
    [ -f "$test_file" ] || continue

    # Skip this validation test itself
    [ "$test_file" = "00-validate-tests.bats" ] && continue

    if ! grep -q "setup_sequential_test" "$test_file"; then
      echo "FAIL: Foundation test $test_file doesn't call setup_sequential_test()" >&2
      return 1
    fi
  done
}

@test "all standalone tests use setup_nonsequential_test() or ensure_foundation()" {
  cd "$BATS_TEST_DIRNAME"

  for test_file in test-*.bats; do
    [ -f "$test_file" ] || continue

    # Check for either setup_nonsequential_test() or ensure_foundation()
    # ensure_foundation() is the newer, simpler pattern for tests that only need foundation
    if ! grep -q "setup_nonsequential_test\|ensure_foundation" "$test_file"; then
      echo "FAIL: Non-sequential test $test_file doesn't call setup_nonsequential_test() or ensure_foundation()" >&2
      return 1
    fi
  done
}

@test "PID safety documentation exists" {
  cd "$BATS_TEST_DIRNAME/.."

  # Verify README.pids.md exists and contains key information
  if [ ! -f "README.pids.md" ]; then
    echo "FAIL: test/README.pids.md is missing" >&2
    echo "This file documents our PID safety mechanism and BATS process model" >&2
    return 1
  fi

  # Check it contains key sections
  if ! grep -q "BATS Process Architecture" "README.pids.md"; then
    echo "FAIL: README.pids.md missing BATS Process Architecture section" >&2
    return 1
  fi

  if ! grep -qi "parent process" "README.pids.md"; then
    echo "FAIL: README.pids.md doesn't document parent process behavior" >&2
    return 1
  fi

  if ! grep -q "setup_file\|teardown_file" "README.pids.md"; then
    echo "FAIL: README.pids.md doesn't mention setup_file/teardown_file" >&2
    return 1
  fi
}

# vi: expandtab sw=2 ts=2
