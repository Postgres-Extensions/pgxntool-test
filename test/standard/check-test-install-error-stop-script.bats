#!/usr/bin/env bats

# Test: check-test-install-error-stop.sh - pure script-logic unit tests
#
# These tests exercise test/bin/check-test-install-error-stop.sh directly
# against a bare scratch directory -- no foundation environment, no `make`,
# no PostgreSQL. They cover the script's own pass/fail logic: direct
# ON_ERROR_STOP, sourcing test/pgxntool/psql.sql, and files with neither.
#
# Tests that need real Make integration (TEST_DEPS wiring,
# PGXNTOOL_ENABLE_TEST_INSTALL_ERROR_STOP_CHECK=no skipping the target) stay
# in make-test.bats.

load ../lib/helpers
load ../lib/assertions

setup_file() {
  setup_topdir
  load_test_env "check-test-install-error-stop-script"
}

setup() {
  load_test_env "check-test-install-error-stop-script"
  export SCRIPT="$PGXNREPO/test/bin/check-test-install-error-stop.sh"

  # Fresh, empty scratch directory per test -- no foundation/TEST_REPO needed.
  export TESTDIR="$BATS_TEST_TMPDIR/testdir"
  mkdir -p "$TESTDIR/install"
}

@test "check-test-install-error-stop.sh: passes when a file sets ON_ERROR_STOP directly" {
  printf '\\set ON_ERROR_STOP on\nCREATE TABLE foo AS SELECT 1;\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_success
}

@test "check-test-install-error-stop.sh: passes when a file sources test/pgxntool/psql.sql" {
  printf '\\i test/pgxntool/psql.sql\nCREATE TABLE foo AS SELECT 1;\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_success
}

@test "check-test-install-error-stop.sh: fails when a file has neither" {
  printf 'CREATE TABLE foo AS SELECT 1;\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_failure_with_status 1
  assert_contains "$output" "foo.sql"
  assert_contains "$output" "ON_ERROR_STOP"
}

@test "check-test-install-error-stop.sh: reports every offending file, not just the first" {
  printf 'CREATE TABLE foo AS SELECT 1;\n' > "$TESTDIR/install/foo.sql"
  printf 'CREATE TABLE bar AS SELECT 1;\n' > "$TESTDIR/install/bar.sql"
  printf '\\set ON_ERROR_STOP on\nCREATE TABLE baz AS SELECT 1;\n' > "$TESTDIR/install/baz.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_failure_with_status 1
  assert_contains "$output" "foo.sql"
  assert_contains "$output" "bar.sql"
}

@test "check-test-install-error-stop.sh: passes on an empty test/install/ directory" {
  run "$SCRIPT" "$TESTDIR"
  assert_success
}

@test "check-test-install-error-stop.sh: requires exactly one argument" {
  run "$SCRIPT"
  assert_failure

  run "$SCRIPT" "$TESTDIR" extra
  assert_failure
}
