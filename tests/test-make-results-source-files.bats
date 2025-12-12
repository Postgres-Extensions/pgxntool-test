#!/usr/bin/env bats

# Test: make results with source files
#
# Tests that make results correctly handles source files:
# - Ephemeral files from input/*.source → sql/*.sql are cleaned by make clean
# - Ephemeral files from output/*.source → expected/*.out are cleaned by make clean
# - make results skips files that have output/*.source counterparts (source of truth)

load helpers

# Debug function to list files matching a glob pattern
# Usage: debug_ls LEVEL LABEL GLOB_PATTERN
#   LEVEL: debug level (e.g., 5)
#   LABEL: label to display (e.g., "Actual result files")
#   GLOB_PATTERN: glob pattern to match (e.g., "test/results/*.out")
debug_ls() {
  local level="$1"
  local label="$2"
  local glob_pattern="$3"
  if [ "${DEBUG:-0}" -ge "$level" ]; then
    out "$label:"
    shopt -s nullglob
    eval "local files=($glob_pattern)"
    [ ${#files[@]} -gt 0 ] && ls -la "${files[@]}" || out "  (none)"
    shopt -u nullglob
  fi
}

# Transform file paths from one pattern to another
# Usage: transform_files INPUT_ARRAY OUTPUT_ARRAY DIR_REPLACE EXT_REPLACE [USE_BASENAME]
#   INPUT_ARRAY: name of input array (e.g., "input_source_files")
#   OUTPUT_ARRAY: name of output array (e.g., "expected_sql_files")
#   DIR_REPLACE: directory replacement pattern "from:to" (e.g., "input:sql")
#   EXT_REPLACE: extension replacement pattern "from:to" (e.g., ".source:.sql")
#   USE_BASENAME: if set to "basename", extract basename and use DIR_REPLACE as target directory
transform_files() {
  local input_array_name="$1"
  local output_array_name="$2"
  local dir_replace="$3"
  local ext_replace="$4"
  local use_basename="${5:-}"
  
  local -a input_array=("${!input_array_name}")  # Indirect expansion
  
  # Parse replacement patterns: "from:to" -> extract "from" and "to"
  # ${var%%:*} removes longest match of :* from end (gets part before :)
  # ${var##*:} removes longest match of *: from start (gets part after :)
  local from_dir="${dir_replace%%:*}"
  local to_dir="${dir_replace##*:}"
  local from_ext="${ext_replace%%:*}"
  local to_ext="${ext_replace##*:}"
  
  for file in "${input_array[@]}"; do
    local new_file
    if [ "$use_basename" = "basename" ]; then
      local base_name=$(basename "$file" "$from_ext")
      new_file="${to_dir}/${base_name}${to_ext}"
    else
      new_file="${file/$from_dir/$to_dir}"
      new_file="${new_file%$from_ext}$to_ext"
    fi
    # Append to output array using eval
    eval "$output_array_name+=(\"\$new_file\")"
  done
}

setup_file() {
  # Set TOPDIR
  cd "$BATS_TEST_DIRNAME/.."
  export TOPDIR=$(pwd)

  # Independent test - gets its own isolated environment with foundation TEST_REPO
  load_test_env "make-results-source"
  ensure_foundation "$TEST_DIR"
}

setup() {
  load_test_env "make-results-source"
  cd "$TEST_REPO"
}

@test "ephemeral files are created by pg_regress" {
  # Track all files we create and expect (global so other tests can use them)
  input_source_files=()
  output_source_files=()
  expected_sql_files=()
  expected_expected_files=()
  expected_result_files=()
  expected_source_files=()

  # Create input/*.source files to generate SQL tests
  mkdir -p test/input
  local another_input="test/input/another-test.source"
  input_source_files+=("$another_input")
  cat > "$another_input" <<'EOF'
\i @abs_srcdir@/pgxntool/setup.sql

SELECT plan(1);
SELECT is(1 + 1, 2);

\i @abs_srcdir@/pgxntool/finish.sql
EOF
  local source_based_input="test/input/source-based-test.source"
  input_source_files+=("$source_based_input")
  cat > "$source_based_input" <<'EOF'
\i @abs_srcdir@/pgxntool/setup.sql

SELECT plan(1);
SELECT is(40 + 2, 42);

\i @abs_srcdir@/pgxntool/finish.sql
EOF

  # Create output/*.source files for expected output
  mkdir -p test/output
  local another_output="test/output/another-test.source"
  output_source_files+=("$another_output")
  cat > "$another_output" <<'EOF'
1..1
ok 1
EOF
  local source_based_output="test/output/source-based-test.source"
  output_source_files+=("$source_based_output")
  cat > "$source_based_output" <<'EOF'
1..1
ok 1
EOF

  # Build lists of expected ephemeral files
  # input/*.source → sql/*.sql (replace input with sql, .source with .sql)
  expected_sql_files+=("test/sql/pgxntool-test.sql")  # From foundation
  transform_files input_source_files expected_sql_files "input:sql" ".source:.sql"
  
  # output/*.source → expected/*.out (replace output with expected, .source with .out)
  transform_files output_source_files expected_expected_files "output:expected" ".source:.out"
  
  # Results files (from running tests) - same base names as input source files but in results/
  expected_result_files+=("test/results/pgxntool-test.out")  # From foundation
  transform_files input_source_files expected_result_files "test/results" ".source:.out" "basename"
  
  # Source files (should never be removed)
  expected_source_files+=("${input_source_files[@]}")
  expected_source_files+=("${output_source_files[@]}")
  expected_source_files+=("test/input/pgxntool-test.source")  # From foundation

  # Run make test to trigger pg_regress conversions and test execution
  # Note: make test may fail, but we only care that conversions and results were created
  run make test

  # Debug output
  debug 2 "Expected SQL files: ${expected_sql_files[*]}"
  debug 2 "Expected expected files: ${expected_expected_files[*]}"
  debug 2 "Expected result files: ${expected_result_files[*]}"
  debug 2 "Expected source files: ${expected_source_files[*]}"
  debug_ls 5 "Actual result files" "test/results/*.out"
  debug_ls 5 "Actual SQL files" "test/sql/*.sql"
  debug_ls 5 "Actual expected files" "test/expected/*.out"

  assert_files_exist expected_sql_files
  assert_files_exist expected_expected_files
  assert_files_exist expected_result_files
  assert_files_exist expected_source_files
}

@test "make results skips files with output source counterparts" {
  # This test uses files created in the previous test
  # Verify both the ephemeral expected file (from source) and actual results exist
  assert_file_exists "test/expected/another-test.out"
  assert_file_exists "test/results/another-test.out"

  # Get the content of the ephemeral file (from source) - this is the source of truth
  local source_content=$(cat test/expected/another-test.out)

  # Modify the expected file to simulate it being different from source
  # (This simulates what would happen if make results overwrote it)
  echo "MODIFIED_EXPECTED_CONTENT" > test/expected/another-test.out

  # Run make results - it runs make test (which regenerates results), then copies results to expected
  # But it should NOT overwrite files that have output/*.source counterparts
  run make results
  assert_success

  # The expected file should still have the source content (regenerated from output/*.source)
  # NOT the modified content we put in, and NOT the result content
  [ "$(cat test/expected/another-test.out)" = "$source_content" ]
}

@test "make results copies files without output source counterparts" {
  # This test uses files created in the first test
  # Verify result exists and has content
  assert_file_exists "test/results/pgxntool-test.out"
  [ -s "test/results/pgxntool-test.out" ] || error "test/results/pgxntool-test.out is empty"

  # Get the result content
  local result_content=$(cat test/results/pgxntool-test.out)

  # Remove expected file if it exists (it may have been created by make results in previous test)
  rm -f test/expected/pgxntool-test.out

  # Run make results - it runs make test (which regenerates results), then copies results to expected
  run make results
  assert_success

  # Verify result file still exists and has content after make results (make test regenerated it)
  assert_file_exists "test/results/pgxntool-test.out"
  [ -s "test/results/pgxntool-test.out" ] || error "test/results/pgxntool-test.out is empty after make results"

  # The expected file should now exist (copied from results)
  assert_file_exists "test/expected/pgxntool-test.out"
  [ -s "test/expected/pgxntool-test.out" ] || error "test/expected/pgxntool-test.out is empty after make results"

  # The expected file should match the result content (since there's no output source)
  local new_result_content=$(cat test/results/pgxntool-test.out)
  [ "$(cat test/expected/pgxntool-test.out)" = "$new_result_content" ]
}

@test "make results handles mixed source and non-source files" {
  # This test uses files created in the first test
  # Verify both types of files exist
  assert_file_exists "test/results/pgxntool-test.out"
  assert_file_exists "test/expected/source-based-test.out"

  # Get content of source-based file (from pg_regress conversion) - this is the source of truth
  local source_content=$(cat test/expected/source-based-test.out)

  # Get result content for pgxntool-test (no output source, so this should be copied)
  local pgxntool_result=$(cat test/results/pgxntool-test.out)

  # Modify the source-based expected file to simulate it being overwritten
  echo "MODIFIED_SOURCE_BASED" > test/expected/source-based-test.out

  # Remove the non-source expected file (simulate it doesn't exist yet)
  rm -f test/expected/pgxntool-test.out

  # Run make results - it runs make test (which regenerates results), then copies results to expected
  run make results
  assert_success

  # Non-source file should be copied from results
  assert_file_exists "test/expected/pgxntool-test.out"
  local new_pgxntool_result=$(cat test/results/pgxntool-test.out)
  [ "$(cat test/expected/pgxntool-test.out)" = "$new_pgxntool_result" ]

  # Source-based file should NOT be overwritten by make results
  # It should still have the content from the source file conversion (regenerated from output/*.source)
  assert_file_exists "test/expected/source-based-test.out"
  [ "$(cat test/expected/source-based-test.out)" = "$source_content" ]
  # Verify it was NOT overwritten with the modified content we put in
  [ "$(cat test/expected/source-based-test.out)" != "MODIFIED_SOURCE_BASED" ]
}

@test "make clean removes all ephemeral files" {
  # Use the global variables from the first test to derive ephemeral files
  # Build lists of ephemeral files that should be removed
  # input/*.source → sql/*.sql
  local ephemeral_sql_files=()
  for input_file in "${input_source_files[@]}"; do
    local sql_file="${input_file/input/sql}"
    sql_file="${sql_file%.source}.sql"
    ephemeral_sql_files+=("$sql_file")
  done
  # Also include foundation file
  ephemeral_sql_files+=("test/sql/pgxntool-test.sql")
  
  # output/*.source → expected/*.out
  local ephemeral_expected_files=()
  for output_file in "${output_source_files[@]}"; do
    local expected_file="${output_file/output/expected}"
    expected_file="${expected_file%.source}.out"
    ephemeral_expected_files+=("$expected_file")
  done
  
  # Lists of source files that should NOT be removed
  local source_files=("${input_source_files[@]}" "${output_source_files[@]}")
  source_files+=("test/input/pgxntool-test.source")  # From foundation

  # Run make clean once - should remove all ephemeral files
  run make clean
  assert_success

  # Ephemeral SQL files from input sources should be removed
  assert_files_not_exist ephemeral_sql_files

  # Ephemeral expected files from output sources should be removed
  assert_files_not_exist ephemeral_expected_files

  # But source files should still exist (they should never be removed)
  assert_files_exist source_files
}

# vi: expandtab sw=2 ts=2

