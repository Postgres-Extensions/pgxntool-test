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

@test "check-stale-expected depends on installcheck, so it runs after pg_regress, not before" {
  # check-stale-expected must run AFTER pg_regress (installcheck), not
  # before -- Make only guarantees order via a real dependency edge, not
  # position in TEST_DEPS, so this is enforced by `check-stale-expected:
  # installcheck` in base.mk. Verify via dry-run (no PostgreSQL needed):
  # the real installcheck pg_regress invocation must appear before the
  # check-stale-expected.sh call in the recipe order `make test` would run.
  run make -n test
  assert_success

  local pg_regress_line check_line
  pg_regress_line=$(echo "$output" | grep -n "pg_regress " | tail -1 | cut -d: -f1)
  check_line=$(echo "$output" | grep -n "check-stale-expected.sh" | head -1 | cut -d: -f1)

  [ -n "$pg_regress_line" ] || error "no pg_regress invocation found in 'make -n test' output"
  [ -n "$check_line" ] || error "check-stale-expected.sh invocation not found in 'make -n test' output"
  [ "$check_line" -gt "$pg_regress_line" ] || \
    error "check-stale-expected.sh (dry-run line $check_line) must come after pg_regress (line $pg_regress_line)"
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

@test "make test fails on a stale expected file, but only after pg_regress has already run" {
  # Unlike an early fail-fast design, check-stale-expected now depends on
  # installcheck, so pg_regress must have already produced real actual-output
  # files by the time make test fails on the stale file. test/results/*.out
  # is written for every test regardless of pass/fail (regression.diffs is
  # only written when a test actually differs, which the template's own
  # passing suite never triggers) -- so its presence is the correct proof
  # that pg_regress actually ran, not just that check-stale-expected itself
  # failed.
  touch test/expected/orphan_test.out
  rm -rf test/results

  run make test
  assert_failure
  assert_contains "$output" "orphan_test.out"

  local out_count
  out_count=$(find test/results -name '*.out' 2>/dev/null | wc -l)
  [ "$out_count" -gt 0 ] || error "test/results has no .out files -- pg_regress apparently never ran before check-stale-expected failed"

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
