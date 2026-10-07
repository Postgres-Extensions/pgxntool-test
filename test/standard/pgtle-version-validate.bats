#!/usr/bin/env bats

# Test: pgtle.sh --pgtle-version validation - pure script-logic unit tests
#
# Invokes pgxntool's pgtle.sh directly against a bare scratch directory -- no
# foundation environment, no `make`, no PostgreSQL. `make pgtle` only forwards
# PGXNTOOL_PGTLE_VERSION to --pgtle-version (covered in 04-pgtle.bats), so the
# validation itself is tested here once.

load ../lib/helpers
load ../lib/assertions

setup_file() {
  setup_topdir
  load_test_env "pgtle-version-validate"
}

setup() {
  load_test_env "pgtle-version-validate"
  export SCRIPT="$PGXNREPO/pgtle.sh"

  # Minimal extension so an accepted range can actually generate output.
  export TESTDIR="$BATS_TEST_TMPDIR/testdir"
  mkdir -p "$TESTDIR/sql"
  echo "default_version = '1.0'" > "$TESTDIR/vext.control"
  echo "SELECT 1;" > "$TESTDIR/sql/vext--1.0.sql"
  cd "$TESTDIR"
}

@test "pgtle.sh --pgtle-version: accepts each exact range name and generates only that range" {
  local range
  for range in 1.0.0-1.4.0 1.4.0-1.5.0 1.5.0+; do
    rm -rf pg_tle
    run "$SCRIPT" --extension vext --pgtle-version "$range"
    assert_success
    [ -f "pg_tle/$range/vext.sql" ]
    [ "$(ls pg_tle)" = "$range" ]
  done
}

@test "pgtle.sh --pgtle-version: plain version is rejected with a did-you-mean hint" {
  local pair version expected
  # Pairs of "plain version:range it falls in", including both boundaries and
  # a pre-release just below one.
  for pair in 1.0.0:1.0.0-1.4.0 1.3.9:1.0.0-1.4.0 1.4.0:1.4.0-1.5.0 \
              1.5.0rc1:1.4.0-1.5.0 1.5.0:1.5.0+ 1.5.2:1.5.0+; do
    version=${pair%%:*}
    expected=${pair#*:}
    run "$SCRIPT" --extension vext --pgtle-version "$version"
    assert_failure_with_status 1
    assert_contains "$output" "invalid pg_tle version range: '$version'"
    assert_contains "$output" "Valid ranges: 1.0.0-1.4.0 1.4.0-1.5.0 1.5.0+"
    assert_contains "$output" "did you mean $expected?"
    [ ! -e pg_tle ]
  done
}

@test "pgtle.sh --pgtle-version: unparseable value is rejected without a hint" {
  local value
  for value in latest "" 1.5.1000; do
    run "$SCRIPT" --extension vext --pgtle-version "$value"
    assert_failure_with_status 1
    assert_contains "$output" "invalid pg_tle version range: '$value'"
    assert_contains "$output" "Valid ranges: 1.0.0-1.4.0 1.4.0-1.5.0 1.5.0+"
    assert_not_contains "$output" "did you mean"
    [ ! -e pg_tle ]
  done
}
