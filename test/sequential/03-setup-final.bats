#!/usr/bin/env bats

# Test: setup.sh idempotence and final setup
#
# Tests that setup.sh can be run multiple times safely and that
# template files can be copied to their final locations

load ../lib/helpers

setup_file() {
  debug 1 ">>> ENTER setup_file: 03-setup-final (PID=$$)"
  setup_sequential_test "03-setup-final" "02-dist"

  export EXTENSION_NAME="pgxntool-test"
  debug 1 "<<< EXIT setup_file: 03-setup-final (PID=$$)"
}

setup() {
  load_test_env "sequential"
  cd "$TEST_REPO"
}

teardown_file() {
  debug 1 ">>> ENTER teardown_file: 03-setup-final (PID=$$)"
  mark_test_complete "03-setup-final"
  debug 1 "<<< EXIT teardown_file: 03-setup-final (PID=$$)"
}

@test "setup.sh can be run again" {
  # This should not error
  run pgxntool/setup.sh
  assert_success
}

@test "setup.sh doesn't overwrite Makefile" {
  # Check output for "already exists" message
  run pgxntool/setup.sh
  echo "$output" | grep -q "Makefile already exists"
}

@test "setup.sh doesn't overwrite deps.sql" {
  run pgxntool/setup.sh
  echo "$output" | grep -q "deps.sql already exists"
}

@test "no git changes after re-running setup.sh" {
  # Skip if there are already uncommitted changes (from tests 5/6 in previous run)
  if ! git diff --exit-code >/dev/null 2>&1; then
    skip "Repository has uncommitted changes from previous test run"
  fi

  # Run setup.sh again
  pgxntool/setup.sh >/dev/null 2>&1

  # Should be no changes
  run git diff --exit-code
  assert_success
}

@test "deps.sql can be updated with extension name" {
  # Check if already updated
  if grep -q "CREATE EXTENSION \"$EXTENSION_NAME\"" test/deps.sql; then
    skip "deps.sql already updated"
  fi

  # Update deps.sql
  local quote='"'
  sed -i '' -e "s/CREATE EXTENSION \.\.\..*/CREATE EXTENSION ${quote}$EXTENSION_NAME${quote};/" test/deps.sql

  # Verify change
  grep -q "CREATE EXTENSION \"$EXTENSION_NAME\"" test/deps.sql
}

@test "repository is still in valid state" {
  # Final validation
  assert_file_exists "Makefile"
  assert_file_exists "META.json"
  assert_file_exists "test/deps.sql"

  # deps.sql should have correct extension name
  grep -q "$EXTENSION_NAME" test/deps.sql
}

# vi: expandtab sw=2 ts=2
