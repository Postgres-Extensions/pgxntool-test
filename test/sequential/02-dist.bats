#!/usr/bin/env bats

# Test: Distribution after META Generation
#
# This test validates that 'make dist' works correctly after other operations
# have been performed (specifically, after META.json generation in 01-meta).
#
# This tests a different scenario than test-dist-clean.bats:
# - test-dist-clean: Tests dist from completely clean foundation
# - 02-dist (this file): Tests dist after META.json has been generated
#
# Both should produce identical distribution contents, demonstrating that
# 'make dist' has correct dependencies regardless of prior operations.
#
# Key validations:
# - make dist succeeds after prior operations
# - make dist FAILS if there are untracked files (enforces clean repo)
# - Distribution includes correct files
# - Distribution excludes incorrect files (pgxntool docs, etc.)
#
# Note: In a real extension project, some files that are currently in t/
# would be at the root and tracked in git. This test verifies that pgxntool's
# distribution logic works correctly whether files are tracked or not.

load ../lib/helpers
load ../lib/dist-files

setup_file() {
  debug 1 ">>> ENTER setup_file: 02-dist (PID=$$)"
  setup_sequential_test "02-dist" "01-meta"

  # Extract distribution name and version dynamically from META.json
  #
  # WHY DYNAMIC: The 01-meta test modifies META.json, changing values (including
  # version for testing regeneration). We must read the actual values, not hardcode them.
  #
  # This extraction must happen AFTER setup_sequential_test() ensures 01-meta
  # has completed, otherwise META.json may not exist or have wrong values.
  export DISTRIBUTION_NAME=$(grep '"name"' "$TEST_REPO/META.json" | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
  export VERSION=$(grep '"version"' "$TEST_REPO/META.json" | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
  export DIST_FILE="$TEST_DIR/${DISTRIBUTION_NAME}-${VERSION}.zip"
  debug 1 "<<< EXIT setup_file: 02-dist (PID=$$)"
}

setup() {
  load_test_env "sequential"
  cd "$TEST_REPO"
}

teardown_file() {
  debug 1 ">>> ENTER teardown_file: 02-dist (PID=$$)"
  mark_test_complete "02-dist"
  debug 1 "<<< EXIT teardown_file: 02-dist (PID=$$)"
}

@test "make (default build target) succeeds" {
  # Run default build target before dist to ensure it doesn't break make dist.
  # This simulates a common development workflow: build, then create distribution.
  run make
  [ "$status" -eq 0 ]
}

@test "make distclean removes generated files" {
  # Verify that distclean properly removes generated build artifacts
  # so we can test that make rebuilds them correctly
  run make distclean
  assert_success

  # Generated files should be removed
  [ ! -f "META.json" ]
  [ ! -f "meta.mk" ]
  [ ! -f "control.mk" ]
}

@test "make after distclean generates versioned SQL files" {
  # This test verifies that 'make' (without arguments) runs the 'all' target
  # and generates versioned SQL files, not just META.json.
  #
  # This is critical because:
  # 1. The 'all' target depends on $(EXTENSION_VERSION_FILES) - versioned SQL like sql/ext--1.0.sql
  # 2. These versioned SQL files are required for PostgreSQL to load the extension
  # 3. If 'make' only generated META.json, the extension would be unusable

  # Run make (default target should be 'all')
  run make
  assert_success

  # META.json should be regenerated (this was always true)
  assert_file_exists "META.json"

  # Verify versioned SQL files were generated (proves 'all' target ran)
  # The control file specifies default_version = '0.1.1', so we expect:
  # - sql/pgxntool-test--0.1.1.sql (auto-generated from sql/pgxntool-test.sql)
  #
  # Note: The version comes from the .control file, NOT META.json.
  # control.mk.sh reads the control file to generate the versioned filename.
  local control_file=$(ls *.control 2>/dev/null | head -1)
  local ext_name="${control_file%.control}"
  local version=$(grep -E "^[[:space:]]*default_version" "$control_file" | sed "s/.*=[[:space:]]*['\"]\\([^'\"]*\\)['\"].*/\\1/")

  # The versioned SQL file should exist
  local versioned_sql="sql/${ext_name}--${version}.sql"
  assert_file_exists "$versioned_sql"

  # Verify it has the auto-generated header (proves it was actually generated, not just copied)
  run grep -q "DO NOT EDIT - AUTO-GENERATED FILE" "$versioned_sql"
  assert_success
}

@test "make html succeeds" {
  # Build documentation before dist. This is actually redundant since make dist
  # depends on html, but we test it explicitly to verify the workflow.
  run make html
  [ "$status" -eq 0 ]
}

@test "repository is still clean after make targets" {
  # After running make and make html, repository should still be clean
  # (all generated files should be in .gitignore)
  run git status --porcelain
  [ "$status" -eq 0 ]

  # Should have no output (clean repo)
  [ -z "$output" ]
}

@test "make dist creates distribution archive" {
  # Run make dist to create the distribution.
  # This happens AFTER make and make html have run, proving that prior
  # build operations don't break distribution creation.

  # Clean up version tag if it exists (make dist creates this tag)
  # OK to fail: Tag may not exist from previous runs, which is fine
  git tag -d "$VERSION" 2>/dev/null || true

  run make dist
  [ "$status" -eq 0 ]
  [ -f "$DIST_FILE" ]
}

@test "distribution contains exact expected files" {
  # PRIMARY VALIDATION: Compare against exact manifest (dist-expected-files.txt)
  # This is the source of truth - distributions should contain exactly these files.
  # If this test fails, either:
  # 1. Distribution behavior has changed (investigate why)
  # 2. Manifest needs updating (if change is intentional)
  # DIST_FILE is set in setup_file() to the absolute path where make dist creates it
  run validate_exact_distribution_contents "$DIST_FILE"
  if [ "$status" -ne 0 ]; then
    out "Validation failed. Output:"
    out "$output"
  fi
  [ "$status" -eq 0 ]
}

@test "distribution contents pass pattern validation" {
  # SECONDARY VALIDATION: Belt-and-suspenders check using patterns
  # This validates:
  # - Required files (control, META.json, Makefile, SQL, pgxntool)
  # - Expected files (docs, tests)
  # - Excluded files (git metadata, pgxntool docs, build artifacts)
  # - Proper structure (single top-level directory)
  run validate_distribution_contents "$DIST_FILE"
  [ "$status" -eq 0 ]
}

@test "distribution includes test documentation" {
  # Validate specific files from our test template
  local files=$(get_distribution_files "$DIST_FILE")

  # These are specific to pgxntool-test-template structure
  # Foundation copies template files to root, so they appear at root in distribution
  echo "$files" | grep -q "TEST_DOC\.asc"
  echo "$files" | grep -q "doc/asc_doc\.asc"
  echo "$files" | grep -q "doc/asciidoc_doc\.asciidoc"
}

@test "make dist fails with untracked files" {
  # Create an untracked file
  touch untracked_file.txt

  # make dist should fail because repo is dirty
  run make dist
  [ "$status" -ne 0 ]

  # Should mention untracked changes
  echo "$output" | grep -qi "untracked"

  # Clean up
  rm untracked_file.txt
}

@test "make dist fails with uncommitted changes" {
  # Modify a tracked file
  echo "# test comment" >> Makefile

  # make dist should fail
  run make dist
  [ "$status" -ne 0 ]

  # Clean up
  git checkout Makefile
}


# vi: expandtab sw=2 ts=2
