#!/usr/bin/env bats

# Test: verify-tap.sh - pure script-logic unit tests
#
# These tests invoke pgxntool's verify-tap.sh directly on scratch files and
# stdin -- no foundation environment, no `make`, no PostgreSQL. They own all
# of its decision logic: which TAP streams fail, how inputs are named, and
# its exit codes. verify-results-pgtap-script.bats covers
# verify-results-pgtap.sh's use of this script.

load ../lib/helpers
load ../lib/assertions

setup_file() {
  setup_topdir
  load_test_env "verify-tap-script"  # only resolves PGXNREPO; creates no foundation
}

setup() {
  load_test_env "verify-tap-script"  # only resolves PGXNREPO; creates no foundation
  export SCRIPT="$PGXNREPO/verify-tap.sh"
  export OUTDIR="$BATS_TEST_TMPDIR/out"
  mkdir -p "$OUTDIR"
}

# Write $2 as the content of $OUTDIR/$1.out.
write_out() {
  printf '%s\n' "$2" > "$OUTDIR/$1.out"
}

@test "verify-tap.sh: passes clean TAP, plan last, a skip_all 1..0, TODO failures and subtests" {
  write_out clean '\set ECHO none
1..2
ok 1
ok 2 - described
# TRANSACTION INTENTIONALLY LEFT OPEN!'
  write_out planlast 'ok 1
ok 2 - described
1..2'
  write_out skipall '1..0 # Skipped: nothing to do here'
  write_out todo '1..2
ok 1
not ok 2 - known issue # TODO fix later'
  # Indented subtest lines count toward nothing, failures included.
  write_out subtest '1..1
    1..2
    ok 1
    not ok 2
    Bail out!
ok 1 - subtest'

  run "$SCRIPT" "$OUTDIR/clean.out" "$OUTDIR/planlast.out" "$OUTDIR/skipall.out" \
    "$OUTDIR/todo.out" "$OUTDIR/subtest.out"
  assert_success
  [ -z "$output" ] || error "expected no output, got: $output"
}

@test "verify-tap.sh: fails on not ok, Bail out! and pgTAP's 'Looks like you planned' line" {
  write_out failing '1..2
ok 1
not ok 2 - broken'
  run "$SCRIPT" "$OUTDIR/failing.out"
  assert_failure_with_status 1
  assert_contains "$output" "pgtap failure detected in $OUTDIR/failing.out"
  assert_contains "$output" "not ok 2 - broken"

  write_out bail '1..2
ok 1
Bail out! database went away'
  run "$SCRIPT" "$OUTDIR/bail.out"
  assert_failure_with_status 1
  assert_contains "$output" "bailed out in $OUTDIR/bail.out"
  assert_contains "$output" "Bail out! database went away"

  write_out planned '1..3
ok 1
ok 2
# Looks like you planned 3 tests but ran 2'
  run "$SCRIPT" "$OUTDIR/planned.out"
  assert_failure_with_status 1
  assert_contains "$output" "pgtap plan mismatch in $OUTDIR/planned.out"
  assert_contains "$output" "Looks like you planned 3 tests but ran 2"
  # pgTAP's own line already says it; no second count message.
  assert_not_contains "$output" "but found"
}

@test "verify-tap.sh: fails without exactly one plan line, placed first or last" {
  # A no_plan() test that died before finish() printed its plan.
  write_out noplan 'ok 1
ok 2'
  run "$SCRIPT" "$OUTDIR/noplan.out"
  assert_failure_with_status 1
  assert_contains "$output" "$OUTDIR/noplan.out has no plan line"

  write_out twoplans '1..1
ok 1
1..1'
  run "$SCRIPT" "$OUTDIR/twoplans.out"
  assert_failure_with_status 1
  assert_contains "$output" "$OUTDIR/twoplans.out has 2 plan lines"

  write_out middle 'ok 1
1..2
ok 2'
  run "$SCRIPT" "$OUTDIR/middle.out"
  assert_failure_with_status 1
  assert_contains "$output" "$OUTDIR/middle.out has its plan line (1..N) between test lines"
}

@test "verify-tap.sh: fails when the test count differs from the plan" {
  # A plan(N) test that died partway through: no pgTAP mismatch line at all.
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

@test "verify-tap.sh: fails on input with no TAP at all, unless --skip-non-tap skips it" {
  # Plain SQL output, even mentioning TAP phrases mid-line, means nothing ran.
  write_out plain '\set ECHO none

 x
---
 not ok here
(1 row)'

  run "$SCRIPT" "$OUTDIR/plain.out"
  assert_failure_with_status 1
  assert_contains "$output" "no TAP output in $OUTDIR/plain.out"

  run "$SCRIPT" --skip-non-tap "$OUTDIR/plain.out"
  assert_success
  [ -z "$output" ] || error "expected no output, got: $output"

  # Skipping is only for input with no TAP lines; a TAP stream beside it is
  # still judged, wherever the flag goes, and so is stdin.
  write_out bad '1..1
not ok 1'
  run "$SCRIPT" "$OUTDIR/plain.out" "$OUTDIR/bad.out" --skip-non-tap
  assert_failure_with_status 1
  assert_contains "$output" "pgtap failure detected in $OUTDIR/bad.out"
  assert_not_contains "$output" "plain.out"

  run bash -c '"$SCRIPT" --skip-non-tap < "$OUTDIR/plain.out"'
  assert_success
  run bash -c '"$SCRIPT" --skip-non-tap < "$OUTDIR/bad.out"'
  assert_failure_with_status 1
}

@test "verify-tap.sh: reads stdin with no arguments or '-', reporting to stderr as stdin" {
  run bash -c 'printf "1..1\nok 1\n" | "$SCRIPT"'
  assert_success

  write_out bad '1..1
not ok 1'
  run bash -c '"$SCRIPT" < "$OUTDIR/bad.out"'
  assert_failure_with_status 1
  assert_contains "$output" "pgtap failure detected in stdin"

  # `-` mixes with files; every diagnostic goes to stderr, none to stdout.
  write_out good '1..1
ok 1'
  run bash -c '"$SCRIPT" "$OUTDIR/good.out" - < "$OUTDIR/bad.out" 2>/dev/null'
  assert_failure_with_status 1
  [ -z "$output" ] || error "expected nothing on stdout, got: $output"
  run bash -c '"$SCRIPT" "$OUTDIR/good.out" - < "$OUTDIR/bad.out" 2>&1 >/dev/null'
  assert_contains "$output" "pgtap failure detected in stdin"
}

@test "verify-tap.sh: reports every failing file and fails if any one fails" {
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

@test "verify-tap.sh: exits 2 on a usage error or an unreadable file, judging nothing" {
  write_out bad '1..1
not ok 1'

  run "$SCRIPT" "$OUTDIR/bad.out" "$OUTDIR/missing.out"
  assert_failure_with_status 2
  assert_contains "$output" "cannot read '$OUTDIR/missing.out'"
  assert_not_contains "$output" "pgtap failure"

  run "$SCRIPT" "$OUTDIR"
  assert_failure_with_status 2

  run "$SCRIPT" --bogus "$OUTDIR/bad.out"
  assert_failure_with_status 2
  assert_contains "$output" "Usage:"

  run "$SCRIPT" --help
  assert_success
  assert_contains "$output" "Usage:"
}

# vi: expandtab ts=2 sw=2
