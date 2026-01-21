#!/usr/bin/env bats

# Test: Control File Error Handling
#
# Tests that pgxntool's control.mk.sh correctly reports errors for:
# - Missing default_version in control file
# - Duplicate default_version lines in control file
#
# These tests verify that developers get clear error messages when their
# control files are misconfigured, rather than silent failures or confusing errors.

load ../lib/helpers

setup_file() {
  # Set TOPDIR
  setup_topdir

  # Independent test - gets its own isolated environment
  load_test_env "control-errors"

  # Create test directory for error cases
  export ERROR_TEST_DIR="${TEST_DIR}/control-tests"
}

setup() {
  load_test_env "control-errors"

  # Clean up any previous test files
  rm -rf "$ERROR_TEST_DIR"
  mkdir -p "$ERROR_TEST_DIR"
}

# ============================================================================
# MISSING DEFAULT_VERSION ERROR
# ============================================================================

@test "control.mk.sh errors when default_version is missing" {
  cd "$ERROR_TEST_DIR"

  # Create control file without default_version
  cat > missing_version.control << 'EOF'
comment = 'Test extension without default_version'
requires = 'plpgsql'
schema = 'public'
EOF

  # control.mk.sh should fail
  run "$TOPDIR/../pgxntool/control.mk.sh" missing_version.control
  assert_failure

  # Error message should mention default_version
  assert_contains "$output" "default_version"
}

@test "missing default_version error message is clear" {
  cd "$ERROR_TEST_DIR"

  # Create control file without default_version
  cat > no_version.control << 'EOF'
comment = 'Extension with no version'
EOF

  run "$TOPDIR/../pgxntool/control.mk.sh" no_version.control
  assert_failure

  # Error should mention the control file name
  assert_contains "$output" "no_version.control"

  # Error should explain that pgxntool requires default_version
  # The actual error is: "...pgxntool requires it to generate versioned SQL files."
  assert_contains "$output" "pgxntool requires it"
}

# ============================================================================
# DUPLICATE DEFAULT_VERSION ERROR
# ============================================================================

@test "control.mk.sh errors when default_version appears multiple times" {
  cd "$ERROR_TEST_DIR"

  # Create control file with duplicate default_version
  cat > duplicate_version.control << 'EOF'
comment = 'Test extension with duplicate default_version'
default_version = '1.0.0'
default_version = '2.0.0'
requires = 'plpgsql'
EOF

  # control.mk.sh should fail
  run "$TOPDIR/../pgxntool/control.mk.sh" duplicate_version.control
  assert_failure

  # Error message should mention duplicate or multiple
  echo "$output" | grep -qiE "multiple|duplicate"
}

@test "duplicate default_version error message is clear" {
  cd "$ERROR_TEST_DIR"

  # Create control file with duplicate default_version lines
  cat > multi_version.control << 'EOF'
comment = 'Extension with multiple versions'
default_version = '1.0.0'
requires = 'plpgsql'
default_version = '1.5.0'
EOF

  run "$TOPDIR/../pgxntool/control.mk.sh" multi_version.control
  assert_failure

  # Error should mention the control file name
  assert_contains "$output" "multi_version.control"
}

# ============================================================================
# VALID CONTROL FILE (POSITIVE TEST)
# ============================================================================

@test "control.mk.sh succeeds with valid control file" {
  cd "$ERROR_TEST_DIR"

  # Create valid control file
  cat > valid.control << 'EOF'
comment = 'Valid test extension'
default_version = '1.0.0'
requires = 'plpgsql'
schema = 'public'
EOF

  # control.mk.sh should succeed
  run "$TOPDIR/../pgxntool/control.mk.sh" valid.control
  assert_success

  # Output should contain correct variable assignments
  assert_contains "$output" "EXTENSION_valid_VERSION := 1.0.0"
  assert_contains "$output" "EXTENSIONS += valid"
}

@test "control.mk.sh handles single-quoted version" {
  cd "$ERROR_TEST_DIR"

  cat > single_quote.control << 'EOF'
default_version = '2.5.0'
EOF

  run "$TOPDIR/../pgxntool/control.mk.sh" single_quote.control
  assert_success

  assert_contains "$output" "EXTENSION_single_quote_VERSION := 2.5.0"
}

@test "control.mk.sh handles double-quoted version" {
  cd "$ERROR_TEST_DIR"

  cat > double_quote.control << 'EOF'
default_version = "3.0.0"
EOF

  run "$TOPDIR/../pgxntool/control.mk.sh" double_quote.control
  assert_success

  assert_contains "$output" "EXTENSION_double_quote_VERSION := 3.0.0"
}

@test "control.mk.sh handles trailing comments" {
  cd "$ERROR_TEST_DIR"

  cat > with_comment.control << 'EOF'
default_version = '4.0.0' # This is the version
EOF

  run "$TOPDIR/../pgxntool/control.mk.sh" with_comment.control
  assert_success

  assert_contains "$output" "EXTENSION_with_comment_VERSION := 4.0.0"
}

@test "control.mk.sh handles whitespace variations" {
  cd "$ERROR_TEST_DIR"

  cat > whitespace.control << 'EOF'
  default_version  =  '5.0.0'
EOF

  run "$TOPDIR/../pgxntool/control.mk.sh" whitespace.control
  assert_success

  assert_contains "$output" "EXTENSION_whitespace_VERSION := 5.0.0"
}

# ============================================================================
# NONEXISTENT FILE ERROR
# ============================================================================

@test "control.mk.sh errors when control file does not exist" {
  run "$TOPDIR/../pgxntool/control.mk.sh" /nonexistent/path/to/file.control
  assert_failure

  # Error should mention the file not being found
  echo "$output" | grep -qiE "not found|does not exist|no such"
}

# ============================================================================
# MULTIPLE CONTROL FILES
# ============================================================================

@test "control.mk.sh processes multiple control files" {
  cd "$ERROR_TEST_DIR"

  cat > first.control << 'EOF'
default_version = '1.0.0'
EOF

  cat > second.control << 'EOF'
default_version = '2.0.0'
EOF

  run "$TOPDIR/../pgxntool/control.mk.sh" first.control second.control
  assert_success

  assert_contains "$output" "EXTENSION_first_VERSION := 1.0.0"
  assert_contains "$output" "EXTENSION_second_VERSION := 2.0.0"
  assert_contains "$output" "EXTENSIONS += first"
  assert_contains "$output" "EXTENSIONS += second"
}

@test "control.mk.sh fails if any control file is invalid" {
  cd "$ERROR_TEST_DIR"

  cat > good.control << 'EOF'
default_version = '1.0.0'
EOF

  cat > bad.control << 'EOF'
comment = 'No version here'
EOF

  # Should fail when processing bad.control
  run "$TOPDIR/../pgxntool/control.mk.sh" good.control bad.control
  assert_failure

  assert_contains "$output" "bad.control"
}

# vi: expandtab sw=2 ts=2
