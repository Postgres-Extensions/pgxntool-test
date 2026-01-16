#!/usr/bin/env bats

# Test: pg_tle installation against multiple versions (optional)
#
# Tests that pg_tle registration SQL files work correctly with different
# pg_tle versions. This test iterates through all available pg_tle versions
# and verifies installation works with each.
#
# This test is optional because:
# - It requires multiple pg_tle versions to be available
# - It's more comprehensive and may take longer
# - Not all environments will have multiple versions available
#
# This is an independent test that requires PostgreSQL and pg_tle

load ../lib/helpers

setup_file() {
  debug 1 ">>> ENTER setup_file: test-pgtle-versions (PID=$$)"
  setup_topdir

  load_test_env "pgtle-versions"
  ensure_foundation "$TEST_DIR"
  debug 1 "<<< EXIT setup_file: test-pgtle-versions (PID=$$)"
}

setup() {
  load_test_env "pgtle-versions"
  cd "$TEST_REPO"
  
  # Skip if PostgreSQL not available
  skip_if_no_postgres
  
  # Skip if pg_tle not available
  skip_if_no_pgtle
  
  # Reset pg_tle cache since we'll be installing different versions
  reset_pgtle_cache
  
  # Uninstall pg_tle if it's installed (we'll install specific versions in tests)
  psql -X -c "DROP EXTENSION IF EXISTS pg_tle CASCADE;" >/dev/null 2>&1 || true
}

@test "pgtle-versions: ensure pgTap is installed" {
  # Ensure pgTap extension is installed
  psql -X -c "CREATE EXTENSION IF NOT EXISTS pgtap SCHEMA tap;" >/dev/null 2>&1 || true
  
  # Verify pgTap is available
  run psql -X -tAc "SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname = 'pgtap');"
  assert_success
  assert_contains "$output" "t"
}

@test "pgtle-versions: test each available pg_tle version" {
  # Query all available versions
  local versions
  versions=$(psql -X -tAc "SELECT version FROM pg_available_extension_versions WHERE name = 'pg_tle' ORDER BY version;" 2>/dev/null || echo)
  
  if [ -z "$versions" ]; then
    skip "No pg_tle versions available for testing"
  fi
  
  # Process each version
  while IFS= read -r version; do
    [ -z "$version" ] && continue

    out -f "Testing with pg_tle version: $version"

    # Ensure pg_tle extension is at the requested version
    # This must succeed - we're testing known available versions
    if ! ensure_pgtle_extension "$version"; then
      error "Failed to install pg_tle version $version: $PGTLE_EXTENSION_ERROR"
    fi
    
    # Run make check-pgtle (should report the version we just created)
    run make check-pgtle
    assert_success
    assert_contains "$output" "$version"
    
    # Run make run-pgtle (should auto-detect version and use correct files)
    run make run-pgtle
    assert_success "Failed to install pg_tle registration at version $version"
    
    # Run SQL tests (in a transaction that doesn't commit)
    local sql_file="${BATS_TEST_DIRNAME}/pgtle-versions.sql"
    run psql -X -v ON_ERROR_STOP=1 -f "$sql_file" 2>&1
    if [ "$status" -ne 0 ]; then
      out -f "psql command failed with exit status $status"
      out -f "SQL file: $sql_file"
      out -f "pg_tle version: $version"
      out -f "Output:"
      out -f "$output"
    fi
    assert_success "SQL tests failed for pg_tle version $version"
    
    # pgTap output should contain test results
    assert_contains "$output" "1.."
    
    # Clean up extension registration for next iteration
    psql -X -c "DROP EXTENSION IF EXISTS \"pgxntool-test\";" >/dev/null 2>&1 || true
    psql -X -c "DROP EXTENSION pg_tle;" >/dev/null 2>&1 || true
  done <<< "$versions"
}

# vi: expandtab sw=2 ts=2
