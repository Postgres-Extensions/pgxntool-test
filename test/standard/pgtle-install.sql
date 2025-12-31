/*
 * Test: pg_tle installation and functionality
 * Tests that pg_tle registration SQL files work correctly:
 * - CREATE EXTENSION works after registration
 * - Extension functions exist in base version
 * - Extension upgrades work
 * - Multiple versions can be created and upgraded
 */

-- No status messages
\set QUIET true
-- Verbose error messages
\set VERBOSITY verbose
-- Revert all changes on failure
\set ON_ERROR_ROLLBACK 1
\set ON_ERROR_STOP true

\pset format unaligned
\pset tuples_only true
\pset pager off

BEGIN;

-- Set up pgTap
SET client_min_messages = WARNING;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'tap') THEN
    CREATE SCHEMA tap;
  END IF;
END
$$;

SET search_path = tap, public;
CREATE EXTENSION IF NOT EXISTS pgtap SCHEMA tap;

-- Declare test plan (9 tests total: 1 setup + 8 actual tests)
SELECT plan(9);

-- Ensure pg_tle extension exists
SELECT lives_ok(
  $lives_ok$CREATE EXTENSION IF NOT EXISTS pg_tle$lives_ok$,
  'pg_tle extension should exist or be created'
);

/*
 * Test 1: Verify extension can be created after registration
 * (Registration is done by make run-pgtle, which should be run before this test)
 */
SELECT has_extension(
  'pgxntool-test',
  'Extension should be available after registration'
);

-- Test 2: Verify extension was created with correct default version
SELECT is(
  (SELECT extversion FROM pg_extension WHERE extname = 'pgxntool-test'),
  '0.1.1',
  'Extension should be created with default version 0.1.1'
);

-- Test 3: Verify int function exists in base version
SELECT has_function(
  'public',
  'pgxntool-test',
  ARRAY['int', 'int'],
  'int version of pgxntool-test function should exist in base version'
);

/*
 * Test 4: Test extension upgrade
 * Drop and recreate at base version
 */
SELECT lives_ok(
  $lives_ok$DROP EXTENSION IF EXISTS "pgxntool-test" CASCADE$lives_ok$,
  'should drop extension if it exists'
);
SELECT lives_ok(
  $lives_ok$CREATE EXTENSION "pgxntool-test" VERSION '0.1.0'$lives_ok$,
  'should create extension at version 0.1.0'
);

-- Test 6: Verify current version is 0.1.0
SELECT is(
  (SELECT extversion FROM pg_extension WHERE extname = 'pgxntool-test'),
  '0.1.0',
  'Extension should start at version 0.1.0'
);

-- Test 7: Verify bigint function does NOT exist in 0.1.0
SELECT hasnt_function(
  'public',
  'pgxntool-test',
  ARRAY['bigint', 'bigint'],
  'bigint version should not exist in 0.1.0'
);

-- Upgrade extension
SELECT lives_ok(
  $lives_ok$ALTER EXTENSION "pgxntool-test" UPDATE TO '0.1.1'$lives_ok$,
  'should upgrade extension to 0.1.1'
);

-- Test 8: Verify new version is 0.1.1
SELECT is(
  (SELECT extversion FROM pg_extension WHERE extname = 'pgxntool-test'),
  '0.1.1',
  'Extension upgraded successfully to 0.1.1'
);

-- Test 9: Verify upgrade added bigint function
SELECT has_function(
  'public',
  'pgxntool-test',
  ARRAY['bigint', 'bigint'],
  'bigint version should exist after upgrade to 0.1.1'
);

SELECT finish();

-- vi: expandtab ts=2 sw=2
