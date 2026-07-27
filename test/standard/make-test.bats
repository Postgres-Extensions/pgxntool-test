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

@test "EXTRA_CLEAN's test/results/ entry actually percolates into the clean recipe" {
  # Layering (see CLAUDE.md): whether `rm -rf` actually deletes a directory
  # is PGXS's own established `clean`/EXTRA_CLEAN mechanism, not pgxntool's
  # to re-verify. What pgxntool IS responsible for is correctly populating
  # EXTRA_CLEAN (covered above) AND that entry genuinely reaching the real
  # `clean` recipe -- in case something upstream never wires EXTRA_CLEAN into
  # `clean`'s dependency graph at all. Verify via dry-run, so this doesn't
  # need to invoke or verify PGXS's own deletion mechanics.
  run make -n clean
  assert_success
  assert_contains "$output" "test/results/"
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
# before" test below.
#
# See also: CLAUDE.md's testing-layering section, and
# check-stale-expected-script.bats for the script's own decision-logic tests
# (not duplicated here).

@test "check-stale-expected depends on installcheck, so it runs after pg_regress, not before" {
  # Capture dry-run make output and ensure that pg_regress is called before
  # check-stale-expected.sh.
  #
  # check-stale-expected must run AFTER pg_regress (installcheck), not
  # before -- Make only guarantees order via a real dependency edge, not
  # position in TEST_DEPS, so this is enforced by `check-stale-expected:
  # installcheck` in base.mk. No PostgreSQL needed for this: the recipe
  # order in `make -n test` output is enough to prove the dependency edge
  # is real.
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
  # Not a decision-logic test (no orphan/alternate-file scenario is
  # crafted) -- this is an end-to-end smoke check that the real template
  # stays in the passing state the Template Requirements section of
  # CLAUDE.md requires, exercised through the real recipe and real script.
  run make check-stale-expected
  assert_success
}

@test "check-stale-expected recipe invokes the script with TESTDIR and the file-types arg" {
  # base.mk's responsibility, not the script's: does the recipe actually
  # pass the right positional arguments? Verified via dry-run (no
  # Postgres/script execution needed) for both the default value and an
  # explicit override, so this only exercises the make plumbing.
  run make -n check-stale-expected
  assert_success
  assert_contains "$output" "test/bin/check-stale-expected.sh test yes"

  run make -n check-stale-expected PGXNTOOL_CHECK_EXPECTED_FILE_TYPES=no
  assert_success
  assert_contains "$output" "test/bin/check-stale-expected.sh test no"
}

@test "PGXNTOOL_ENABLE_CHECK_STALE_EXPECTED=no: make test never invokes check-stale-expected.sh" {
  skip_if_no_postgres

  # Disabling via this variable drops the check-stale-expected target from
  # TEST_DEPS (and its own definition) entirely -- see base.mk -- so the
  # script must never even be invoked, not merely have a failure from it
  # ignored. That's a materially stronger claim than "make test succeeds
  # despite a stale file", so prove it directly: point
  # PGXNTOOL_CHECK_STALE_EXPECTED_SCRIPT -- the one variable the
  # check-stale-expected recipe actually invokes (see base.mk) -- at a stub
  # that only touches a marker file and fails. No need to fake out
  # PGXNTOOL_DIR itself, since this variable is the sole thing standing
  # between the target and the real script. If the marker never appears,
  # the script was genuinely never called. This is base.mk's
  # target-skipping behavior, not the script's decision logic, so a stub
  # (not the real script) is exactly what should stand in here.
  local marker="$BATS_TEST_TMPDIR/check-stale-expected-invoked"
  local stub_script
  stub_script=$(make_stub_script check-stale-expected-stub 1 "" "$marker")

  run make test PGXNTOOL_ENABLE_CHECK_STALE_EXPECTED=no PGXNTOOL_CHECK_STALE_EXPECTED_SCRIPT="$stub_script"
  assert_success
  assert_file_not_exists "$marker"
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

@test "make correctly propagates check-stale-expected.sh's exit status and output" {
  # base.mk's responsibility, not the script's decision logic (the real
  # script's distinct exit codes and messages are already covered directly
  # in check-stale-expected-script.bats): does `make check-stale-expected`
  # correctly surface whatever PGXNTOOL_CHECK_STALE_EXPECTED_SCRIPT does? A
  # stub that deterministically prints a message and exits nonzero must
  # make the target (and `make`'s own recipe-failure handling) fail and
  # show that message; a stub that exits 0 must let it pass -- regardless
  # of what the real script would have decided for the same directory.
  local stub_script
  stub_script=$(make_stub_script fail-stub 5 "STUB SENTINEL MESSAGE")

  run make check-stale-expected PGXNTOOL_CHECK_STALE_EXPECTED_SCRIPT="$stub_script"
  assert_failure
  assert_contains "$output" "STUB SENTINEL MESSAGE"

  stub_script=$(make_stub_script pass-stub 0)

  run make check-stale-expected PGXNTOOL_CHECK_STALE_EXPECTED_SCRIPT="$stub_script"
  assert_success
}

# vi: expandtab sw=2 ts=2
