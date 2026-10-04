#!/usr/bin/env bats

# Test: check-test-install-error-stop.sh - pure script-logic unit tests
#
# These tests exercise test/bin/check-test-install-error-stop.sh directly
# against a bare scratch directory -- no foundation environment, no `make`,
# no PostgreSQL. They cover each branch of the script's pass/fail rule: an
# explicit `\set ON_ERROR_STOP on` passes even with a later turn-off;
# sourcing test/pgxntool/psql.sql passes only with no turn-off anywhere
# (`\set ... off` or `\unset`); anything else fails.
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

@test "check-test-install-error-stop.sh: passes when ON_ERROR_STOP is explicitly turned on then off" {
  printf '\\set ON_ERROR_STOP on\nCREATE TABLE foo AS SELECT 1;\n\\set ON_ERROR_STOP off\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_success
}

@test "check-test-install-error-stop.sh: fails when a file sources psql.sql and also turns ON_ERROR_STOP off" {
  printf '\\i test/pgxntool/psql.sql\nCREATE TABLE foo AS SELECT 1;\n\\set ON_ERROR_STOP off\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_failure_with_status 1
  assert_contains "$output" "foo.sql: includes psql.sql but also disables ON_ERROR_STOP"
}

@test "check-test-install-error-stop.sh: fails when a file sources psql.sql and also unsets ON_ERROR_STOP" {
  printf '\\i test/pgxntool/psql.sql\nCREATE TABLE foo AS SELECT 1;\n\\unset ON_ERROR_STOP\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_failure_with_status 1
  assert_contains "$output" "foo.sql: includes psql.sql but also disables ON_ERROR_STOP"
}

@test "check-test-install-error-stop.sh: fails when ON_ERROR_STOP is only ever turned off" {
  printf '\\set ON_ERROR_STOP off\nCREATE TABLE foo AS SELECT 1;\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_failure_with_status 1
  assert_contains "$output" "foo.sql"
  assert_contains "$output" "ON_ERROR_STOP"
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
