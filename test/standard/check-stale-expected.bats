#!/usr/bin/env bats

# Test: check-stale-expected (issue #14)
#
# `make test` never caught a stale test/expected/*.out left behind after a
# test/sql/*.sql file was renamed or removed. check-stale-expected fails
# loudly instead, and is wired into TEST_DEPS so `make test` runs it first
# (before install/installcheck, so no PostgreSQL is needed to observe the
# failure). It checks two directory pairs: test/sql <-> test/expected, and
# test/build <-> test/build/expected.
#
# It also has to tolerate pg_regress's alternate expected-output files
# (test.out, test_0.out .. test_9.out -- see get_alternative_expectfile() in
# pg_regress.c), which a naive basename comparison would flag as orphaned
# since there's no matching test_1.sql etc. This is not a hypothetical edge
# case: pg_tle's own test suite ships pg_tle_perms_1.out/pg_tle_versions_1.out
# (see /root/git/pg_tle/test/expected/), and pgtap/pglogical/count_nulls use
# the same _N.out convention. This was the exact false positive caught in
# review before this fix landed, and is tested explicitly below.

load ../lib/helpers

setup_file() {
  setup_topdir

  load_test_env "check-stale-expected"
  ensure_foundation "$TEST_DIR"
}

setup() {
  load_test_env "check-stale-expected"
  cd_test_env
}

@test "check-stale-expected passes on clean template state" {
  run make check-stale-expected
  assert_success
}

@test "check-stale-expected fails on an orphaned test/expected/*.out" {
  touch test/expected/orphan_test.out

  run make check-stale-expected
  assert_failure
  assert_contains "$output" "orphan_test.out"
  assert_contains "$output" "no corresponding"

  rm -f test/expected/orphan_test.out
}

@test "make test fails fast on a stale expected file, before install/installcheck" {
  # check-stale-expected is first in TEST_DEPS, so `make test` must fail here
  # without ever needing PostgreSQL -- confirms the wiring, not just the
  # standalone target.
  touch test/expected/orphan_test.out

  run make test
  assert_failure
  assert_contains "$output" "orphan_test.out"

  rm -f test/expected/orphan_test.out
}

@test "check-stale-expected does not false-flag pg_regress alternate files (_N.out)" {
  # base.sql exists in the template, so base_1.out must be tolerated as an
  # alternate expected file for it, not flagged as orphaned.
  touch test/expected/base_1.out

  run make check-stale-expected
  assert_success

  rm -f test/expected/base_1.out
}

@test "check-stale-expected still fails when the alternate file's own base .sql is missing" {
  # phantom_1.out has no phantom.sql either -- the _N.out exemption must not
  # blanket-exempt every _N.out file, only ones whose stripped base matches
  # a real .sql file.
  touch test/expected/phantom_1.out

  run make check-stale-expected
  assert_failure
  assert_contains "$output" "phantom_1.out"

  rm -f test/expected/phantom_1.out
}

@test "check-stale-expected also checks the test/build <-> test/build/expected pair" {
  touch test/build/expected/orphan_build.out

  run make check-stale-expected
  assert_failure
  assert_contains "$output" "orphan_build.out"

  rm -f test/build/expected/orphan_build.out

  # And tolerates the same _N.out alternate-file convention there too.
  # build_check.sql exists in the template.
  touch test/build/expected/build_check_1.out

  run make check-stale-expected
  assert_success

  rm -f test/build/expected/build_check_1.out
}

# vi: expandtab sw=2 ts=2
