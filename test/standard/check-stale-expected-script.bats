#!/usr/bin/env bats

# Test: check-stale-expected.sh - pure script-logic unit tests
#
# These tests exercise test/bin/check-stale-expected.sh directly against a
# bare scratch directory -- no foundation environment, no `make`, no
# PostgreSQL. They cover the script's own file-comparison logic: orphaned
# .out detection, the pg_regress _N.out alternate-file convention (see
# get_alternative_expectfile() in pg_regress.c), the test/build <->
# test/build/expected pair, the non-.out file-type sub-check (now the
# script's second positional argument -- see check-stale-expected.sh's own
# Usage comment), and basic argument validation.
#
# Tests that need real Make/PostgreSQL integration (ordering relative to
# pg_regress, the PGXNTOOL_ENABLE_CHECK_STALE_EXPECTED=no target-skipping
# behavior, and a real `make test` failure on a stale file) stay in
# make-test.bats.

load ../lib/helpers
load ../lib/assertions

setup_file() {
  setup_topdir
  load_test_env "check-stale-expected-script"
}

setup() {
  load_test_env "check-stale-expected-script"
  export SCRIPT="$PGXNREPO/test/bin/check-stale-expected.sh"

  # Fresh, empty scratch directory per test -- no foundation/TEST_REPO needed.
  export TESTDIR="$BATS_TEST_TMPDIR/testdir"
  mkdir -p "$TESTDIR/sql" "$TESTDIR/expected"
}

@test "check-stale-expected.sh: passes when expected/ exactly mirrors sql/" {
  touch "$TESTDIR/sql/foo.sql"
  touch "$TESTDIR/expected/foo.out"

  run "$SCRIPT" "$TESTDIR"
  assert_success
}

@test "check-stale-expected.sh: fails on an orphaned expected/*.out with no corresponding sql/*.sql" {
  touch "$TESTDIR/sql/foo.sql"
  touch "$TESTDIR/expected/foo.out"
  touch "$TESTDIR/expected/orphan.out"

  run "$SCRIPT" "$TESTDIR"
  assert_failure_with_status 1
  assert_contains "$output" "orphan.out"
  assert_contains "$output" "no corresponding"
}

@test "check-stale-expected.sh: tolerates a pg_regress alternate _N.out file when the base .sql exists" {
  touch "$TESTDIR/sql/foo.sql"
  touch "$TESTDIR/expected/foo.out"
  touch "$TESTDIR/expected/foo_1.out"

  run "$SCRIPT" "$TESTDIR"
  assert_success
}

@test "check-stale-expected.sh: still fails when an alternate _N.out's own base .sql is missing" {
  # phantom_1.out has no phantom.sql -- the _N.out exemption must not
  # blanket-exempt every _N.out file, only ones whose stripped base matches
  # a real .sql file.
  touch "$TESTDIR/expected/phantom_1.out"

  run "$SCRIPT" "$TESTDIR"
  assert_failure_with_status 1
  assert_contains "$output" "phantom_1.out"
}

@test "check-stale-expected.sh: also checks the build <-> build/expected pair" {
  mkdir -p "$TESTDIR/build/expected"
  touch "$TESTDIR/build/build_check.sql"
  touch "$TESTDIR/build/expected/build_check.out"
  touch "$TESTDIR/build/expected/orphan_build.out"

  run "$SCRIPT" "$TESTDIR"
  assert_failure_with_status 1
  assert_contains "$output" "orphan_build.out"
}

@test "check-stale-expected.sh: build <-> build/expected pair also tolerates the _N.out convention" {
  mkdir -p "$TESTDIR/build/expected"
  touch "$TESTDIR/build/build_check.sql"
  touch "$TESTDIR/build/expected/build_check.out"
  touch "$TESTDIR/build/expected/build_check_1.out"

  run "$SCRIPT" "$TESTDIR"
  assert_success
}

@test "check-stale-expected.sh: non-.out file in expected/ fails distinctly, defaulting to check enabled" {
  touch "$TESTDIR/sql/foo.sql"
  touch "$TESTDIR/expected/foo.out"
  touch "$TESTDIR/expected/stray.txt"

  run "$SCRIPT" "$TESTDIR"
  assert_failure_with_status 2
  assert_contains "$output" "unexpected non-.out file"
  assert_contains "$output" "stray.txt"
}

@test "check-stale-expected.sh: check-file-types=yes explicitly enables the non-.out file check" {
  touch "$TESTDIR/sql/foo.sql"
  touch "$TESTDIR/expected/foo.out"
  touch "$TESTDIR/expected/stray.txt"

  run "$SCRIPT" "$TESTDIR" yes
  assert_failure_with_status 2
  assert_contains "$output" "unexpected non-.out file"
}

@test "check-stale-expected.sh: check-file-types=no disables the non-.out file check" {
  touch "$TESTDIR/sql/foo.sql"
  touch "$TESTDIR/expected/foo.out"
  touch "$TESTDIR/expected/stray.txt"

  run "$SCRIPT" "$TESTDIR" no
  assert_success
}

@test "check-stale-expected.sh: exit code is a bitmask of both failure classes" {
  touch "$TESTDIR/expected/orphan.out"
  touch "$TESTDIR/expected/stray.txt"

  run "$SCRIPT" "$TESTDIR"
  assert_failure_with_status 3
  assert_contains "$output" "orphan.out"
  assert_contains "$output" "stray.txt"
}

@test "check-stale-expected.sh: usage error when called with no testdir argument" {
  run "$SCRIPT"
  assert_failure_with_status 1
  assert_contains "$output" "Usage:"
}

@test "check-stale-expected.sh: usage error when called with more than two arguments" {
  run "$SCRIPT" "$TESTDIR" yes extra
  assert_failure_with_status 1
  assert_contains "$output" "Usage:"
}

# vi: expandtab ts=2 sw=2
