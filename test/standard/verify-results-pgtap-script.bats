#!/usr/bin/env bats

# Test: verify-results-pgtap.sh - pure script-logic unit tests
#
# These tests exercise pgxntool's verify-results-pgtap.sh directly against a
# bare scratch directory -- no foundation environment, no `make`, no
# PostgreSQL. They own all of the script's decision logic: which pgtap output
# in results/*.out counts as a failure, and which regression.diffs entries
# block `make results` (a real mismatch against an existing baseline) versus
# which are a brand-new test that has no expected output yet (issue #119).
#
# Tests that need real Make/PostgreSQL integration stay in make-test.bats:
# that `make verify-results` invokes this script and propagates its exit
# status, and that a real pg_regress run against base.mk's empty
# expected-file placeholder actually produces the "@@ -0,0" diff shape the
# classification below keys on.

load ../lib/helpers
load ../lib/assertions

setup_file() {
  setup_topdir
  load_test_env "verify-results-pgtap-script"
}

setup() {
  load_test_env "verify-results-pgtap-script"
  export SCRIPT="$PGXNREPO/verify-results-pgtap.sh"

  # Fresh, empty scratch directory per test -- no foundation/TEST_REPO needed.
  export TESTOUT="$BATS_TEST_TMPDIR/testout"
  mkdir -p "$TESTOUT/results"
}

# Record $2 as test $1's pg_regress output file.
write_results() {
  printf '%s\n' "$2" > "$TESTOUT/results/$1.out"
}

# Append the regression.diffs block pg_regress would write for test $1: the
# "diff <opts> <expected> <results>" header, the ---/+++ file lines, then $2
# as the diff body (hunk headers included).
append_diff_block() {
  local name=$1 body=$2
  {
    printf 'diff -U3 %s %s\n' "$TESTOUT/expected/$name.out" "$TESTOUT/results/$name.out"
    printf -- '--- %s\t2026-01-01 00:00:00.000000000 +0000\n' "$TESTOUT/expected/$name.out"
    printf -- '+++ %s\t2026-01-01 00:00:00.000000000 +0000\n' "$TESTOUT/results/$name.out"
    printf '%s\n' "$body"
  } >> "$TESTOUT/regression.diffs"
}

@test "verify-results-pgtap.sh: passes on all-ok output with no regression.diffs" {
  write_results passing '1..1
ok 1'

  run "$SCRIPT" "$TESTOUT"
  assert_success
}

@test "verify-results-pgtap.sh: allows a brand-new test that has no expected output yet (issue #119)" {
  # base.mk touches an empty test/expected/<name>.out for a test that lacks
  # one, so pg_regress always reports a difference against it: a single
  # "@@ -0,0" hunk. That is unwinnable to block on -- creating that first
  # expected file is what `make results` is for.
  write_results newtest '1..1
ok 1'
  append_diff_block newtest '@@ -0,0 +1,2 @@
+1..1
+ok 1'

  run "$SCRIPT" "$TESTOUT"
  assert_success
  assert_contains "$output" "no expected output yet"
  assert_contains "$output" "newtest.out"
}

@test "verify-results-pgtap.sh: still blocks a real mismatch against an existing baseline" {
  write_results oldtest '1..1
ok 1'
  append_diff_block oldtest '@@ -1,2 +1,2 @@
 1..1
-ok 1 - renamed
+ok 1'

  run "$SCRIPT" "$TESTOUT"
  assert_failure_with_status 1
  assert_contains "$output" "Tests are failing"
  assert_contains "$output" "Cannot run 'make results'"
  assert_contains "$output" "oldtest.out"
}

@test "verify-results-pgtap.sh: a real mismatch still blocks alongside a brand-new test" {
  write_results newtest '1..1
ok 1'
  append_diff_block newtest '@@ -0,0 +1,2 @@
+1..1
+ok 1'
  write_results oldtest '1..1
ok 1'
  append_diff_block oldtest '@@ -1,2 +1,2 @@
 1..1
-ok 1 - renamed
+ok 1'

  run "$SCRIPT" "$TESTOUT"
  assert_failure_with_status 1
  assert_contains "$output" "Tests are failing"
  assert_contains "$output" "oldtest.out"
}

@test "verify-results-pgtap.sh: refuses to bless a brand-new test whose output holds a SQL error" {
  # ON_ERROR_STOP aborts the script at the error, so pgtap emits neither
  # 'not ok' nor its plan-mismatch line and the scan above finds nothing.
  #
  # Both of psql's real renderings have to block. pg_regress feeds psql on
  # stdin, so an error in the test file itself starts at column 0, while one
  # inside an \i'd file (setup.sql/finish.sql, which every pgxntool test
  # sources) carries a "psql:<file>:<line>: " prefix -- a column-anchored
  # match would sail straight past the second.
  write_results errtest '1..2
ok 1
ERROR:  42P01: relation "nope" does not exist'
  append_diff_block errtest '@@ -0,0 +1,3 @@
+1..2
+ok 1
+ERROR:  42P01: relation "nope" does not exist'

  run "$SCRIPT" "$TESTOUT"
  assert_failure_with_status 1
  assert_contains "$output" "errtest.out"

  rm -f "$TESTOUT/regression.diffs"
  write_results errtest '1..2
ok 1
psql:test/pgxntool/setup.sql:3: ERROR:  42P01: relation "nope" does not exist'
  append_diff_block errtest '@@ -0,0 +1,3 @@
+1..2
+ok 1
+psql:test/pgxntool/setup.sql:3: ERROR:  42P01: relation "nope" does not exist'

  run "$SCRIPT" "$TESTOUT"
  assert_failure_with_status 1
  assert_contains "$output" "errtest.out"
}

@test "verify-results-pgtap.sh: blesses a passing test whose description merely mentions ERROR:" {
  # psql writes two spaces after the severity; a pgtap description quoting an
  # error message does not, and isn't at the start of a line or after ": ".
  # Without that distinction a legitimately-passing new test could never have
  # its first expected output created.
  write_results described '1..1
ok 1 - raises ERROR: division by zero'
  append_diff_block described '@@ -0,0 +1,2 @@
+1..1
+ok 1 - raises ERROR: division by zero'

  run "$SCRIPT" "$TESTOUT"
  assert_success
  assert_contains "$output" "no expected output yet"
  assert_contains "$output" "described.out"
}

@test "verify-results-pgtap.sh: classifies by unprefixed headers, not by diffed content" {
  # Every content line in a diff carries a ' ', '+' or '-' prefix, so output
  # that itself contains block or hunk headers must not be mistaken for one.
  write_results tricky '1..1
ok 1'
  append_diff_block tricky '@@ -0,0 +1,4 @@
+diff -U3 a.out b.out
+@@ -1,2 +1,2 @@
+1..1
+ok 1'

  run "$SCRIPT" "$TESTOUT"
  assert_success
  assert_contains "$output" "no expected output yet"
}

@test "verify-results-pgtap.sh: a deleted '-- comment' line doesn't read as a file header" {
  # A removed "-- comment" renders as "--- comment", which is why the
  # classification keys on "diff "/"@@ " lines rather than the ---/+++ pair.
  write_results commented '1..1
ok 1'
  append_diff_block commented '@@ -1,3 +1,2 @@
 1..1
--- vi: expandtab ts=2 sw=2
+ok 1'

  run "$SCRIPT" "$TESTOUT"
  assert_failure_with_status 1
  assert_contains "$output" "commented.out"
}

@test "verify-results-pgtap.sh: blocks when regression.diffs exists but is empty" {
  # pg_regress truncates the file at startup and removes it again on a clean
  # finish, so an empty one means it died before comparing anything -- and
  # base.mk's `.IGNORE: installcheck` lets `make results` reach here anyway.
  # results/ then holds whatever an earlier run left, so passing this would
  # bless stale output.
  write_results stale '1..1
ok 1'
  : > "$TESTOUT/regression.diffs"

  run "$SCRIPT" "$TESTOUT"
  assert_failure_with_status 1
  assert_contains "$output" "pg_regress did not complete"
}

@test "verify-results-pgtap.sh: blocks a block whose hunks aren't all '@@ -0,0'" {
  # Two fail-closed shapes that aren't a clean no-baseline block: a header
  # with no hunks at all (what a pre-12 context diff looks like here), and a
  # block that only partly diffed against an empty file.
  write_results nohunk '1..1
ok 1'
  append_diff_block nohunk ''

  run "$SCRIPT" "$TESTOUT"
  assert_failure_with_status 1
  assert_contains "$output" "nohunk.out"

  rm -f "$TESTOUT/regression.diffs"
  write_results mixed '1..1
ok 1'
  append_diff_block mixed '@@ -0,0 +1,1 @@
+1..1
@@ -3,1 +4,1 @@
-was here
+ok 1'

  run "$SCRIPT" "$TESTOUT"
  assert_failure_with_status 1
  assert_contains "$output" "mixed.out"
}

@test "verify-results-pgtap.sh: blocks when unrecognized content follows a valid block" {
  # The whole file has to fail closed, not just refuse to classify: a block
  # that reads as blessable is no reason to ignore text after it that fits no
  # part of the diff format.
  write_results newtest '1..1
ok 1'
  append_diff_block newtest '@@ -0,0 +1,2 @@
+1..1
+ok 1'
  printf 'diff: /nonexistent: No such file or directory\n' >> "$TESTOUT/regression.diffs"

  run "$SCRIPT" "$TESTOUT"
  assert_failure_with_status 1
  assert_contains "$output" "unrecognized content"

  # ...but diff's own no-newline marker is part of the format, not junk.
  # Treating it as junk would block a legitimate first bless of any test
  # whose output doesn't end in a newline.
  rm -f "$TESTOUT/regression.diffs"
  append_diff_block newtest '@@ -0,0 +1,2 @@
+1..1
+ok 1
\ No newline at end of file'

  run "$SCRIPT" "$TESTOUT"
  assert_success
  assert_contains "$output" "no expected output yet"
}

@test "verify-results-pgtap.sh: blocks on regression.diffs content it cannot classify" {
  write_results passing '1..1
ok 1'
  printf 'truncated junk with no diff header\n' > "$TESTOUT/regression.diffs"

  run "$SCRIPT" "$TESTOUT"
  assert_failure_with_status 1
  assert_contains "$output" "unrecognized"

  # Diff body lines with no header before them yield no classification at
  # all rather than an unrecognized one, which has to block just the same.
  printf ' 1..1\n+ok 1\n' > "$TESTOUT/regression.diffs"

  run "$SCRIPT" "$TESTOUT"
  assert_failure_with_status 1
  assert_contains "$output" "unrecognized"
}

@test "verify-results-pgtap.sh: detects a pgtap failure" {
  write_results failing '1..2
ok 1
not ok 2 - broken'

  run "$SCRIPT" "$TESTOUT"
  assert_failure_with_status 1
  assert_contains "$output" "pgtap failure detected"
  assert_contains "$output" "not ok 2 - broken"
}

@test "verify-results-pgtap.sh: ignores a TODO failure" {
  write_results todo '1..1
not ok 1 - known issue # TODO fix later'

  run "$SCRIPT" "$TESTOUT"
  assert_success
}

@test "verify-results-pgtap.sh: detects a pgtap plan mismatch" {
  write_results planned '1..3
ok 1
ok 2
# Looks like you planned 3 tests but ran 2'

  run "$SCRIPT" "$TESTOUT"
  assert_failure_with_status 1
  assert_contains "$output" "pgtap plan mismatch"
}

@test "verify-results-pgtap.sh: usage error when called with no TESTOUT argument" {
  run "$SCRIPT"
  assert_failure
  assert_contains "$output" "Usage:"
}

# vi: expandtab ts=2 sw=2
