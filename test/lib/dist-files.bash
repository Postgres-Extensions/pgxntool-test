#!/usr/bin/env bash

# Distribution File Validation
#
# This file defines what files MUST, SHOULD, and MUST NOT appear in
# distributions created by `make dist`.
#
# Used by: 02-dist.bats, test-dist-clean.bats
#
# Two validation approaches:
# 1. Exact file manifest (dist-expected-files.txt) - primary validation
# 2. Pattern-based validation (validate_distribution_contents) - safety net
#
# CRITICAL: The exact manifest is the source of truth. Changes to it indicate
# changes to distribution behavior that need documentation and review.

# Check if a distribution contains expected files
#
# Usage: validate_distribution_contents "$DIST_FILE"
# Returns: 0 if valid, 1 if invalid (with error messages)
validate_distribution_contents() {
  local dist_file="$1"

  if [ ! -f "$dist_file" ]; then
    echo "ERROR: Distribution file not found: $dist_file"
    return 1
  fi

  # Extract file list (skip header lines, use grep pattern matching)
  local files=$(unzip -l "$dist_file" | grep "^[[:space:]]*[0-9]" | awk '{print $4}')

  local failed=0

  # ============================================================================
  # REQUIRED FILES - Distribution MUST contain these
  # ============================================================================

  echo "# Validating required files..."

  # Extension control file
  if ! echo "$files" | grep -q "\.control$"; then
    echo "ERROR: Missing .control file"
    failed=1
  fi

  # META.json (PGXN metadata)
  if ! echo "$files" | grep -q "META\.json$"; then
    echo "ERROR: Missing META.json"
    failed=1
  fi

  # Makefile (extensions need this to build)
  if ! echo "$files" | grep -q "^[^/]*/Makefile$"; then
    echo "ERROR: Missing Makefile"
    failed=1
  fi

  # SQL files (at least one .sql file, either at root or in sql/)
  if ! echo "$files" | grep -q "\.sql$"; then
    echo "ERROR: Missing SQL files"
    failed=1
  fi

  # pgxntool directory (the build framework itself)
  if ! echo "$files" | grep -q "^[^/]*/pgxntool/"; then
    echo "ERROR: Missing pgxntool/ directory"
    failed=1
  fi

  # ============================================================================
  # EXPECTED FILES - Should be present in typical extensions
  # ============================================================================

  echo "# Validating expected files..."

  # Documentation source files (at least one)
  if ! echo "$files" | grep -qE '\.(asc|adoc|asciidoc|md|txt)$'; then
    echo "WARNING: No documentation source files found"
  fi

  # Generated HTML documentation (if docs exist)
  if echo "$files" | grep -qE '\.(asc|adoc|asciidoc)$'; then
    if ! echo "$files" | grep -q "\.html$"; then
      echo "WARNING: Documentation source exists but no .html generated"
    fi
  fi

  # Test files (test/sql/ or test/input/)
  if ! echo "$files" | grep -qE 'test/(sql|input)/'; then
    echo "WARNING: No test files found in test/ directory"
  fi

  # ============================================================================
  # EXCLUDED FILES - Must NOT be present
  # ============================================================================

  echo "# Validating excluded files..."

  # Git repository metadata
  if echo "$files" | grep -q "\.git/"; then
    echo "ERROR: Distribution includes .git/ directory"
    failed=1
  fi

  # pgxntool's own documentation (should not be in extension distributions)
  if echo "$files" | grep -qE 'pgxntool/.*\.(asc|adoc|asciidoc|html|md|txt)$'; then
    echo "ERROR: Distribution includes pgxntool documentation"
    failed=1
  fi

  # Build artifacts (should be in .gitignore)
  if echo "$files" | grep -q "\.o$"; then
    echo "ERROR: Distribution includes .o files (build artifacts)"
    failed=1
  fi

  if echo "$files" | grep -q "\.so$"; then
    echo "ERROR: Distribution includes .so files (build artifacts)"
    failed=1
  fi

  # Test results (should not be distributed)
  if echo "$files" | grep -qE 'results/|regression\.(diffs|out)'; then
    echo "ERROR: Distribution includes test result files"
    failed=1
  fi

  # ============================================================================
  # STRUCTURE VALIDATION
  # ============================================================================

  echo "# Validating distribution structure..."

  # All files should be under a single top-level directory (PGXN requirement)
  # Extract the first path component from first non-directory file
  local first_file=$(echo "$files" | grep -v "/$" | grep -v "^$" | head -1)

  if [ -z "$first_file" ]; then
    echo "ERROR: No files found in distribution"
    failed=1
  else
    # Get the prefix (everything before first /)
    local prefix=$(echo "$first_file" | sed 's/\/.*//')

    # Check if all files start with this prefix
    if echo "$files" | grep -v "^$prefix/" | grep -v "^$" | grep -q .; then
      echo "ERROR: Files not under single top-level directory"
      echo "  Expected prefix: $prefix/"
      echo "  Found:"
      echo "$files" | grep -v "^$prefix/" | head -5
      failed=1
    fi
  fi

  return $failed
}

# Get list of files from distribution (for custom validation)
#
# Usage: files=$(get_distribution_files "$DIST_FILE")
get_distribution_files() {
  local dist_file="$1"

  if [ ! -f "$dist_file" ]; then
    echo
    return 1
  fi

  # Extract file list, skipping unzip header/footer
  unzip -l "$dist_file" | grep "^[[:space:]]*[0-9]" | awk '{print $4}'
}

# Validate distribution against exact expected file manifest
#
# Usage: validate_exact_distribution_contents "$DIST_FILE"
# Returns: 0 if exact match, 1 if differences found
#
# This is the PRIMARY validation - it checks that the distribution contains
# exactly the files listed in dist-expected-files.txt, no more, no less.
validate_exact_distribution_contents() {
  local dist_file="$1"

  if [ ! -f "$dist_file" ]; then
    echo "ERROR: Distribution file not found: $dist_file"
    return 1
  fi

  # Load expected file list
  # dist-files.bash is in test/lib/, so we keep the manifest there as well
  local manifest_file="${BASH_SOURCE[0]%/*}/dist-expected-files.txt"
  if [ ! -f "$manifest_file" ]; then
    echo "ERROR: Expected file manifest not found: $manifest_file"
    return 1
  fi

  # Read expected files (skip comments and blank lines)
  local expected=$(grep -v '^#' "$manifest_file" | grep -v '^$' | sort)

  # Get actual files from distribution (remove prefix directory)
  local actual=$(unzip -l "$dist_file" | grep "^[[:space:]]*[0-9]" | awk '{print $4}' | \
                 sed 's|^[^/]*/||' | grep -v '^$' | sort)

  # Compare expected vs actual
  local diff_output=$(diff <(echo "$expected") <(echo "$actual"))

  if [ -n "$diff_output" ]; then
    echo "ERROR: Distribution contents differ from expected manifest"
    echo
    echo "Differences (< expected, > actual):"
    echo "$diff_output"
    echo
    echo "This indicates distribution contents have changed."
    echo "If this change is intentional, update dist-expected-files.txt"
    return 1
  fi

  return 0
}

# vi: expandtab sw=2 ts=2
