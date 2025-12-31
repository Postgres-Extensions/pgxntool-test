#!/usr/bin/env bats

# Test: META.json generation
#
# This is the first sequential test that actually uses the test environment (TEST_REPO).
# Test 00-validate-tests is technically first but only validates test file structure
# (see comments in 00-validate-tests.bats for why it's sequential but doesn't use the environment).
#
# Since this is the first test to use TEST_REPO, it's responsible for copying the
# foundation environment (.envs/foundation/repo) to the sequential environment
# (.envs/sequential/repo). All later sequential tests (02-dist, 03-setup-final)
# build on this copied TEST_REPO.
#
# Tests that META.in.json → META.json generation works correctly.
# Foundation already replaced placeholders, so we test the regeneration
# mechanism by modifying a different field and verifying META.json updates.

load helpers

setup_file() {
  debug 1 ">>> ENTER setup_file: 01-meta (PID=$$)"

  # Set TOPDIR first
  cd "$BATS_TEST_DIRNAME/.."
  export TOPDIR=$(pwd)

  # Set up as sequential test with foundation prerequisite
  # setup_sequential_test handles pollution detection and runs foundation if needed
  setup_sequential_test "01-meta" "foundation"

  # CRITICAL: Copy foundation repo to sequential environment
  # This is the ONLY sequential test that should do this, because it's the first
  # one to actually use TEST_REPO. Later sequential tests (02-dist, etc.) depend
  # on 01-meta, not foundation directly, so they reuse this copied repo.
  #
  # Why ensure_foundation and not just copy?
  # - Handles case where foundation already ran but sequential/repo doesn't exist
  # - Checks foundation age and warns if stale (important when testing pgxntool changes)
  # - Creates foundation if it doesn't exist
  ensure_foundation "$TEST_DIR"

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
  # Check if we've already modified the version field
  if grep -q '"version": "0.1.1"' META.in.json; then
    skip "META.in.json already modified"
  fi

  # Sleep to ensure timestamp changes
  sleep 1

  # Modify a field to test regeneration (change version from 0.1.0 to 0.1.1)
  #
  # WARNING: In a real extension, bumping the version without creating an upgrade script
  # (extension--0.1.0--0.1.1.sql) would be bad practice. PostgreSQL extensions need upgrade
  # scripts to migrate data/schema between versions. For testing purposes this is fine since
  # we're only validating META.json regeneration, not actual extension upgrade behavior.
  #
  # TODO: pgxntool should arguably check for missing upgrade scripts when version changes
  # and warn/error, but currently it doesn't perform this validation.
  #
  # Note: sed -i.bak + rm is the simplest portable solution (works on macOS BSD sed and GNU sed)
  # BSD sed requires an extension argument (can't do just -i), GNU sed allows it
  sed -i.bak 's/"version": "0.1.0"/"version": "0.1.1"/' META.in.json
  rm -f META.in.json.bak

  # Verify change
  grep -q '"version": "0.1.1"' META.in.json
}

@test "make regenerates META.json from META.in.json" {
  # Run make (should regenerate META.json because META.in.json changed)
  run make
  assert_success

  # META.json should exist
  assert_file_exists "META.json"
}

@test "META.json contains changes from META.in.json" {
  # Verify that our version change made it through to META.json
  grep -q '"version": "0.1.1"' META.json
}

@test "META.json is valid JSON" {
  # Try to parse it with a simple check
  run python3 -m json.tool META.json
  assert_success
}

@test "changes can be committed" {
  # Skip if already committed (check for modified/staged files, not untracked)
  local changes=$(git status --porcelain | grep -v '^??')
  if [ -z "$changes" ]; then
    skip "No changes to commit"
  fi

  # Commit
  run git commit -am "Change META"
  assert_success

  # Verify no tracked changes remain (ignore untracked files)
  local remaining=$(git status --porcelain | grep -v '^??')
  [ -z "$remaining" ]
}

# vi: expandtab sw=2 ts=2
