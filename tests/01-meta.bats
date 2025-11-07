#!/usr/bin/env bats

# Test: META.json generation
#
# Tests that META.in.json → META.json generation works correctly

load helpers

setup_file() {
  debug 1 ">>> ENTER setup_file: 01-meta (PID=$$)"

  # Set TOPDIR first
  cd "$BATS_TEST_DIRNAME/.."
  export TOPDIR=$(pwd)

  # First sequential test - ensure foundation exists first
  load_test_env "sequential"
  ensure_foundation "$TEST_DIR"

  # Now set up as sequential test (no prereq, we're first)
  setup_sequential_test "01-meta"

  export DISTRIBUTION_NAME="distribution_test"
  export EXTENSION_NAME="pgxntool-test"
  debug 1 "<<< EXIT setup_file: 01-meta (PID=$$)"
}

setup() {
  load_test_env "sequential"
  cd "$TEST_REPO"
}

teardown_file() {
  debug 1 ">>> ENTER teardown_file: 01-meta (PID=$$)"
  mark_test_complete "01-meta"
  debug 1 "<<< EXIT teardown_file: 01-meta (PID=$$)"
}

@test "META.in.json exists" {
  assert_file_exists "META.in.json"
}

@test "can modify META.in.json" {
  # Check if already modified
  if grep -q "$DISTRIBUTION_NAME" META.in.json; then
    skip "META.in.json already modified"
  fi

  # Sleep to ensure timestamp changes
  sleep 1

  # Modify META.in.json
  sed -i '' -e "s/DISTRIBUTION_NAME/$DISTRIBUTION_NAME/" -e "s/EXTENSION_NAME/$EXTENSION_NAME/" META.in.json

  # Verify changes
  grep -q "$DISTRIBUTION_NAME" META.in.json
  grep -q "$EXTENSION_NAME" META.in.json
}

@test "make regenerates META.json from META.in.json" {
  # Save original META.json timestamp
  local before=$(stat -f %m META.json 2>/dev/null || echo "0")

  # Run make (should regenerate META.json)
  run make
  [ "$status" -eq 0 ]

  # META.json should exist
  assert_file_exists "META.json"
}

@test "META.json contains changes from META.in.json" {
  # Verify that our changes made it through
  grep -q "$DISTRIBUTION_NAME" META.json
  grep -q "$EXTENSION_NAME" META.json
}

@test "META.json is valid JSON" {
  # Try to parse it with a simple check
  run python3 -m json.tool META.json
  [ "$status" -eq 0 ]
}

@test "changes can be committed" {
  # Skip if already committed (check for modified/staged files, not untracked)
  local changes=$(git status --porcelain | grep -v '^??')
  if [ -z "$changes" ]; then
    skip "No changes to commit"
  fi

  # Commit
  run git commit -am "Change META"
  [ "$status" -eq 0 ]

  # Verify no tracked changes remain (ignore untracked files)
  local remaining=$(git status --porcelain | grep -v '^??')
  [ -z "$remaining" ]
}

# vi: expandtab sw=2 ts=2
