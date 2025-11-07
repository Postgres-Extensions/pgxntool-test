#!/usr/bin/env bats

# Test: make test framework
#
# Tests that the test framework works correctly:
# - Creates test/output directory when needed
# - Uses test/output for expected outputs
# - Doesn't recreate output when directories removed

load helpers

setup_file() {
  # Set TOPDIR
  cd "$BATS_TEST_DIRNAME/.."
  export TOPDIR=$(pwd)

  # Independent test - gets its own isolated environment with foundation TEST_REPO
  load_test_env "make-test"
  ensure_foundation "$TEST_DIR"
}

setup() {
  load_test_env "make-test"
  cd "$TEST_REPO"
}

@test "test/output directory does not exist initially" {
  # Skip if already exists from previous run
  if [ -d "test/output" ]; then
    skip "test/output already exists"
  fi

  assert_dir_not_exists "test/output"
}

@test "make test creates test/output directory" {
  # Skip if already exists
  if [ -d "test/output" ]; then
    skip "test/output already exists"
  fi

  # Run make test (will fail but that's expected for test setup)
  make test || true

  # Directory should now exist
  assert_dir_exists "test/output"
}

@test "test/output is a directory" {
  assert_dir_exists "test/output"
}

@test "can copy expected output file to test/output" {
  local source_file="$TOPDIR/pgxntool-test.source"

  # Skip if already copied
  if [ -f "test/output/pgxntool-test.out" ]; then
    skip "Output file already copied"
  fi

  # Skip if source doesn't exist
  if [ ! -f "$source_file" ]; then
    skip "Source file $source_file does not exist"
  fi

  # Copy and rename .source to .out
  cp "$source_file" test/output/pgxntool-test.out

  assert_file_exists "test/output/pgxntool-test.out"
}

@test "make test succeeds when output matches" {
  # This should now pass since we copied the expected output
  run make test
  [ "$status" -eq 0 ]
}

@test "expected output can be committed" {
  # Check if there are untracked files in test/expected/
  local untracked=$(git status --porcelain test/expected/ | grep '^??')

  if [ -z "$untracked" ]; then
    skip "No untracked files in test/expected/"
  fi

  # Add and commit
  git add test/expected/
  run git commit -m "Add test expected output"
  [ "$status" -eq 0 ]
}

@test "can remove test directories" {
  # Remove input and output
  rm -rf test/input test/output

  assert_dir_not_exists "test/output"
}

@test "make test doesn't recreate output when directories removed" {
  # After removing directories, output should not be recreated
  make test || true

  # test/output should NOT exist (correct behavior)
  assert_dir_not_exists "test/output"
}

@test "repository is still functional" {
  # Basic sanity check
  assert_file_exists "Makefile"

  run make --version
  [ "$status" -eq 0 ]
}

# vi: expandtab sw=2 ts=2
