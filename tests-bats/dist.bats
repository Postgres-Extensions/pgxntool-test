#!/usr/bin/env bats

# Test distribution packaging
#
# This validates that 'make dist' creates a properly structured distribution
# archive with correct file inclusion/exclusion rules.

setup_file() {
  # Load test environment - must be run after tests/clone has executed
  if [ ! -f "$BATS_TEST_DIRNAME/../.env" ]; then
    echo "ERROR: .env not found. Run legacy tests first to set up test environment." >&2
    return 1
  fi

  source "$BATS_TEST_DIRNAME/../.env"
  source "$TOPDIR/lib.sh"

  # Store these for all tests in this file
  export TEST_REPO
  export DISTRIBUTION_NAME=distribution_test
  export DIST_FILE="$TEST_REPO/../${DISTRIBUTION_NAME}-0.1.0.zip"
}

setup() {
  cd "$TEST_REPO"
}

@test "make dist creates distribution archive" {
  # Run make dist ourselves to ensure zip exists
  make dist
  [ -f "$DIST_FILE" ]
}

@test "distribution contains documentation files" {
  # Ensure dist was created
  [ -f "$DIST_FILE" ] || make dist

  # Extract list of files from zip
  local files=$(unzip -l "$DIST_FILE" | awk '{print $4}')

  # Should contain at least one doc file
  echo "$files" | grep -E '\.(asc|adoc|asciidoc|html|md|txt)$'
}

@test "distribution excludes pgxntool documentation" {
  [ -f "$DIST_FILE" ] || make dist
  local files=$(unzip -l "$DIST_FILE" | awk '{print $4}')

  # Should NOT contain any pgxntool docs
  # Use ! with run to assert command should fail (no matches found)
  run bash -c "echo '$files' | grep -E 'pgxntool/.*\.(asc|adoc|asciidoc|html|md|txt)$'"
  [ "$status" -eq 1 ]
}

@test "distribution includes expected extension files" {
  [ -f "$DIST_FILE" ] || make dist
  local files=$(unzip -l "$DIST_FILE" | awk '{print $4}')

  # Check for key files
  echo "$files" | grep -q "\.control$"
  echo "$files" | grep -q "\.sql$"
}

@test "distribution includes test documentation" {
  [ -f "$DIST_FILE" ] || make dist
  local files=$(unzip -l "$DIST_FILE" | awk '{print $4}')

  # Should have test docs
  echo "$files" | grep -q "t/TEST_DOC\.asc"
  echo "$files" | grep -q "t/doc/asc_doc\.asc"
  echo "$files" | grep -q "t/doc/asciidoc_doc\.asciidoc"
}

# vi: expandtab sw=2 ts=2
