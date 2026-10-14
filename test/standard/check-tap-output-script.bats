#!/usr/bin/env bats

# Test: check-tap-output.sh - pure script-logic unit tests
#
# These tests invoke test/bin/check-tap-output.sh directly on scratch files --
# no foundation environment, no `make`, no PostgreSQL. They own all of its
# decision logic: what counts as TAP output, and which TAP output fails.
#
# make-test.bats covers only base.mk's wiring (which files `make test` passes
# in, the PGXNTOOL_ENABLE_CHECK_TAP_OUTPUT=no skip, exit-status propagation)
# plus one real end-to-end failure; verify-results-pgtap-script.bats covers
# verify-results-pgtap.sh's use of this script.

load ../lib/helpers
load ../lib/assertions

setup_file() {
  setup_topdir
  load_test_env "check-tap-output-script"  # only resolves PGXNREPO; creates no foundation
}

setup() {
  load_test_env "check-tap-output-script"  # only resolves PGXNREPO; creates no foundation
  export SCRIPT="$PGXNREPO/test/bin/check-tap-output.sh"
  export OUTDIR="$BATS_TEST_TMPDIR/out"
  mkdir -p "$OUTDIR"
}

# Write $2 as the content of $OUTDIR/$1.out.
write_out() {
  printf '%s\n' "$2" > "$OUTDIR/$1.out"
}

@test "check-tap-output.sh: passes clean TAP output, no_plan() (plan last), a skip_all 1..0, and TODO failures" {
  write_out clean '\set ECHO none
1..2
ok 1
ok 2 - described
# TRANSACTION INTENTIONALLY LEFT OPEN!'
  write_out noplan '\set ECHO none
ok 1
ok 2 - described
1..2
# TRANSACTION INTENTIONALLY LEFT OPEN!'
  write_out skipall '1..0 # Skipped: nothing to do here'
  write_out todo '1..2
ok 1
not ok 2 - known issue # TODO fix later'

  run "$SCRIPT" "$OUTDIR/clean.out" "$OUTDIR/noplan.out" "$OUTDIR/skipall.out" "$OUTDIR/todo.out"
  assert_success
  [ -z "$output" ] || error "expected no output, got: $output"
}

@test "check-tap-output.sh: passes non-TAP files and ignores nonexistent arguments" {
  # Plain SQL output is not TAP even if it mentions pgTap's phrases mid-line,
  # and an unmatched shell glob arrives as a literal, nonexistent path.
  write_out plain '\set ECHO none

 x
---
 not ok here
(1 row)'

  run "$SCRIPT" "$OUTDIR/plain.out" "$OUTDIR/missing.out" "$OUTDIR/nomatch/*.out"
  assert_success

  run "$SCRIPT"
  assert_success

  # --list names just the TAP files, by the same definition, and checks
  # nothing: a failing TAP file is still listed with a zero exit.
  write_out failing '1..1
not ok 1'
  run "$SCRIPT" --list "$OUTDIR/plain.out" "$OUTDIR/failing.out" "$OUTDIR/missing.out"
  assert_success
  [ "$output" = "$OUTDIR/failing.out" ]
}

@test "check-tap-output.sh: fails on a not ok without TODO" {
  write_out failing '1..2
ok 1
not ok 2 - broken'

  run "$SCRIPT" "$OUTDIR/failing.out"
  assert_failure_with_status 1
  assert_contains "$output" "pgtap failure detected in $OUTDIR/failing.out"
  assert_contains "$output" "not ok 2 - broken"
}

@test "check-tap-output.sh: fails on pgTap's 'Looks like you planned' line" {
  write_out planned '1..3
ok 1
ok 2
# Looks like you planned 3 tests but ran 2'

  run "$SCRIPT" "$OUTDIR/planned.out"
  assert_failure_with_status 1
  assert_contains "$output" "pgtap plan mismatch in $OUTDIR/planned.out"
  assert_contains "$output" "Looks like you planned 3 tests but ran 2"
  # pgTap's own line already says it; no second count message.
  assert_not_contains "$output" "but found"
}

@test "check-tap-output.sh: fails when there is no plan line" {
  # A no_plan() test that died before finish() printed its plan.
  write_out noplan 'ok 1
ok 2'

  run "$SCRIPT" "$OUTDIR/noplan.out"
  assert_failure_with_status 1
  assert_contains "$output" "$OUTDIR/noplan.out has no plan line"
}

@test "check-tap-output.sh: fails on more than one plan line" {
  write_out twoplans '1..1
ok 1
1..1'

  run "$SCRIPT" "$OUTDIR/twoplans.out"
  assert_failure_with_status 1
  assert_contains "$output" "$OUTDIR/twoplans.out has 2 plan lines"
}

@test "check-tap-output.sh: fails when the test count differs from the plan" {
  # A plan(N) test that died partway through: no pgTap mismatch line at all.
  write_out short '1..3
ok 1
ERROR:  boom'
  write_out long '1..1
ok 1
ok 2'

  run "$SCRIPT" "$OUTDIR/short.out"
  assert_failure_with_status 1
  assert_contains "$output" "plan mismatch in $OUTDIR/short.out: planned 3 tests but found 1"

  run "$SCRIPT" "$OUTDIR/long.out"
  assert_failure_with_status 1
  assert_contains "$output" "planned 1 tests but found 2"
}

@test "check-tap-output.sh: counts only top-level lines, so subtests don't skew the plan" {
  write_out subtest '1..1
    1..2
    ok 1
    not ok 2
ok 1 - subtest'

  run "$SCRIPT" "$OUTDIR/subtest.out"
  assert_success
}

@test "check-tap-output.sh: reports every failing file and fails if any one fails" {
  write_out good '1..1
ok 1'
  write_out bad1 '1..1
not ok 1'
  write_out bad2 'ok 1'

  run "$SCRIPT" "$OUTDIR/good.out" "$OUTDIR/bad1.out" "$OUTDIR/bad2.out"
  assert_failure_with_status 1
  assert_contains "$output" "bad1.out"
  assert_contains "$output" "bad2.out"
  assert_not_contains "$output" "good.out"
}

# vi: expandtab ts=2 sw=2
