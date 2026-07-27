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

# ============================================================================
# EXTRA_CLEAN must target the real $(TESTOUT)/results/ directory (issue #7)
# ============================================================================
#
# PGXS's pg_regress_clean_files unconditionally rm -rf's a top-level results/,
# but pg_regress actually writes to $(TESTOUT)/results/ (test/results/ by
# default, via --outputdir in REGRESS_OPTS). EXTRA_CLEAN used to list a
# nonexistent top-level results/ instead of the real directory, so `make
# clean` never removed actual test output.

@test "EXTRA_CLEAN lists the real TESTOUT/results directory" {
  run make print-EXTRA_CLEAN
  assert_success
  assert_contains "$output" "test/results/"
}

@test "make clean removes the real test/results output directory" {
  mkdir -p test/results
  touch test/results/dummy.out
  assert_dir_exists "test/results"

  run make clean
  assert_success
  assert_dir_not_exists "test/results"
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

# Test: check-stale-expected (issue #14)
#
# `make test` never caught a stale test/expected/*.out left behind after a
# test/sql/*.sql file was renamed or removed. check-stale-expected fails
# loudly instead. It runs AFTER install/installcheck (pg_regress), via an
# explicit `check-stale-expected: installcheck` dependency edge in base.mk,
# not as an early fail-fast check -- see the "runs after pg_regress, not
# before" test below. It checks two directory pairs: test/sql <->
# test/expected, and test/build <-> test/build/expected.
#
# It also has to tolerate pg_regress's alternate expected-output files
# (test.out, test_0.out .. test_9.out -- see get_alternative_expectfile() in
# pg_regress.c), which a naive basename comparison would flag as orphaned
# since there's no matching test_1.sql etc. This is not a hypothetical edge
# case: pg_tle's own test suite ships pg_tle_perms_1.out/pg_tle_versions_1.out
# (see /root/git/pg_tle/test/expected/), and pgtap/pglogical/count_nulls use
# the same _N.out convention. This was the exact false positive caught in
# review before this fix landed, and is tested explicitly below.
#
# It also fails (distinctly, exit code 2 vs 1) if expected/ contains any
# file that isn't *.out -- disable-able on its own via
# PGXNTOOL_CHECK_EXPECTED_FILE_TYPES=no, independent of disabling the
# whole check via PGXNTOOL_ENABLE_CHECK_STALE_EXPECTED=no.

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
  # Exclude test-build's own (unrelated) pg_regress invocation, identified
  # by its --outputdir=test/build. test-build has no dependency relationship
  # with check-stale-expected -- position in TEST_DEPS is not an ordering
  # guarantee (see comment above) -- so depending on where test-build lands
  # in TEST_DEPS, its recipe can print before or after check-stale-expected's
  # in this dry-run, which would make a plain "last pg_regress mention"
  # search pick up the wrong invocation. Filtering it out leaves only the
  # main suite's pg_regress call, whose ordering relative to
  # check-stale-expected IS guaranteed (by the explicit dependency edge).
  pg_regress_line=$(echo "$output" | grep -n "pg_regress " | grep -v -- '--outputdir=test/build' | tail -1 | cut -d: -f1)
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
  skip_if_no_postgres

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

@test "check-stale-expected fails with a distinct message/exit code for a non-.out file in expected/" {
  touch test/expected/stray.txt

  # Invoke the script directly rather than through 'make': make's own exit
  # status on any recipe failure is always 2 regardless of the underlying
  # command's exit code, so verifying the script's own distinct exit codes
  # (1 = orphaned .out, 2 = unexpected non-.out file, 3 = both) requires
  # calling it directly.
  run pgxntool/test/bin/check-stale-expected.sh test
  assert_failure_with_status 2
  assert_contains "$output" "unexpected non-.out file"
  assert_contains "$output" "stray.txt"

  # 'make check-stale-expected' should still surface the same message.
  run make check-stale-expected
  assert_failure
  assert_contains "$output" "unexpected non-.out file"

  rm -f test/expected/stray.txt
}

@test "PGXNTOOL_CHECK_EXPECTED_FILE_TYPES=no disables the non-.out file sub-check" {
  touch test/expected/stray.txt

  run make check-stale-expected PGXNTOOL_CHECK_EXPECTED_FILE_TYPES=no
  assert_success

  rm -f test/expected/stray.txt
}

# vi: expandtab sw=2 ts=2
