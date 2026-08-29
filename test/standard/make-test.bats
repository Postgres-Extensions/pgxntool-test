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
# - installcheck always runs after install, even when pulled in indirectly
#   (issue #79)
# - PGXNTOOL_ENABLE_FS_INSTALL can disable the install prerequisite entirely,
#   for "existing mode"/pg_tle-style testing (issues #55, #90)
# - PGXNTOOL_ENABLE_PGXN_INSTALL can independently disable the pgtap
#   dependency's own `pgxn install --sudo` auto-install
# - check-stale-expected catches orphaned test/expected/*.out files (issue #14)
# - `make test` exits non-zero on a real regression.diffs mismatch (issue #49)
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
  # mismatch went unnoticed only because of issue #49 (make test always
  # exiting 0 regardless of regression.diffs).
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

# Test: installcheck must run after install, even when pulled in indirectly
# (issue #79)
#
# `test`'s TEST_DEPS lists `install installcheck` (and check-stale-expected,
# which itself depends on installcheck -- see issue #14 below) as
# independent, unordered prerequisites -- Make doesn't guarantee unrelated
# same-target prerequisites build left-to-right. Before this fix,
# installcheck had no dependency on install, so nothing stopped it from
# running first: on a genuinely uninstalled tree, pg_regress ran against a
# database missing the extension, failing every test with "schema ... does
# not exist". base.mk now has an explicit `installcheck: install` edge
# (mirroring test-build's own `test-build: install` edge), so install
# always runs first.

@test "installcheck's parsed prerequisite list includes install (issue #79, structural proof)" {
  # make -p dumps Make's internal parsed-rule database, independent of
  # runtime scheduling order. This proves the `installcheck: install` edge
  # genuinely exists in base.mk -- unlike a real `make test` run, which could
  # theoretically pass even on a broken base.mk purely by luck of Make's
  # scheduling order for unrelated same-target prerequisites (see the
  # behavioral test below).
  run make -p -n installcheck
  assert_success

  local prereq_line
  prereq_line=$(echo "$output" | awk '/^installcheck:/{print; exit}')
  [ -n "$prereq_line" ] || error "installcheck rule not found in 'make -p' database dump"

  # Split on whitespace and match the exact "install" token -- grep -w alone
  # would also match inside "test/install/schedule" (PGXNTOOL_ENABLE_TEST_INSTALL's
  # generated schedule file path), which is word-bounded by slashes too.
  echo "$prereq_line" | tr ' ' '\n' | grep -qx install || \
    error "installcheck's parsed prerequisite list does not include 'install': $prereq_line"
}

@test "make test succeeds from a genuinely uninstalled state (issue #79)" {
  skip_if_no_postgres

  # The `make -p` test above is the primary proof for this issue (the
  # dependency edge genuinely exists in the parsed makefile). This test is a
  # complementary real-world sanity check of the whole pipeline: on a
  # genuinely uninstalled tree, does pg_regress actually find the extension
  # already installed by the time it runs? `make uninstall` forces that
  # precondition regardless of what any earlier test in this file already
  # installed on the shared PostgreSQL instance -- the original bug was
  # historically masked in exactly that way.
  run make uninstall
  assert_success

  run make test
  assert_success
  assert_not_contains "$output" "does not exist"
}

# ============================================================================
# install/installcheck can skip filesystem install (issues #55, #90)
# ============================================================================
#
# `test`/`verify-results` always filesystem-installed the extension via
# PGXS's `install`, and `installcheck` always depended on `install` (the
# issue #79 fix, tested above) -- with no way to disable either. That defeats
# "existing mode" testing, where the extension under test was deployed some
# other way (e.g. a pg_tle registration, or a real pg_upgrade) and the whole
# point is to prove that other deployment path works -- filesystem-installing
# as a side effect defeats it. PGXNTOOL_ENABLE_FS_INSTALL=no removes both the
# TEST_DEPS `install` entry and the `installcheck: install` edge.

@test "PGXNTOOL_ENABLE_FS_INSTALL=no removes install from installcheck's parsed prerequisite list" {
  # Same structural technique as the issue #79 test above, inverted: prove
  # the edge is genuinely gone, not just that a real run happened to succeed
  # regardless of scheduling order.
  run make -p -n installcheck PGXNTOOL_ENABLE_FS_INSTALL=no
  assert_success

  local prereq_line
  prereq_line=$(echo "$output" | awk '/^installcheck:/{print; exit}')
  [ -n "$prereq_line" ] || error "installcheck rule not found in 'make -p' database dump"

  # Split on whitespace and match the exact "install" token -- grep -w would
  # false-positive on the unrelated "test/install/schedule" path (PGXNTOOL_ENABLE_TEST_INSTALL's
  # generated schedule file), which is also a word-bounded "install" once
  # surrounded by slashes.
  if echo "$prereq_line" | tr ' ' '\n' | grep -qx install; then
    error "installcheck's parsed prerequisite list still includes 'install' with PGXNTOOL_ENABLE_FS_INSTALL=no: $prereq_line"
  fi
}

@test "PGXNTOOL_ENABLE_FS_INSTALL=no removes install's recipe from make test's dry run" {
  run make -n test PGXNTOOL_ENABLE_FS_INSTALL=no
  assert_success
  assert_not_contains "$output" "install -c -m 644"
}

@test "PGXNTOOL_ENABLE_FS_INSTALL rejects invalid values" {
  run make print-PGXNTOOL_ENABLE_FS_INSTALL PGXNTOOL_ENABLE_FS_INSTALL=bogus
  assert_failure
  assert_contains "$output" "PGXNTOOL_ENABLE_FS_INSTALL must be"
}

@test "make test succeeds with PGXNTOOL_ENABLE_FS_INSTALL=no when the extension is already installed" {
  skip_if_no_postgres

  # Stands in for "existing mode": the extension is already deployed (here,
  # via a normal install) before test/installcheck ever runs, so disabling
  # the FS install prerequisite shouldn't stop the suite from passing.
  run make install
  assert_success

  run make test PGXNTOOL_ENABLE_FS_INSTALL=no
  assert_success
}

@test "make test fails with PGXNTOOL_ENABLE_FS_INSTALL=no against a genuinely uninstalled tree" {
  skip_if_no_postgres

  # Inverse of the issue #79 test above: with filesystem install disabled,
  # pg_regress must run against whatever's already there -- on a genuinely
  # uninstalled tree that means failure, which is the real-world proof that
  # `install` genuinely didn't run as a side effect (the structural test
  # above already proves the edge itself is gone; this proves it matters).
  run make uninstall
  assert_success

  run make test PGXNTOOL_ENABLE_FS_INSTALL=no
  assert_failure
  assert_contains "$output" "does not exist"

  # Restore installed state for the rest of this file's tests.
  run make install
  assert_success
}

# ----------------------------------------------------------------------------
# pgtap auto-install can be disabled independently (PGXNTOOL_ENABLE_PGXN_INSTALL)
# ----------------------------------------------------------------------------
#
# `installcheck` also auto-installs the pgtap dependency via `pgxn install
# pgtap --sudo` when it isn't already filesystem-installed -- itself a
# filesystem-install side effect, and the same problem
# PGXNTOOL_ENABLE_FS_INSTALL solves for the extension under test.
# PGXNTOOL_ENABLE_PGXN_INSTALL defaults to following PGXNTOOL_ENABLE_FS_INSTALL,
# but can be set independently.

@test "PGXNTOOL_ENABLE_PGXN_INSTALL defaults to following PGXNTOOL_ENABLE_FS_INSTALL" {
  run make print-PGXNTOOL_ENABLE_PGXN_INSTALL
  assert_success
  assert_contains "$output" 'set to "yes"'

  run make print-PGXNTOOL_ENABLE_PGXN_INSTALL PGXNTOOL_ENABLE_FS_INSTALL=no
  assert_success
  assert_contains "$output" 'set to "no"'
}

@test "PGXNTOOL_ENABLE_PGXN_INSTALL can be set independently of PGXNTOOL_ENABLE_FS_INSTALL" {
  run make print-PGXNTOOL_ENABLE_PGXN_INSTALL PGXNTOOL_ENABLE_FS_INSTALL=no PGXNTOOL_ENABLE_PGXN_INSTALL=yes
  assert_success
  assert_contains "$output" 'set to "yes"'
}

@test "PGXNTOOL_ENABLE_PGXN_INSTALL=no removes pgtap's recipe from a dry-run installcheck" {
  # pgtap's file-check target ($(DESTDIR)$(datadir)/extension/pgtap.control)
  # is already satisfied on this machine (pgtap is genuinely installed), so
  # a plain dry-run never shows the "pgxn install" recipe regardless of this
  # variable -- it wouldn't prove anything either way. Pointing DESTDIR at a
  # nonexistent path makes that file-check target genuinely unsatisfied,
  # forcing the recipe to appear in a *dry* run (nothing is actually
  # installed there -- -n never executes it) -- that's what actually proves
  # PGXNTOOL_ENABLE_PGXN_INSTALL gates it.
  local fake_destdir="$BATS_TEST_TMPDIR/fake-destdir"

  run make -n installcheck "DESTDIR=$fake_destdir"
  assert_success
  assert_contains "$output" "pgxn install pgtap --sudo"

  run make -n installcheck "DESTDIR=$fake_destdir" PGXNTOOL_ENABLE_PGXN_INSTALL=no
  assert_success
  assert_not_contains "$output" "pgxn install pgtap --sudo"
}

@test "PGXNTOOL_ENABLE_PGXN_INSTALL rejects invalid values" {
  run make print-PGXNTOOL_ENABLE_PGXN_INSTALL PGXNTOOL_ENABLE_PGXN_INSTALL=bogus
  assert_failure
  assert_contains "$output" "PGXNTOOL_ENABLE_PGXN_INSTALL must be"
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
# verify-results / make results (issues #14, #49)
# ============================================================================
#
# `results` depends on `verify-results` (when enabled), which depends on
# $(TEST_DEPS) -- testdeps/install/installcheck/etc -- directly, NOT on the
# `test` target itself (see base.mk's comment above `verify-results:
# $(TEST_DEPS)`). So `make results` reruns the suite by pulling in those
# prerequisites fresh, rather than by invoking `test`. This matters because
# `test`'s own recipe now exits 1 as soon as it sees regression.diffs (issue
# #49's fix, tested below) -- if `results`/`verify-results` depended on
# `test` instead, that exit would abort the chain before verify-results ever
# got to inspect the diff and report it.

@test "verify-results succeeds with clean template state" {
  skip_if_no_postgres

  run make verify-results
  assert_success
}

@test "verify-results pulls in installcheck via TEST_DEPS, not by depending on test" {
  # Confirm the dependency is wired: a dry-run of verify-results must
  # include the installcheck recipe pulled in via $(TEST_DEPS) (see the
  # section header above for why it's $(TEST_DEPS) and not `test` itself).
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

@test "make test shows diff with modified expected output, and exits non-zero (issue #49)" {
  skip_if_no_postgres

  run make test
  # Ensure make exited non-zero
  assert_failure

  # Confirms the pre-existing cat behavior wasn't lost while adding the exit.
  echo "$output" | grep -q "diff"
}

@test "make results is blocked by verify-results when tests fail" {
  skip_if_no_postgres

  # The previous test's mismatch is still in place, so verify-results's
  # rerun of $(TEST_DEPS) fails again and blocks make results.
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
  # With verify-results disabled, results depends only on $(TEST_DEPS), so
  # its dry-run never mentions the verify-results block message. We check
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
