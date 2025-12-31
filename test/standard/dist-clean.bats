#!/usr/bin/env bats

# Test: Distribution from Clean Repository
#
# CRITICAL: This test is part of a dual-testing strategy with 02-dist.bats.
#
# WHY TWO DIST TESTS:
# - test-dist-clean (this file): Tests `make dist` from completely clean foundation
# - 02-dist.bats: Tests `make dist` after META.json generation (sequential test)
#
# Both are needed because:
# 1. Extensions must support `git clone → make dist` (proves dependencies are correct)
# 2. Extensions must also work after other operations (`make` → `make dist`)
# 3. Both scenarios MUST produce identical distributions
# 4. Verifies `make dist` doesn't accidentally depend on undeclared prerequisites
#
# This test validates that 'make dist' works correctly from a completely
# clean repository (just after foundation setup, before any other make commands).
#
# Key validations:
# - make dist succeeds from clean state (proves dependencies declared correctly)
# - Generated files (.html) are properly ignored via .gitignore
# - Distribution includes correct files (docs, SQL, tests)
# - Distribution format is correct (proper prefix, file structure)
# - Repository remains clean after dist (no untracked files from build process)

load helpers
load dist-files

setup_file() {
  # Set TOPDIR
  cd "$BATS_TEST_DIRNAME/.."
  export TOPDIR=$(pwd)

  # Independent test - gets its own isolated environment with foundation TEST_REPO
  load_test_env "dist-clean"
  ensure_foundation "$TEST_DIR"

  # CRITICAL: Extract distribution name and version dynamically from META.json
  #
  # Cannot hardcode values because foundation's META.json has been configured
  # with actual values. Must read from META.json to get correct distribution
  # filename (used by git archive in make dist).
  export DISTRIBUTION_NAME=$(grep '"name"' "$TEST_REPO/META.json" | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
  export VERSION=$(grep '"version"' "$TEST_REPO/META.json" | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
  export DIST_FILE="$TEST_DIR/${DISTRIBUTION_NAME}-${VERSION}.zip"
}

setup() {
  load_test_env "dist-clean"
  cd "$TEST_REPO"
}

@test "repository is in clean state before make dist" {
  # Verify repo is clean (no uncommitted changes, no untracked files except ignored)
  run git status --porcelain
  assert_success

  # Should have no output (repo is clean)
  [ -z "$output" ]

  # Clean up any existing version branch (from previous runs)
  # make dist creates a branch with the version number, and will fail if it exists
  # OK to fail: Branch may not exist, which is fine for cleanup
  git branch -D "$VERSION" 2>/dev/null || true

  # Also clean up any previous distribution file
  rm -f "$DIST_FILE"
}

@test "make dist succeeds from clean repository" {
  # This is the key test: make dist must work from a completely clean checkout.
  # It should build documentation, create versioned SQL files, and package everything.
  run make dist
  assert_success_with_output
}

@test "make dist creates distribution archive" {
  [ -f "$DIST_FILE" ]
}

@test "make dist generates HTML documentation" {
  # make dist should have built HTML docs as a prerequisite
  [ -f "doc/adoc_doc.html" ] || [ -f "doc/asciidoc_doc.html" ]
}

@test "generated HTML files are ignored by git" {
  # HTML files should be in .gitignore, so they don't make repo dirty
  run git status --porcelain
  assert_success

  # Should have no untracked .html files
  ! echo "$output" | grep -q "\.html$"
}

@test "repository remains clean after make dist" {
  # After make dist, repo should still be clean (all generated files ignored)
  run git status --porcelain
  assert_success
  [ -z "$output" ]
}

@test "distribution contains exact expected files" {
  # PRIMARY VALIDATION: Compare against exact manifest (dist-expected-files.txt)
  # This is the source of truth - distributions should contain exactly these files.
  # If this test fails, either:
  # 1. Distribution behavior has changed (investigate why)
  # 2. Manifest needs updating (if change is intentional)
  run validate_exact_distribution_contents "$DIST_FILE"
  assert_success_with_output
}

@test "distribution contents pass pattern validation" {
  # SECONDARY VALIDATION: Belt-and-suspenders check using patterns
  # This validates:
  # - Required files (control, META.json, Makefile, SQL, pgxntool)
  # - Expected files (docs, tests)
  # - Excluded files (git metadata, pgxntool docs, build artifacts)
  # - Proper structure (single top-level directory)
  run validate_distribution_contents "$DIST_FILE"
  assert_success
}

@test "distribution contains test documentation files" {
  # Validate specific files from our test template
  local files=$(get_distribution_files "$DIST_FILE")

  # These are specific to pgxntool-test-template structure
  echo "$files" | grep -q "t/TEST_DOC\.asc"
  echo "$files" | grep -q "t/doc/.*\.asc"
}

# vi: expandtab sw=2 ts=2
