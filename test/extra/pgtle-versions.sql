/*
 * Test: pg_tle extension functionality with specific version
 * This test verifies that the extension works correctly with a given pg_tle version
 * The version is passed as a psql variable :pgtle_version
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

-- Set up pgTap (assumes it's already installed)
SET client_min_messages = WARNING;
SET search_path = tap, public;

-- Declare test plan (3 tests total)
SELECT plan(3);

-- Test 1: CREATE EXTENSION should work
SELECT lives_ok(
  $lives_ok$CREATE EXTENSION "pgxntool-test"$lives_ok$,
  'should create extension'
);

-- Test 2: Verify int function exists
SELECT has_function(
  'public',
  'pgxntool-test',
  ARRAY['int', 'int'],
  'int version of pgxntool-test function should exist'
);

-- Test 3: Verify bigint function does NOT exist in 0.1.0
SELECT hasnt_function(
  'public',
  'pgxntool-test',
  ARRAY['bigint', 'bigint'],
  'bigint version should not exist in 0.1.0'
);

SELECT finish();

-- vi: expandtab ts=2 sw=2

