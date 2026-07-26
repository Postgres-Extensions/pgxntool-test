#!/usr/bin/env bats

# Test: Parallel-build safety of versioned SQL file generation (issue #19)
#
# The rule that generates sql/<ext>--<version>.sql used to be two recipe
# lines:
#   @echo '/* DO NOT EDIT - AUTO-GENERATED FILE */' > $(FILE)
#   @cat sql/<ext>.sql >> $(FILE)
# Each recipe line is its own forked shell. If the SAME target gets rebuilt
# by two independent `make` processes running concurrently (e.g. two CI jobs
# sharing a checkout, or a developer running one make command while another
# is still in flight), the two processes' lines can interleave so that both
# truncate (line 1) before either appends (line 2) -- doubling the file's
# content. This was observed in practice: a 264-line file was found at 527
# lines.
#
# The fix collapses the recipe to a single atomic `(...) > $(FILE)` redirect,
# so each firing writes the complete, correct content regardless of how many
# times, or how many concurrent processes, rebuild the target.
#
# This was confirmed by hand against a scratch repo before writing this test:
# racing two concurrent `make all` invocations against the old two-line
# recipe reproduced doubled output (e.g. 31 lines instead of 16) in roughly
# a third of trials; the fixed single-redirect recipe never doubled across
# 15+ trials. The loop below repeats the race to keep that same odds of
# catching a regression.

load ../lib/helpers

setup_file() {
  setup_topdir

  load_test_env "versioned-sql-race"
  ensure_foundation "$TEST_DIR"
}

setup() {
  load_test_env "versioned-sql-race"
  cd_test_env
}

@test "versioned SQL file has correct (non-doubled) content after a normal build" {
  rm -f sql/pgxntool-test--0.1.1.sql

  run make all
  assert_success

  local expected_lines
  expected_lines=$(( $(wc -l < sql/pgxntool-test.sql) + 1 ))
  local actual_lines
  actual_lines=$(wc -l < sql/pgxntool-test--0.1.1.sql)

  [ "$actual_lines" -eq "$expected_lines" ] || error "Expected $expected_lines lines, got $actual_lines"
}

@test "concurrent make invocations do not double the versioned SQL file" {
  local expected_lines
  expected_lines=$(( $(wc -l < sql/pgxntool-test.sql) + 1 ))

  local i
  for i in 1 2 3 4 5; do
    rm -f sql/pgxntool-test--0.1.1.sql

    # Race two independent `make` processes against the same target, as
    # concurrent-make-test.bats does for cross-project races. Close FD 3 so
    # BATS doesn't hang on the background children.
    ( make all >/dev/null 2>&1 ) 3>&- &
    local pid1=$!
    ( make all >/dev/null 2>&1 ) 3>&- &
    local pid2=$!

    wait $pid1
    wait $pid2

    [ -f sql/pgxntool-test--0.1.1.sql ] || error "Iteration $i: versioned SQL file missing after concurrent make"

    local actual_lines
    actual_lines=$(wc -l < sql/pgxntool-test--0.1.1.sql)
    [ "$actual_lines" -eq "$expected_lines" ] || \
      error "Iteration $i: expected $expected_lines lines, got $actual_lines (doubled content would indicate issue #19 regressed)"
  done
}

# vi: expandtab sw=2 ts=2
