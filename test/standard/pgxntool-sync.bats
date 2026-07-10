#!/usr/bin/env bats

# Test: pgxntool-sync end-to-end
#
# This test validates the full pgxntool-sync flow:
#   git subtree pull → update-setup-files.sh
#
# Both entry points are exercised:
#   - the `make pgxntool-sync-<name>` target (variable-driven source)
#   - running `pgxntool/pgxntool-sync.sh <repo> <branch>` directly, without make
#
# Unlike the unit tests in update-setup-files.bats (which test 3-way merge
# scenarios in isolation), this test exercises the complete sync pipeline
# including git subtree pull mechanics.
#
# Note: we always sync from a local source repo, never the real default remote.
# The suite is offline, so the default remote/branch configured in
# pgxntool-sync.sh is checked statically (see the default-source test) rather
# than by pulling from the network.
#
# A dedicated source repo is needed because git subtree pull requires the
# initial add to have been done via `git subtree add`. During normal test
# runs, pgxntool may be dirty (uncommitted changes), causing
# build_test_repo_from_template to use rsync instead. This test creates
# its own clean source repo to guarantee git subtree add is used.

load ../lib/helpers
load ../lib/assertions

setup_file() {
  # Note: BATS runs with set -eET, so any command failure here (including
  # inside subshells) will abort setup_file and BATS will report the failure.
  setup_topdir

  # Always start fresh - this test creates its own repos from scratch
  clean_env "pgxntool-sync"
  load_test_env "pgxntool-sync"

  # =========================================================================
  # Step 1: Create a clean pgxntool source repo
  # =========================================================================
  local source_repo="$TEST_DIR/pgxntool-source"
  mkdir "$source_repo"
  (
    cd "$source_repo"
    git init
    # Copy current pgxntool files (excluding .git)
    rsync -a --exclude='.git' "$PGXNREPO/" ./
    git add .
    git commit -m "Initial pgxntool"
    git tag v1

    # Modify _.gitignore with a marker line for sync detection
    echo "# pgxntool-sync-test-marker" >> _.gitignore
    git add _.gitignore
    git commit -m "Update gitignore"
    git tag v2

    # A second marker at v3, used to exercise the standalone script path after
    # the make path has already advanced the test repo to v2.
    echo "# pgxntool-sync-test-marker-v3" >> _.gitignore
    git add _.gitignore
    git commit -m "Update gitignore again"
    git tag v3
  )

  # =========================================================================
  # Step 2: Create test extension repo using subtree add from source at v1
  # =========================================================================
  mkdir "$TEST_REPO"
  (
    cd "$TEST_REPO"
    git init

    # Copy template files and commit
    rsync -a --exclude='.DS_Store' "$TEST_TEMPLATE"/ ./
    git add .
    git commit -m "Initial extension files"

    # Add pgxntool via git subtree (forces subtree path, not rsync)
    git subtree add -P pgxntool --squash "$source_repo" v1

    # Run setup.sh to generate Makefile, .gitignore, etc.
    ./pgxntool/setup.sh

    # Fix META.in.json placeholders
    sed -i.bak -e 's/DISTRIBUTION_NAME/pgxntool-test/g' -e 's/EXTENSION_NAME/pgxntool-test/g' META.in.json
    rm -f META.in.json.bak

    # Regenerate META.json from updated META.in.json (make auto-rebuilds this
    # as an included file prerequisite, which would dirty the tree during sync)
    ./pgxntool/build_meta.sh META.in.json META.json

    # Ignore generated files so repo stays clean
    echo "*.html" >> .gitignore
    echo "meta.mk" >> .gitignore

    # Commit everything
    git add .
    git commit -m "Add pgxntool setup"
  )

  # Store source repo path in env file for test access
  echo "export SOURCE_REPO=\"$source_repo\"" >> "$TEST_DIR/.env"

  # Wait for filesystem timestamps to settle, then refresh git index cache.
  # git subtree pull internally uses 'git diff-index --quiet HEAD' which can
  # fail due to filesystem timestamp granularity causing stale index entries.
  (cd "$TEST_REPO" && sleep 1 && git update-index --refresh)
}

setup() {
  load_test_env "pgxntool-sync"
  cd "$TEST_REPO"
}

# =============================================================================
# Tests
# =============================================================================

@test "pgxntool subtree was added correctly" {
  assert_file_exists "pgxntool/base.mk"

  # Verify git log shows the subtree merge commit
  run git log --oneline -- pgxntool/
  assert_success
  assert_contains "$output" "pgxntool"
}

@test ".gitignore does not have v2 marker before sync" {
  ! grep -q "pgxntool-sync-test-marker" .gitignore
}

@test "make pgxntool-sync pulls new changes" {
  run make pgxntool-sync-test "pgxntool-sync-test=$SOURCE_REPO v2"
  assert_success
  assert_contains "$output" "Checking setup files for updates"
}

@test ".gitignore was auto-updated after sync" {
  grep -q "pgxntool-sync-test-marker" .gitignore
}

@test "pgxntool files reflect v2 after sync" {
  grep -q "pgxntool-sync-test-marker" pgxntool/_.gitignore
}

@test "sync created a merge commit" {
  run git log --oneline -1
  assert_success
  assert_contains "$output" "Pull pgxntool from"
}

# Verify every predefined make target passes the right <repo> <ref> to the
# script.
#
# `make -n` is dry-run mode: it fully evaluates the makefile (expanding
# variables, the automatic $@, and the pgxntool-sync-% pattern rule) and prints
# the exact commands it *would* run, but executes nothing. So we can check what
# each target resolves to -- offline, with no git subtree pull -- and catch a
# target wired to the wrong repo/ref. This is the class of bug that broke the
# default originally (it resolved to a URL/owner that no longer works).
# It does NOT prove the command succeeds; the direct-script test below covers
# that a sync actually runs.
@test "make sync targets wire to the expected repo and ref" {
  local upstream="https://github.com/Postgres-Extensions/pgxntool.git"

  # Each target prints exactly one command; match it in full. The bare target
  # passes no args (the script supplies the default repo/ref itself).
  run make -n pgxntool-sync
  assert_success
  [ "$output" = "pgxntool/pgxntool-sync.sh" ]

  run make -n pgxntool-sync-master
  assert_success
  [ "$output" = "pgxntool/pgxntool-sync.sh $upstream master" ]

  run make -n pgxntool-sync-local
  assert_success
  [ "$output" = "pgxntool/pgxntool-sync.sh ../pgxntool release" ]

  run make -n pgxntool-sync-local-master
  assert_success
  [ "$output" = "pgxntool/pgxntool-sync.sh ../pgxntool master" ]

  # The script's built-in default (used by bare `pgxntool-sync`) must be the
  # canonical repo on the release tag, not the old decibel remote.
  grep -q "Postgres-Extensions/pgxntool" pgxntool/pgxntool-sync.sh
  ! grep -q "decibel/pgxntool" pgxntool/pgxntool-sync.sh
}

# The script must work without make, since that is the whole point of extracting
# it from the Makefile recipe. This syncs v2 -> v3 by invoking the script
# directly (the make tests above already advanced the repo to v2).
@test "pgxntool-sync.sh can be run directly, without make" {
  # A sync leaves the reconciled setup files modified but uncommitted, and
  # git subtree pull refuses to run against a dirty tree. Committing between
  # syncs is the normal workflow, so commit the v2 result before syncing v3.
  git add -A
  git commit -q -m "Commit v2 sync result"

  run ./pgxntool/pgxntool-sync.sh "$SOURCE_REPO" v3
  assert_success
  assert_contains "$output" "Checking setup files for updates"

  grep -q "pgxntool-sync-test-marker-v3" .gitignore
  grep -q "pgxntool-sync-test-marker-v3" pgxntool/_.gitignore
}

# vi: expandtab sw=2 ts=2
