#!/usr/bin/env bats

# Test: pgxntool-version
#
# Tests bin/version's HISTORY.asc parsing in isolation (a stamped
# version, an unreleased "STABLE" checkout, a missing file, an empty file,
# malformed first lines), that `make pgxntool-version` is correctly wired to
# it inside a real embedded pgxntool copy, and (CRITICAL -- see comment
# below) that it matches the actual, unmodified pgxntool checkout this test
# suite is running against.

load ../lib/helpers

setup_file() {
  setup_topdir

  # Independent test - gets its own isolated environment with foundation TEST_REPO
  load_test_env "pgxntool-version"
  ensure_foundation "$TEST_DIR"

  export VERSION_SCRIPT="$PGXNREPO/bin/version"
  export SCRATCH_DIR="$TEST_DIR/pgxntool-version-tests"
}

setup() {
  load_test_env "pgxntool-version"

  rm -rf "$SCRATCH_DIR"
  mkdir -p "$SCRATCH_DIR"
}

@test "bin/version prints a stamped version number" {
  echo "2.1.0" > "$SCRATCH_DIR/HISTORY.asc"

  run "$VERSION_SCRIPT" "$SCRATCH_DIR/HISTORY.asc"
  assert_success
  [ "$output" = "2.1.0" ]
}

@test "bin/version prints STABLE for an unreleased checkout" {
  printf 'STABLE\n------\n' > "$SCRATCH_DIR/HISTORY.asc"

  run "$VERSION_SCRIPT" "$SCRATCH_DIR/HISTORY.asc"
  assert_success
  [ "$output" = "STABLE" ]
}

@test "bin/version errors on a missing HISTORY.asc" {
  run "$VERSION_SCRIPT" "$SCRATCH_DIR/does-not-exist.asc"
  assert_failure
  assert_contains "$output" "not found"
}

@test "bin/version errors on an empty HISTORY.asc" {
  : > "$SCRATCH_DIR/HISTORY.asc"

  run "$VERSION_SCRIPT" "$SCRATCH_DIR/HISTORY.asc"
  assert_failure
  assert_contains "$output" "empty"
}

@test "bin/version rejects a malformed first line" {
  for bad in "stable" "v2.1.0" "2.1.0-beta" "2.1" "not a version"; do
    echo "$bad" > "$SCRATCH_DIR/HISTORY.asc"

    run "$VERSION_SCRIPT" "$SCRATCH_DIR/HISTORY.asc"
    assert_failure
    assert_contains "$output" "neither STABLE nor a X.Y.Z version"
  done
}

# CRITICAL: this test must run bin/version directly against the real,
# unmodified $PGXNREPO checkout -- never a scratch file, an rsync'd copy, or
# a cached foundation snapshot. A release PR stamps HISTORY.asc with the
# real version and relies on CI running this exact check to catch a bad
# stamp before it's tagged and pushed -- that guarantee only holds if the
# check reads the literal, current pgxntool/HISTORY.asc. This matters most
# precisely when the top line is NOT "STABLE": that's the release commit
# itself, and a copy-based or stale check could pass against old content and
# let a wrong version ship. Do not weaken this to a scratch-file test or to a
# non-empty check.
@test "bin/version matches the current pgxntool/HISTORY.asc with no modifications" {
  local expected
  expected=$(head -n1 "$PGXNREPO/HISTORY.asc")

  run "$VERSION_SCRIPT"
  assert_success
  [ "$output" = "$expected" ]
}

@test "make pgxntool-version matches the embedded pgxntool/HISTORY.asc" {
  cd "$TEST_REPO"

  local expected
  expected=$(head -n1 pgxntool/HISTORY.asc)

  # --no-print-directory: our own test suite runs under `make test-all`, which
  # propagates MAKEFLAGS/MAKELEVEL to this nested `make` call and would
  # otherwise wrap the output in "make[1]: Entering/Leaving directory" banners.
  run make --no-print-directory pgxntool-version
  assert_success
  [ "$output" = "$expected" ]
}

# vi: expandtab sw=2 ts=2
