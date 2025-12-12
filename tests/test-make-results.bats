#!/usr/bin/env bats

# Test: make results functionality
#
# Tests that make results correctly updates expected output files:
# - Modifies expected output to create a mismatch
# - Verifies make test fails with the mismatch
# - Runs make results to update expected output
# - Verifies make test now passes

load helpers

setup_file() {
  # Set TOPDIR
  cd "$BATS_TEST_DIRNAME/.."
  export TOPDIR=$(pwd)

  # Independent test - gets its own isolated environment with foundation TEST_REPO
  load_test_env "make-results"
  ensure_foundation "$TEST_DIR"
}

setup() {
  load_test_env "make-results"
  cd "$TEST_REPO"
}

@test "make results establishes baseline expected output" {
  # Clean up any leftover files in test/output/ from previous test runs
  # (pg_regress uses test/output/ for diffs, but empty .source files might be left behind)
  # These can interfere with make_results.sh which checks for output/*.source files
  rm -f test/output/*.source

  # Skip if expected output already exists and has content
  if [ -f "test/expected/pgxntool-test.out" ] && [ -s "test/expected/pgxntool-test.out" ]; then
    skip "Expected output already established"
  fi

  # Run make results (which depends on make test, so both will run)
  # This establishes the baseline expected output
  run make results
  assert_success

  # Verify expected output now exists with content
  assert_file_exists "test/expected/pgxntool-test.out"
  [ -s "test/expected/pgxntool-test.out" ]
}

@test "expected output file exists with content" {
  assert_file_exists "test/expected/pgxntool-test.out"
  [ -s "test/expected/pgxntool-test.out" ]
}

@test "expected output can be committed to git" {
  # Check if file is already tracked and clean
  local status_output=$(git status --porcelain test/expected/pgxntool-test.out)

  if [ -z "$status_output" ]; then
    skip "Expected output already committed"
  fi

  # Add and commit the expected output
  git add test/expected/pgxntool-test.out
  run git commit -m "Add baseline expected output"
  assert_success
}

@test "can modify expected output to create mismatch" {
  # Add a blank line to create a difference
  echo >> test/expected/pgxntool-test.out

  # Verify file was modified (now it should show as modified since it's committed)
  run git status --porcelain test/expected/pgxntool-test.out
  [ -n "$output" ]
  echo "$output" | grep -qE "^.M"
}

@test "make test shows diff with modified expected output" {
  # Run make test (should show diffs due to mismatch)
  # Note: make test doesn't exit non-zero due to .IGNORE: installcheck
  run make test

  # Check that diff output was produced (either in output or test/output directory exists)
  # test/output is created when tests fail
  [ -d "test/output" ] || echo "$output" | grep -q "diff"
}

@test "make results updates expected output" {
  # Run make results to fix the expected output
  run make results
  assert_success
}

@test "make test succeeds after make results" {
  # Now make test should pass
  run make test
  assert_success
}

@test "repository is still functional after make results" {
  # Final validation
  assert_file_exists "test/expected/pgxntool-test.out"
  assert_file_exists "Makefile"
}

# vi: expandtab sw=2 ts=2
