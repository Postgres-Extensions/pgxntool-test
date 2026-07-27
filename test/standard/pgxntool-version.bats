#!/usr/bin/env bats

# Test: pgxntool-version
#
# Tests pgxntool-version.sh's HISTORY.asc parsing in isolation (a stamped
# version, an unreleased "STABLE" checkout, a missing file, an empty file,
# malformed first lines), plus that `make pgxntool-version` is correctly
# wired to it inside a real embedded pgxntool copy.

load ../lib/helpers

setup_file() {
  setup_topdir

  # Independent test - gets its own isolated environment with foundation TEST_REPO
  load_test_env "pgxntool-version"
  ensure_foundation "$TEST_DIR"

  export VERSION_SCRIPT="$TOPDIR/../pgxntool/pgxntool-version.sh"
  export SCRATCH_DIR="$TEST_DIR/pgxntool-version-tests"
}

setup() {
  load_test_env "pgxntool-version"

  rm -rf "$SCRATCH_DIR"
  mkdir -p "$SCRATCH_DIR"
}

@test "pgxntool-version.sh prints a stamped version number" {
  echo "2.1.0" > "$SCRATCH_DIR/HISTORY.asc"

  run "$VERSION_SCRIPT" "$SCRATCH_DIR/HISTORY.asc"
  assert_success
  [ "$output" = "2.1.0" ]
}

@test "pgxntool-version.sh prints STABLE for an unreleased checkout" {
  printf 'STABLE\n------\n' > "$SCRATCH_DIR/HISTORY.asc"

  run "$VERSION_SCRIPT" "$SCRATCH_DIR/HISTORY.asc"
  assert_success
  [ "$output" = "STABLE" ]
}

@test "pgxntool-version.sh errors on a missing HISTORY.asc" {
  run "$VERSION_SCRIPT" "$SCRATCH_DIR/does-not-exist.asc"
  assert_failure
  assert_contains "$output" "not found"
}

@test "pgxntool-version.sh errors on an empty HISTORY.asc" {
  : > "$SCRATCH_DIR/HISTORY.asc"

  run "$VERSION_SCRIPT" "$SCRATCH_DIR/HISTORY.asc"
  assert_failure
  assert_contains "$output" "empty"
}

@test "pgxntool-version.sh rejects a malformed first line" {
  for bad in "stable" "v2.1.0" "2.1.0-beta" "2.1" "not a version"; do
    echo "$bad" > "$SCRATCH_DIR/HISTORY.asc"

    run "$VERSION_SCRIPT" "$SCRATCH_DIR/HISTORY.asc"
    assert_failure
    assert_contains "$output" "neither STABLE nor a X.Y.Z version"
  done
}

@test "pgxntool-version.sh defaults to its own directory's HISTORY.asc" {
  run "$VERSION_SCRIPT"
  assert_success
  [ -n "$output" ]
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
