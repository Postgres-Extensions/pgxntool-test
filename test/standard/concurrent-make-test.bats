#!/usr/bin/env bats

# Test: Concurrent make test runs
#
# Verifies that two different projects can run `make test` simultaneously
# without database name collisions. This validates that REGRESS_DBNAME
# (unique per-directory database name) works correctly via CONTRIB_TESTDB,
# and that there is only one --dbname flag passed to pg_regress.

load ../lib/helpers

REPO1_ENV="concurrent-single"
REPO2_ENV="concurrent-multi"

setup_file() {
  setup_topdir

  # Build first environment from single-extension template
  local env1_dir="$TOPDIR/test/.envs/$REPO1_ENV"
  if [ -d "$env1_dir" ]; then
    clean_env "$REPO1_ENV" || return 1
  fi
  load_test_env "$REPO1_ENV" || return 1
  mkdir -p "$TEST_DIR/.bats-state"
  build_test_repo_from_template "${TOPDIR}/template" || return 1

  # Build second environment from multi-extension template
  local env2_dir="$TOPDIR/test/.envs/$REPO2_ENV"
  if [ -d "$env2_dir" ]; then
    clean_env "$REPO2_ENV" || return 1
  fi
  load_test_env "$REPO2_ENV" || return 1
  mkdir -p "$TEST_DIR/.bats-state"
  build_test_repo_from_template "${TOPDIR}/template-multi-extension" || return 1
}

_repo_path() {
  echo "$TOPDIR/test/.envs/$1/repo"
}

setup() {
  setup_topdir
}

@test "repos have different REGRESS_DBNAME values" {
  local repo1 repo2
  repo1=$(_repo_path "$REPO1_ENV")
  repo2=$(_repo_path "$REPO2_ENV")

  local dbname1 dbname2
  dbname1=$(make -C "$repo1" print-REGRESS_DBNAME 2>&1 | sed -n 's/.*set to "\(.*\)"/\1/p')
  dbname2=$(make -C "$repo2" print-REGRESS_DBNAME 2>&1 | sed -n 's/.*set to "\(.*\)"/\1/p')

  [ -n "$dbname1" ] || error "Could not extract REGRESS_DBNAME from repo1"
  [ -n "$dbname2" ] || error "Could not extract REGRESS_DBNAME from repo2"

  out "repo1 REGRESS_DBNAME: $dbname1"
  out "repo2 REGRESS_DBNAME: $dbname2"

  [ "$dbname1" != "$dbname2" ] || error "Both repos have the same REGRESS_DBNAME: $dbname1"
}

@test "single-extension repo has exactly one --dbname flag" {
  local repo
  repo=$(_repo_path "$REPO1_ENV")

  local count
  count=$(make -C "$repo" -n test 2>&1 | grep pg_regress | grep -o -- '--dbname' | wc -l)
  count=$(echo "$count" | tr -d ' ')

  out "single-extension --dbname count: $count"
  [ "$count" -eq 1 ] || error "Expected exactly 1 --dbname flag, got $count"
}

@test "multi-extension repo has exactly one --dbname flag" {
  local repo
  repo=$(_repo_path "$REPO2_ENV")

  local count
  count=$(make -C "$repo" -n test 2>&1 | grep pg_regress | grep -o -- '--dbname' | wc -l)
  count=$(echo "$count" | tr -d ' ')

  out "multi-extension --dbname count: $count"
  [ "$count" -eq 1 ] || error "Expected exactly 1 --dbname flag, got $count"
}

@test "concurrent make test succeeds for both projects" {
  skip_if_no_postgres

  local repo1 repo2
  repo1=$(_repo_path "$REPO1_ENV")
  repo2=$(_repo_path "$REPO2_ENV")

  local log1 log2
  log1=$(mktemp)
  log2=$(mktemp)

  # Run both make test invocations in parallel
  # Close FD 3 to prevent BATS from hanging on child processes
  (cd "$repo1" && make test > "$log1" 2>&1) 3>&- &
  local pid1=$!

  (cd "$repo2" && make test > "$log2" 2>&1) 3>&- &
  local pid2=$!

  local status1=0 status2=0
  wait $pid1 || status1=$?
  wait $pid2 || status2=$?

  if [ $status1 -ne 0 ]; then
    out "single-extension make test FAILED (exit $status1):"
    out "$(cat "$log1")"
  fi
  if [ $status2 -ne 0 ]; then
    out "multi-extension make test FAILED (exit $status2):"
    out "$(cat "$log2")"
  fi

  rm -f "$log1" "$log2"

  [ $status1 -eq 0 ] || error "single-extension make test failed"
  [ $status2 -eq 0 ] || error "multi-extension make test failed"
}

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
#
# Uses the single-extension repo (REPO1_ENV) built above -- the race is about
# a single repo's own concurrent `make` invocations, not the cross-project
# scenario the rest of this file tests.

@test "versioned SQL file has correct (non-doubled) content after a normal build" {
  local repo
  repo=$(_repo_path "$REPO1_ENV")
  cd "$repo"

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
  local repo
  repo=$(_repo_path "$REPO1_ENV")
  cd "$repo"

  local expected_lines
  expected_lines=$(( $(wc -l < sql/pgxntool-test.sql) + 1 ))

  local i
  for i in 1 2 3 4 5; do
    rm -f sql/pgxntool-test--0.1.1.sql

    # Race two independent `make` processes against the same target, as
    # the cross-project race above does. Close FD 3 so BATS doesn't hang
    # on the background children.
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
