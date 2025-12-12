# assertions.bash - Assertion functions for BATS tests
#
# This file contains all assertion and validation functions used by the test suite.
# It should be loaded by helpers.bash.

# Status Assertions
# These should be used after `run command` to check exit status

# Assert that a command succeeded (exit status 0)
# Usage: run some_command
#        assert_success
#        assert_success_with_output  # Includes output on failure
assert_success() {
  if [ "$status" -ne 0 ]; then
    error "Command failed with exit status $status"
  fi
}

# Assert that a command succeeded, showing output on failure
# Usage: run some_command
#        assert_success_with_output
assert_success_with_output() {
  if [ "$status" -ne 0 ]; then
    out "Command failed with exit status $status"
    out "Output:"
    out "$output"
    error "Command failed (see output above)"
  fi
}

# Assert that a command failed (non-zero exit status)
# Usage: run some_command_that_should_fail
#        assert_failure
assert_failure() {
  if [ "$status" -eq 0 ]; then
    error "Command succeeded but was expected to fail"
  fi
}

# Assert that a command failed with a specific exit status
# Usage: run some_command_that_should_fail
#        assert_failure_with_status 1
assert_failure_with_status() {
  local expected_status=$1
  if [ "$status" -ne "$expected_status" ]; then
    error "Command failed with exit status $status, expected $expected_status"
  fi
}

# Basic File/Directory Assertions

# Assertions for common checks
assert_file_exists() {
  local file=$1
  [ -f "$file" ]
}

assert_file_not_exists() {
  local file=$1
  [ ! -f "$file" ]
}

# Assert that all files in an array exist
# Usage: assert_files_exist files_array
#   where files_array is a bash array variable name (not the array itself)
assert_files_exist() {
  local array_name=$1
  local missing_files=()
  local file
  
  # Use eval to access the array by name (works in older bash versions)
  eval "for file in \"\${${array_name}[@]}\"; do
    if [ ! -f \"\$file\" ]; then
      missing_files+=(\"\$file\")
    fi
  done"
  
  if [ ${#missing_files[@]} -gt 0 ]; then
    error "The following files do not exist: ${missing_files[*]}"
  fi
}

# Assert that all files in an array do not exist
# Usage: assert_files_not_exist files_array
#   where files_array is a bash array variable name (not the array itself)
assert_files_not_exist() {
  local array_name=$1
  local existing_files=()
  local file
  
  # Use eval to access the array by name (works in older bash versions)
  eval "for file in \"\${${array_name}[@]}\"; do
    if [ -f \"\$file\" ]; then
      existing_files+=(\"\$file\")
    fi
  done"
  
  if [ ${#existing_files[@]} -gt 0 ]; then
    error "The following files should not exist but do: ${existing_files[*]}"
  fi
}

assert_dir_exists() {
  local dir=$1
  [ -d "$dir" ]
}

assert_dir_not_exists() {
  local dir=$1
  [ ! -d "$dir" ]
}

# Git State Assertions

assert_git_clean() {
  local repo=${1:-.}
  [ -z "$(cd "$repo" && git status --porcelain)" ]
}

assert_git_dirty() {
  local repo=${1:-.}
  [ -n "$(cd "$repo" && git status --porcelain)" ]
}

# String Assertions

assert_contains() {
  local haystack=$1
  local needle=$2
  echo "$haystack" | grep -qF "$needle"
}

assert_not_contains() {
  local haystack=$1
  local needle=$2
  ! echo "$haystack" | grep -qF "$needle"
}

# Semantic Validators
# These validators check structural/behavioral properties rather than string output

# Validate META.json structure and required fields
assert_valid_meta_json() {
  local file=${1:-META.json}

  # Check if valid JSON
  if ! jq empty "$file" 2>/dev/null; then
    error "$file is not valid JSON"
  fi

  # Check required fields
  local name=$(jq -r '.name' "$file")
  local version=$(jq -r '.version' "$file")

  if [[ -z "$name" || "$name" == "null" ]]; then
    error "META.json missing 'name' field"
  fi

  if [[ -z "$version" || "$version" == "null" ]]; then
    error "META.json missing 'version' field"
  fi

  # Validate version format (semver)
  if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "Invalid version format: $version (expected X.Y.Z)"
  fi

  return 0
}

# Validate distribution zip structure
assert_valid_distribution() {
  local zipfile=$1

  # Check zip exists
  if [[ ! -f "$zipfile" ]]; then
    error "Distribution zip not found: $zipfile"
  fi

  # Check zip integrity
  if ! unzip -t "$zipfile" >/dev/null 2>&1; then
    error "Distribution zip is corrupted"
  fi

  # List files in zip
  local files=$(unzip -l "$zipfile" | awk 'NR>3 {print $4}')

  # Check for required files
  if ! echo "$files" | grep -q "META.json"; then
    error "Distribution missing META.json"
  fi

  if ! echo "$files" | grep -q ".*\.control$"; then
    error "Distribution missing .control file"
  fi

  # Check that pgxntool documentation is excluded
  if echo "$files" | grep -q "pgxntool.*\.\(md\|asc\|adoc\|html\)"; then
    error "Distribution contains pgxntool documentation (should be excluded)"
  fi

  return 0
}

# Validate specific JSON field value
# Usage: assert_json_field META.json ".name" "pgxntool-test"
assert_json_field() {
  local file=$1
  local field=$2
  local expected=$3

  local actual=$(jq -r "$field" "$file" 2>/dev/null)

  if [[ "$actual" != "$expected" ]]; then
    error "JSON field $field: expected '$expected', got '$actual'"
  fi

  return 0
}

# vi: expandtab sw=2 ts=2
