#!/usr/bin/env bats

# Test: make test / make results / verify-results
#
# These three targets are one tightly-coupled pipeline -- `make results` and
# `make verify-results` only exist to safely update the expected output that
# `make test` checks against -- so they share a single file and a single
# foundation-copied environment rather than three. Covers:
# - `make test` succeeds against the template's known-good state
# - EXTRA_CLEAN targets the real $(TESTOUT)/results/ directory (issue #7)
# - unique per-directory database naming (REGRESS_DBNAME)
# - check-stale-expected catches orphaned test/expected/*.out files (issue #14)
# - verify-results blocks `make results` when tests are failing, detects
#   pgtap failures, and can be disabled

load ../lib/helpers

setup_file() {
  setup_topdir

  # Independent test - gets its own isolated environment with foundation TEST_REPO
  load_test_env "make-test"
  ensure_foundation "$TEST_DIR"

  # The verify-results/results tests below need a committed baseline expected
  # output file so they can create a detectable mismatch against it. Skip
  # this if PostgreSQL is unavailable -- `make results` needs a live server,
  # and those tests skip themselves via skip_if_no_postgres anyway.
  if check_postgres_available; then
    cd "$TEST_REPO"

    # State modification: Ensure expected output exists.
    # The template should already have it, but guard against it being missing or empty.
    if [ ! -f "test/expected/pgxntool-test.out" ] || [ ! -s "test/expected/pgxntool-test.out" ]; then
      make results
    fi

    # State modification: Ensure expected output is committed to git.
    # The verify-results/results tests below create a mismatch and check git
    # status to verify it, which only works if the baseline is committed.
    local status_output
    status_output=$(git status --porcelain test/expected/pgxntool-test.out)
    if [ -n "$status_output" ]; then
      git add test/expected/pgxntool-test.out
      git commit -m "Add baseline expected output"
    fi
  fi
}

setup() {
  load_test_env "make-test"
  cd "$TEST_REPO"
}

@test "make test succeeds" {
  run make test
  assert_success
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

  # Create a simple SQL test that queries the current database name.
  # \set ECHO none is required: pg_regress always runs test files through
  # `psql -a` (echo mode -- see psql_start_test() in pg_regress_main.c), so
  # without it every input line, including \a/\t themselves, gets echoed
  # verbatim into the output before it runs. This is the same convention
  # template/test/sql/base.sql already documents and relies on -- hand-writing
  # just the bare value here (without \set ECHO none) previously produced an
  # expected file that could never match pg_regress's real output; that
  # mismatch went unnoticed because make test's own diff output was never
  # inspected here.
  mkdir -p test/sql
  cat > test/sql/dbname.sql <<'EOF'
\set ECHO none
\a
\t
SELECT current_database();
EOF

  # Get the exact database name from make (authoritative source)
  # Output format: REGRESS_DBNAME is simple variable set to "value"
  local expected_dbname
  expected_dbname=$(make print-REGRESS_DBNAME 2>&1 | sed -n 's/.*set to "\(.*\)"/\1/p')
  [ -n "$expected_dbname" ] || error "Could not extract REGRESS_DBNAME from make"

  # Expected output is just the echoed `\set ECHO none` line itself (read
  # while ECHO was still "all") followed by the query's own bare result.
  mkdir -p test/expected
  printf '\\set ECHO none\n%s\n' "$expected_dbname" > test/expected/dbname.out
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
  # _CHECK_STALE_EXPECTED_SCRIPT -- the one variable the
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

  run make test PGXNTOOL_ENABLE_CHECK_STALE_EXPECTED=no _CHECK_STALE_EXPECTED_SCRIPT="$stub_script"
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
  # correctly surface whatever _CHECK_STALE_EXPECTED_SCRIPT does? A
  # stub that deterministically prints a message and exits nonzero must
  # make the target (and `make`'s own recipe-failure handling) fail and
  # show that message; a stub that exits 0 must let it pass -- regardless
  # of what the real script would have decided for the same directory.
  local stub_script
  stub_script=$(make_stub_script fail-stub 5 "STUB SENTINEL MESSAGE")

  run make check-stale-expected _CHECK_STALE_EXPECTED_SCRIPT="$stub_script"
  assert_failure
  assert_contains "$output" "STUB SENTINEL MESSAGE"

  stub_script=$(make_stub_script pass-stub 0)

  run make check-stale-expected _CHECK_STALE_EXPECTED_SCRIPT="$stub_script"
  assert_success
}

# ============================================================================
# verify-results / make results (issue #14)
# ============================================================================
#
# pgxntool makes verify-results depend on test (verify-results: test), so
# `make results` re-runs the tests and checks the FRESH regression.diffs,
# even under make -j.

@test "verify-results succeeds with clean template state" {
  skip_if_no_postgres

  run make verify-results
  assert_success
}

@test "verify-results depends on test execution" {
  # pgxntool makes verify-results depend on test (verify-results: test) so
  # that `make results` re-runs the tests and checks the FRESH
  # regression.diffs, even under make -j. Confirm the dependency is wired: a
  # dry-run of verify-results must include the installcheck recipe pulled in
  # via the test target.
  run make -n verify-results 2>&1
  assert_success
  assert_contains "$output" "installcheck"
}

@test "can modify expected output to create mismatch" {
  skip_if_no_postgres

  # Add a blank line to create a difference. This mismatch stays in place
  # through the rest of this section -- "make results updates expected
  # output" below is what finally fixes it.
  echo >> test/expected/pgxntool-test.out

  # Verify file was modified (should show as modified since it's committed)
  run git status --porcelain test/expected/pgxntool-test.out
  [ -n "$output" ]
  echo "$output" | grep -qE "^.M"
}

@test "make test shows diff with modified expected output" {
  skip_if_no_postgres

  # Run make test (should show diffs due to mismatch).
  # Note: make test doesn't exit non-zero due to .IGNORE: installcheck.
  run make test

  echo "$output" | grep -q "diff"
}

@test "make results is blocked by verify-results when tests fail" {
  skip_if_no_postgres

  # The previous test's mismatch is still in place. verify-results depends
  # on test, so its rerun of the suite fails again and blocks make results.
  run make results
  assert_failure
  assert_contains "$output" "Cannot run 'make results'"
}

@test "verify-results blocks when invoked directly, not just via results" {
  skip_if_no_postgres

  # Same mismatch as above, but this test invokes `make verify-results`
  # directly instead of going through `results` -- a distinct entry point
  # worth covering on its own, since `results` only reaches verify-results
  # as a prerequisite.
  run make verify-results
  assert_failure
  assert_contains "$output" "Tests are failing"
  assert_contains "$output" "Cannot run 'make results'"
}

@test "verify-results can be disabled" {
  # With verify-results disabled, results depends only on test, so its
  # dry-run never mentions the verify-results block message. We check
  # for the actual block message rather than the bare string
  # "verify-results", since that could spuriously match make's own
  # "Entering directory" banners depending on the environment's path.
  run make -n results PGXNTOOL_ENABLE_VERIFY_RESULTS=no 2>&1
  assert_success
  assert_not_contains "$output" "Cannot run 'make results'"
}

@test "make results updates expected output" {
  skip_if_no_postgres

  # Run make results with verify-results disabled to actually fix the mismatch.
  # Disabling verify-results lets make results run the suite and copy the
  # fresh results to expected/, fixing the mismatch.
  run make PGXNTOOL_ENABLE_VERIFY_RESULTS=no results
  assert_success
}

@test "make test succeeds after make results" {
  skip_if_no_postgres

  # Now make test should pass
  run make test
  assert_success
}

@test "verify-results detects pgtap failures in result files" {
  skip_if_no_postgres

  mkdir -p test/results
  cat > test/results/pgtap_fail.out <<'EOF'
1..2
ok 1 - passing test
not ok 2 - failing test
EOF

  run make verify-results
  assert_failure
  assert_contains "$output" "pgtap failure detected"

  rm -f test/results/pgtap_fail.out
}

@test "verify-results ignores pgtap TODO failures" {
  skip_if_no_postgres

  mkdir -p test/results
  cat > test/results/pgtap_todo.out <<'EOF'
1..1
not ok 1 - known issue # TODO fix later
EOF

  run make verify-results
  assert_success

  rm -f test/results/pgtap_todo.out
}

@test "verify-results detects pgtap plan mismatch" {
  skip_if_no_postgres

  mkdir -p test/results
  cat > test/results/pgtap_plan.out <<'EOF'
1..3
ok 1 - test one
ok 2 - test two
# Looks like you planned 3 tests but ran 2
EOF

  run make verify-results
  assert_failure
  assert_contains "$output" "pgtap plan mismatch"

  rm -f test/results/pgtap_plan.out
}

# vi: expandtab sw=2 ts=2
