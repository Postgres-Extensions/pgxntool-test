#!/usr/bin/env bats

# Test: test-build feature
#
# The template includes a working test/build/ directory (build_check.sql with
# matching expected output). Tests validate the working state first, then
# modify for edge cases.

load ../lib/helpers

setup_file() {
  setup_topdir

  load_test_env "test-build"
  ensure_foundation "$TEST_DIR"
}

setup() {
  load_test_env "test-build"
  cd "$TEST_REPO"
}

@test "template includes test/build files" {
  assert_file_exists "test/build/build_check.sql"
  assert_file_exists "test/build/expected/build_check.out"
}

@test "test-build is auto-detected as enabled" {
  run make -n test 2>&1
  assert_success
  echo "$output" | grep -q "test-build"
}

@test "test-build runs successfully with template files" {
  skip_if_no_postgres

  run make test-build
  assert_success

  assert_repo_clean "after make test-build"
}

@test "test-build fails with invalid SQL" {
  skip_if_no_postgres

  # Add an invalid SQL file alongside the valid template one
  cat > test/build/invalid_test.sql <<'EOF'
SELECT FROM nonexistent_table WHERE;
EOF
  mkdir -p test/build/expected
  # Create expected output that would match if there were no error
  echo > test/build/expected/invalid_test.out

  # Clean generated sql/ so updated files get copied
  rm -rf test/build/sql

  run make test-build
  [ "$status" -ne 0 ]

  # Clean up
  rm -f test/build/invalid_test.sql test/build/expected/invalid_test.out
  rm -rf test/build/sql
}

@test "test-build can be disabled via PGXNTOOL_ENABLE_TEST_BUILD=no" {
  run make -n test PGXNTOOL_ENABLE_TEST_BUILD=no 2>&1
  assert_success
  # Check that run-test-build.sh recipe commands are not in the dry-run output.
  # Note: we cannot check for the string "test-build" directly because the
  # test environment directory path contains "test-build" and appears in
  # make's "Entering directory" messages.
  ! echo "$output" | grep -q "run-test-build.sh"
}

# Tests below here remove test/build/; keep them last
@test "PGXNTOOL_ENABLE_TEST_BUILD=yes errors when test/build/ is missing" {
  rm -rf test/build

  # Explicitly enabling should error when directory has no files
  run make test-build PGXNTOOL_ENABLE_TEST_BUILD=yes 2>&1
  [ "$status" -ne 0 ]
}

@test "run-test-build.sh errors when no .sql files exist" {
  # test/build/ still removed from previous test
  run pgxntool/run-test-build.sh test
  assert_failure
  echo "$output" | grep -q "no .sql files found"
}

@test "test-build target absent when test/build/ is removed" {
  # test/build/ still removed
  run make -n test 2>&1
  assert_success
  # Check that run-test-build.sh recipe commands are not in the dry-run output.
  # Note: we cannot check for the string "test-build" directly because the
  # test environment directory path contains "test-build" and appears in
  # make's "Entering directory" messages.
  ! echo "$output" | grep -q "run-test-build.sh"
}

# vi: expandtab sw=2 ts=2
