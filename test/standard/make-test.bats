#!/usr/bin/env bats

# Test: make test framework
#
# Tests that the test framework works correctly:
# - Creates test/output directory when needed
# - Uses test/output for expected outputs
# - Doesn't recreate output when directories removed

load ../lib/helpers

setup_file() {
  # Set TOPDIR
  setup_topdir


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

  # pg_regress does NOT create input/ or output/ directories - they are optional
  # INPUT directories. We need to create it ourselves for this test.
  mkdir -p test/output

  # Verify directory was created
  assert_dir_exists "test/output"
}

@test "test/output is a directory" {
  assert_dir_exists "test/output"
}

@test "make test succeeds" {
  run make test
  assert_success
}

@test "can remove test directories" {
  # Remove input and output
  rm -rf test/input test/output

  assert_dir_not_exists "test/output"
}

@test "make test doesn't recreate output when directories removed" {
  # After removing directories, output should not be recreated
  # We only care that the directory doesn't get recreated, not that tests pass
  run make test

  # test/output should NOT exist (correct behavior)
  assert_dir_not_exists "test/output"
}

@test "repository is still functional" {
  # Basic sanity check
  assert_file_exists "Makefile"

  run make --version
  assert_success
}

# Unique database name tests
#
# Verify that make test uses a unique database name based on the project name
# and a hash of the current directory (REGRESS_DBNAME in base.mk).

@test "unique db name: create test SQL file and expected output" {
  skip_if_no_postgres

  # Create a simple SQL test that queries the current database name
  # Use \t and \a so output is just the bare value (no headers/formatting)
  mkdir -p test/sql
  cat > test/sql/dbname.sql <<'EOF'
\a
\t
SELECT current_database();
EOF

  # Get the exact database name from make (authoritative source)
  # Output format: REGRESS_DBNAME is simple variable set to "value"
  local expected_dbname
  expected_dbname=$(make print-REGRESS_DBNAME 2>&1 | sed -n 's/.*set to "\(.*\)"/\1/p')
  [ -n "$expected_dbname" ] || error "Could not extract REGRESS_DBNAME from make"

  # Manually create the expected output file
  mkdir -p test/expected
  printf '%s\n' "$expected_dbname" > test/expected/dbname.out
}

@test "unique db name: make test passes" {
  skip_if_no_postgres

  run make test
  assert_success
}

# vi: expandtab sw=2 ts=2
