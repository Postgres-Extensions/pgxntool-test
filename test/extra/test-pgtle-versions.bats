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

  # Run full pgtle-install test suite for each version
  # Uses PGTLE_TARGET_VERSION env var to control which version is tested
  local bats_cmd="${TOPDIR}/test/bats/bin/bats"
  local pgtle_tests="${TOPDIR}/test/standard/pgtle-install.bats"

  while IFS= read -r version; do
    [ -z "$version" ] && continue

    out -f "Running pgtle-install tests with pg_tle version: $version"

    # Clean up before each version test
    psql -X -c "DROP EXTENSION IF EXISTS \"pgxntool-test\";" >/dev/null 2>&1
    # Unregister from pg_tle if registered (only if pg_tle extension exists)
    psql -X -c "DO \$\$ BEGIN IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_tle') THEN PERFORM pgtle.uninstall_extension('pgxntool-test'); END IF; EXCEPTION WHEN no_data_found THEN NULL; END \$\$;" >/dev/null 2>&1
    psql -X -c "DROP EXTENSION IF EXISTS pg_tle CASCADE;" >/dev/null 2>&1

    # Remove physical extension files if installed (pg_tle refuses to register
    # extensions that have physical control files)
    local ext_dir
    ext_dir=$(psql -X -tAc "SELECT setting || '/extension' FROM pg_config WHERE name = 'SHAREDIR';" | tr -d '[:space:]')
    if [ -n "$ext_dir" ] && [ -f "$ext_dir/pgxntool-test.control" ]; then
      rm -f "$ext_dir"/pgxntool-test*
    fi

    # Run pgtle-install.bats with target version
    # The tests will use ensure_pgtle_extension to install this version
    run env PGTLE_TARGET_VERSION="$version" "$bats_cmd" "$pgtle_tests"
    if [ "$status" -ne 0 ]; then
      out -f "pgtle-install tests failed for pg_tle version $version"
      out -f "Output:"
      out -f "$output"
    fi
    assert_success "pgtle-install tests failed for pg_tle version $version"

  done <<< "$versions"
}

# vi: expandtab sw=2 ts=2
