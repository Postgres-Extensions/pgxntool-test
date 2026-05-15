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

# vi: expandtab sw=2 ts=2
