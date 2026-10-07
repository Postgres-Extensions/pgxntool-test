#!/usr/bin/env bats

# Test: check-test-install-error-stop.sh - pure script-logic unit tests
#
# These tests exercise test/bin/check-test-install-error-stop.sh directly
# against a bare scratch directory -- no foundation environment, no `make`,
# and no PostgreSQL except the one psql.sql test at the end. The rule: a file fails only if it neither includes
# test/pgxntool/psql.sql nor has any `\set`/`\unset ON_ERROR_STOP` command,
# whatever the value or order.
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

@test "check-test-install-error-stop.sh: passes when a file sources psql.sql and turns ON_ERROR_STOP off" {
  printf '\\i test/pgxntool/psql.sql\nCREATE TABLE foo AS SELECT 1;\n\\set ON_ERROR_STOP OFF\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_success
}

@test "check-test-install-error-stop.sh: passes when a file sources psql.sql via \\ir and unsets ON_ERROR_STOP" {
  printf '\\ir ../pgxntool/psql.sql\nCREATE TABLE foo AS SELECT 1;\n\\unset ON_ERROR_STOP\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_success
}

@test "check-test-install-error-stop.sh: passes when a file sources psql.sql via \\include" {
  printf '\\include test/pgxntool/psql.sql\nCREATE TABLE foo AS SELECT 1;\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_success
}

@test "check-test-install-error-stop.sh: passes when a file sources psql.sql via \\include_relative" {
  printf '\\include_relative ../pgxntool/psql.sql\nCREATE TABLE foo AS SELECT 1;\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_success
}

@test "check-test-install-error-stop.sh: passes when an indented \\set ON_ERROR_STOP is the only mention" {
  printf '   \\set ON_ERROR_STOP on\nCREATE TABLE foo AS SELECT 1;\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_success
}

@test "check-test-install-error-stop.sh: passes when ON_ERROR_STOP is only ever turned off" {
  printf '\\set ON_ERROR_STOP 0\nCREATE TABLE foo AS SELECT 1;\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_success
}

@test "check-test-install-error-stop.sh: passes when ON_ERROR_STOP is only ever unset" {
  printf '\\unset ON_ERROR_STOP\nCREATE TABLE foo AS SELECT 1;\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_success
}

@test "check-test-install-error-stop.sh: passes when ON_ERROR_STOP is turned on then off" {
  printf '\\set ON_ERROR_STOP on\nCREATE TABLE foo AS SELECT 1;\n\\set ON_ERROR_STOP off\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_success
}

@test "check-test-install-error-stop.sh: passes when ON_ERROR_STOP is turned off then on" {
  printf '\\set ON_ERROR_STOP off\nCREATE TABLE foo AS SELECT 1;\n\\set ON_ERROR_STOP on\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_success
}

@test "check-test-install-error-stop.sh: passes when the \\set is the last line with no trailing newline" {
  printf 'CREATE TABLE foo AS SELECT 1;\n\\set ON_ERROR_STOP on' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_success
}

@test "check-test-install-error-stop.sh: fails when a file never mentions ON_ERROR_STOP" {
  printf 'CREATE TABLE foo AS SELECT 1;\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_failure_with_status 1
  assert_contains "$output" "foo.sql: never sets ON_ERROR_STOP"
}

@test "check-test-install-error-stop.sh: fails when ON_ERROR_STOP appears only in a comment" {
  printf -- '-- ON_ERROR_STOP is set by the caller\nCREATE TABLE foo AS SELECT 1;\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_failure_with_status 1
  assert_contains "$output" "foo.sql: never sets ON_ERROR_STOP"
}

@test "check-test-install-error-stop.sh: fails when a commented-out \\set ON_ERROR_STOP is the only mention" {
  printf -- '-- \\set ON_ERROR_STOP on\nCREATE TABLE foo AS SELECT 1;\n' > "$TESTDIR/install/foo.sql"

  run "$SCRIPT" "$TESTDIR"
  assert_failure_with_status 1
  assert_contains "$output" "foo.sql: never sets ON_ERROR_STOP"
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

# Guards the assumption check-test-install-error-stop.sh makes when it accepts
# files that include psql.sql. -X keeps ~/.psqlrc from masking a regression.
@test "test/pgxntool/psql.sql makes psql stop on error" {
  skip_if_no_postgres

  run psql -X -f "$PGXNREPO/test/pgxntool/psql.sql" -c 'SELECT 1/0' -c '\echo SENTINEL'
  assert_failure
  [[ "$output" != *SENTINEL* ]]
}
