#!/usr/bin/env bats

# Test: pg_tle installation and functionality
#
# Tests that pg_tle registration SQL files can be installed and that
# extensions work correctly after installation:
# - make check-pgtle reports version
# - pg_tle extension can be created/updated
# - make run-pgtle installs registration
# - CREATE EXTENSION works after registration (tested in SQL)
# - Extension functions work correctly (tested in SQL)
# - Extension upgrades work (tested in SQL)
#
# This is an independent test that requires PostgreSQL and pg_tle

load ../lib/helpers

setup_file() {
  debug 1 ">>> ENTER setup_file: test-pgtle-install (PID=$$)"
  setup_topdir

  load_test_env "pgtle-install"
  ensure_foundation "$TEST_DIR"
  debug 1 "<<< EXIT setup_file: test-pgtle-install (PID=$$)"
}

setup() {
  load_test_env "pgtle-install"
  cd "$TEST_REPO"

  # Skip if PostgreSQL not available
  skip_if_no_postgres

  # Skip if pg_tle not available
  skip_if_no_pgtle

  # If PGTLE_TARGET_VERSION is set, ensure we're at that version
  # This allows multi-version testing without code duplication
  if [ -n "${PGTLE_TARGET_VERSION:-}" ]; then
    reset_pgtle_cache
    if ! ensure_pgtle_extension "$PGTLE_TARGET_VERSION"; then
      skip "Cannot install pg_tle $PGTLE_TARGET_VERSION: $PGTLE_EXTENSION_ERROR"
    fi
  fi
}

@test "pgtle-install: make check-pgtle reports pg_tle version" {
  # Ensure pg_tle extension is created first (required for check-pgtle)
  if ! ensure_pgtle_extension; then
    skip "pg_tle extension cannot be created: $PGTLE_EXTENSION_ERROR"
  fi
  
  run make check-pgtle
  assert_success
  # Should output version information
  assert_contains "$output" "pg_tle extension version:"
}

@test "pgtle-install: pg_tle is available and pgtle_admin role exists" {
  # Verify pg_tle is available in cluster
  run psql -X -tAc "SELECT EXISTS(SELECT 1 FROM pg_available_extensions WHERE name = 'pg_tle');"
  assert_success
  assert_contains "$output" "t"
  
  # Verify pgtle_admin role exists (may not exist until CREATE EXTENSION pg_tle is run)
  run psql -X -tAc "SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname = 'pgtle_admin');"
  assert_success
  # Role may not exist yet, that's OK
  
  # Create or update pg_tle extension to newest version
  if ! ensure_pgtle_extension; then
    skip "pg_tle extension cannot be created: $PGTLE_EXTENSION_ERROR"
  fi
  
  # Verify we're using the newest version available
  local current_version
  current_version=$(psql -X -tAc "SELECT extversion FROM pg_extension WHERE extname = 'pg_tle';" | tr -d '[:space:]')
  local newest_version
  newest_version=$(psql -X -tAc "SELECT MAX(version) FROM pg_available_extension_versions WHERE name = 'pg_tle';" | tr -d '[:space:]')
  [ "$current_version" = "$newest_version" ]
}

@test "pgtle-install: make run-pgtle installs extension registration" {
  # Ensure pg_tle extension is created (creates pgtle_admin role)
  if ! ensure_pgtle_extension; then
    skip "pg_tle extension cannot be created: $PGTLE_EXTENSION_ERROR"
  fi

  # Clean up any existing extension registration from previous test runs
  psql -X -c "DROP EXTENSION IF EXISTS \"pgxntool-test\";" >/dev/null 2>&1
  # Unregister from pg_tle if registered (only if pg_tle extension exists)
  psql -X -c "DO \$\$ BEGIN IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_tle') THEN PERFORM pgtle.uninstall_extension('pgxntool-test'); END IF; EXCEPTION WHEN no_data_found THEN NULL; END \$\$;" >/dev/null 2>&1

  # Remove physical extension files if installed (pg_tle refuses to register
  # extensions that have physical control files in the extension directory)
  local ext_dir
  ext_dir=$(psql -X -tAc "SELECT setting || '/extension' FROM pg_config WHERE name = 'SHAREDIR';" | tr -d '[:space:]')
  if [ -n "$ext_dir" ] && [ -f "$ext_dir/pgxntool-test.control" ]; then
    rm -f "$ext_dir"/pgxntool-test*
  fi

  # Generate pg_tle SQL files first
  run make pgtle
  assert_success

  # Run run-pgtle (this will install the registration SQL)
  run make run-pgtle
  if [ "$status" -ne 0 ]; then
    echo "make run-pgtle failed with status $status" >&2
    echo "Output:" >&2
    echo "$output" >&2
  fi
  assert_success
}

@test "pgtle-install: SQL tests (registration, functions, upgrades)" {
  # Ensure pg_tle extension is created
  if ! ensure_pgtle_extension; then
    skip "pg_tle extension cannot be created: $PGTLE_EXTENSION_ERROR"
  fi

  # Run the SQL test file which contains all pgTap tests
  # pgTap produces TAP output which we capture and pass through
  local sql_file="${BATS_TEST_DIRNAME}/pgtle-install.sql"
  run psql -X -v ON_ERROR_STOP=1 -f "$sql_file" 2>&1
  if [ "$status" -ne 0 ]; then
    echo "psql command failed with exit status $status" >&2
    echo "SQL file: $sql_file" >&2
    echo "Output:" >&2
    echo "$output" >&2
  fi
  assert_success
  
  # pgTap output should contain test results
  # We check for the plan line to ensure tests ran
  assert_contains "$output" "1.."
}

@test "pgtle-install: uninstall handler catches no_data_found" {
  # Verify the exception handler pattern used in generated SQL correctly
  # catches the error when extension doesn't exist.
  # pg_tle's uninstall_extension() raises no_data_found (P0002).
  #
  # setup() already ensures pg_tle is available via skip_if_no_pgtle

  # Test the exception handler pattern that should be in generated SQL
  # This should succeed because no_data_found catches P0002
  run psql -X -v ON_ERROR_STOP=1 -c "DO \$\$ BEGIN PERFORM pgtle.uninstall_extension('__nonexistent_test_extension__'); EXCEPTION WHEN no_data_found THEN NULL; END \$\$;"
  if [ "$status" -ne 0 ]; then
    echo "Exception handler failed to catch no_data_found (P0002)" >&2
    echo "Output:" >&2
    echo "$output" >&2
  fi
  assert_success
}

@test "pgtle-install: empty upgrade file installs successfully" {
  # Empty upgrade files are intentional no-op upgrades (version bump only).
  # pg_tle should accept the generated SQL with empty upgrade content.

  # Clean up any existing registration and generated files
  psql -X -c "DROP EXTENSION IF EXISTS \"pgxntool-test\";" >/dev/null 2>&1
  # Unregister from pg_tle if registered (ignore error if not registered)
  psql -X -c "DO \$\$ BEGIN IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_tle') THEN PERFORM pgtle.uninstall_extension('pgxntool-test'); END IF; EXCEPTION WHEN no_data_found THEN NULL; END \$\$;" >/dev/null 2>&1
  rm -rf "$TEST_REPO/pg_tle"

  # Remove physical extension files if installed (pg_tle refuses to register
  # extensions that have physical control files in the extension directory)
  local ext_dir
  ext_dir=$(psql -X -tAc "SELECT setting || '/extension' FROM pg_config WHERE name = 'SHAREDIR';" | tr -d '[:space:]')
  if [ -n "$ext_dir" ] && [ -f "$ext_dir/pgxntool-test.control" ]; then
    rm -f "$ext_dir"/pgxntool-test*
  fi

  # Create an empty upgrade file (no-op upgrade from 0.1.1 to 0.1.2)
  touch "$TEST_REPO/sql/pgxntool-test--0.1.1--0.1.2.sql"

  # Generate and install pg_tle SQL (fresh generation)
  run make pgtle
  assert_success

  run make run-pgtle
  if [ "$status" -ne 0 ]; then
    echo "make run-pgtle failed with empty upgrade file" >&2
    echo "Output:" >&2
    echo "$output" >&2
  fi
  assert_success

  # Verify the upgrade path works
  run psql -X -v ON_ERROR_STOP=1 -c "
    CREATE EXTENSION \"pgxntool-test\" VERSION '0.1.1';
    ALTER EXTENSION \"pgxntool-test\" UPDATE TO '0.1.2';
    SELECT extversion FROM pg_extension WHERE extname = 'pgxntool-test';
  "
  assert_success
  assert_contains "$output" "0.1.2"

  # Cleanup
  rm -f "$TEST_REPO/sql/pgxntool-test--0.1.1--0.1.2.sql"
  psql -X -c "DROP EXTENSION IF EXISTS \"pgxntool-test\";" >/dev/null 2>&1 || true
}

@test "pgtle-install: test cleanup" {
  # Clean up test extension
  run psql -X -c "DROP EXTENSION IF EXISTS \"pgxntool-test\";"
  # Don't fail if extension doesn't exist
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

# vi: expandtab sw=2 ts=2
