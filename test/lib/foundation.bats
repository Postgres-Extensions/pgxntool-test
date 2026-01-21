#!/usr/bin/env bats

# IMPORTANT: This file is both a test AND a library
#
# foundation.bats is an unusual file: it's technically a BATS test (it can be run
# directly with `bats foundation.bats`), but it's really more of a library that
# creates the base TEST_REPO environment that all other tests depend on.
#
# Because of this dual nature, it lives in test/lib/ alongside other library files
# (helpers.bash, assertions.bash, etc.), but it's also executed as part of `make test-setup`.
#
# Why this matters:
# - If foundation.bats fails when run inside another test (via ensure_foundation()),
#   we don't get useful BATS output - the failure is hidden in the test that called it.
# - Therefore, foundation.bats MUST be run directly as part of `make test-setup` BEFORE
#   any other tests run, ensuring we get clear error messages if foundation setup fails.
#
# Usage:
# - Direct execution: `make foundation` or `bats test/lib/foundation.bats`
# - Automatic execution: `make test-setup` (runs foundation before other tests)
# - Called by tests: `ensure_foundation()` in helpers.bash (see helpers.bash for details)
#   Note: `ensure_foundation()` only runs foundation.bats if it doesn't already exist.
#   If foundation is already complete, it just copies the existing foundation to the target.
#
# Test: Foundation - Create base TEST_REPO
#
# This is the foundation test that creates the minimal usable TEST_REPO environment.
# It combines repository cloning and initial setup (setup.sh).
#
# All other tests depend on this foundation:
# - Sequential tests (01-meta, 02-dist, 03-setup-final) build on this base
# - Independent tests (doc, make-results) copy this base to their own environment
#
# The foundation is created once in .envs/foundation/ and then copied to other
# test environments for speed. Run `make foundation` to rebuild from scratch.

load helpers

setup_file() {
  debug 1 ">>> ENTER setup_file: foundation (PID=$$)"

  # Set TOPDIR to repository root
  setup_topdir

  # Check if foundation already exists and needs cleaning
  local foundation_dir="$TOPDIR/.envs/foundation"
  local foundation_complete="$foundation_dir/.bats-state/.foundation-complete"

  if [ -f "$foundation_complete" ]; then
    debug 2 "Foundation already exists, cleaning for fresh rebuild"
    # Foundation exists - clean it to start fresh
    # This matches sequential test behavior where tests are self-healing
    clean_env "foundation" || return 1
  fi

  # Foundation always runs in "foundation" environment
  load_test_env "foundation" || return 1

  # Create state directory if needed
  mkdir -p "$TEST_DIR/.bats-state"

  debug 1 "<<< EXIT setup_file: foundation (PID=$$)"
}

setup() {
  load_test_env "foundation"

  # Early tests (1-2) run before TEST_REPO exists, so cd to TEST_DIR
  # Later tests (3+) run inside TEST_REPO after it's created
  if [ -d "$TEST_REPO" ]; then
    assert_cd "$TEST_REPO"
  else
    assert_cd "$TEST_DIR"
  fi
}

teardown_file() {
  debug 1 ">>> ENTER teardown_file: foundation (PID=$$)"
  mark_test_complete "foundation"

  # Create foundation-complete marker for ensure_foundation() to find
  # This is a different marker than .complete-foundation because:
  # - .complete-foundation is for sequential test tracking
  # - .foundation-complete is for ensure_foundation() to check if foundation is ready
  local state_dir="$TEST_DIR/.bats-state"
  date '+%Y-%m-%d %H:%M:%S.%N %z' > "$state_dir/.foundation-complete"

  debug 1 "<<< EXIT teardown_file: foundation (PID=$$)"
}

# ============================================================================
# REPOSITORY INITIALIZATION - Create fresh git repo with extension files
# ============================================================================
#
# This section creates a realistic extension repository from scratch:
# 1. Create directory
# 2. git init (fresh repository)
# 3. Copy extension files from template/t/ to root
# 4. Commit extension files (realistic: extension exists before pgxntool)
# 5. Add fake remote (for testing git operations)
# 6. Push to fake remote
#
# This matches the real-world scenario: "I have an existing extension,
# now I want to add pgxntool to it."

@test "test environment variables are set" {
  [ -n "$TEST_TEMPLATE" ]
  [ -n "$TEST_REPO" ]
  [ -n "$PGXNREPO" ]
  [ -n "$PGXNBRANCH" ]
}

@test "can create TEST_REPO directory" {
  # Should not exist yet - if it does, environment cleanup failed
  [ ! -d "$TEST_REPO" ]

  mkdir "$TEST_REPO"
  [ -d "$TEST_REPO" ]
}

@test "git repository is initialized" {
  # Should not be initialized yet - if it is, previous test failed to clean up
  [ ! -d "$TEST_REPO/.git" ]

  run git init
  assert_success
  [ -d "$TEST_REPO/.git" ]
}

@test "template files are copied to root" {
  # Copy extension source files from template directory to root
  # Exclude .DS_Store (macOS system file)
  rsync -a --exclude='.DS_Store' "$TEST_TEMPLATE"/ .
}

# CRITICAL: This test makes TEST_REPO behave like a real extension repository.
#
# In real extensions using pgxntool, source files (doc/, sql/, test/input/)
# are tracked in git. We commit them FIRST, before adding pgxntool, to match
# the realistic scenario: "I have an existing extension, now I want to add pgxntool."
#
# WHY THIS MATTERS: `make dist` uses `git archive` which only packages tracked
# files. Without committing these files, distributions would be empty.
@test "template files are committed" {
  # Template files should be untracked at this point
  run git status --porcelain
  assert_success
  local untracked=$(echo "$output" | grep "^??" || echo)
  [ -n "$untracked" ]

  # Add all untracked files (extension source files)
  git add .
  run git commit -m "Initial extension files

These are the source files for the pgxntool-test extension.
In a real extension, these would already exist before adding pgxntool."
  assert_success

  # Verify commit succeeded (no untracked files remain)
  run git status --porcelain
  assert_success
  local remaining=$(echo "$output" | grep "^??" || echo)
  [ -z "$remaining" ]
}

# CRITICAL: Fake remote is REQUIRED for `make dist` to work.
#
# WHY: The `make dist` target (in pgxntool/base.mk) has prerequisite `tag`, which does:
#   1. git tag $(PGXNVERSION)          - Create tag for version
#   2. git push origin $(PGXNVERSION)  - Push tag to remote
#
# Without a remote named "origin", step 2 fails and `make dist` cannot complete.
#
# This matches real-world usage: extension repositories typically have git remotes
# configured (GitHub, GitLab, etc.). The fake remote simulates this realistic setup.
#
# ATTEMPTED: Removing these tests causes `make dist` to fail with:
#   "fatal: 'origin' does not appear to be a git repository"
@test "fake git remote is configured" {
  # Should not have origin remote yet
  run git remote get-url origin
  assert_failure

  # Create fake remote (bare repository to accept pushes)
  git init --bare ../fake_repo >/dev/null 2>&1

  # Add fake remote
  git remote add origin ../fake_repo

  # Verify
  local origin_url=$(git remote get-url origin)
  assert_contains "$origin_url" "fake_repo"
}

@test "current branch pushes to fake remote" {
  # Should not have any remote branches yet
  run git branch -r
  assert_success
  [ -z "$output" ]

  local current_branch=$(git symbolic-ref --short HEAD)
  run git push --set-upstream origin "$current_branch"
  assert_success

  # Verify branch exists on remote
  git branch -r | grep -q "origin/$current_branch"

  # Verify repository is in consistent state after push
  run git status
  assert_success
}

# ============================================================================
# PGXNTOOL INTEGRATION - Add pgxntool to the extension
# ============================================================================
#
# This section adds pgxntool to the existing extension repository:
# 1. Add pgxntool via git subtree (or rsync if source is dirty)
# 2. Validate pgxntool was added correctly
#
# This happens AFTER the extension files exist, matching the workflow:
# "I have an extension, now I'm adding the pgxntool framework to it."

@test "pgxntool is added to repository" {
  # pgxntool should not exist yet - if it does, environment cleanup failed
  [ ! -d "pgxntool" ]

  # CRITICAL: git subtree add requires a completely clean working tree.
  # The command internally uses 'git diff-index --quiet HEAD' which can fail due to
  # filesystem timestamp granularity causing stale index cache entries.
  # See: https://git-scm.com/docs/git-status#_background_refresh
  #
  # Solution: Wait for filesystem timestamps to settle, then refresh git index cache
  # to ensure accurate status reporting before git subtree add.

  sleep 1  # Wait for filesystem timestamp granularity

  run git update-index --refresh
  assert_success

  run git status --porcelain
  assert_success

  if [ -n "$output" ]; then
    out "ERROR: Working tree must be clean for git subtree add:"
    out "$output"
    run git diff-index HEAD  # Show what git subtree will see
    out "Files with index mismatches:"
    out "$output"
    error "Working tree has modifications, cannot proceed with git subtree add"
  fi

  # Validate prerequisites before attempting git subtree
  # 1. Check PGXNREPO is accessible and safe
  if [ ! -d "$PGXNREPO/.git" ]; then
    # Not a local directory - must be a valid remote URL

    # Explicitly reject dangerous protocols first
    if echo "$PGXNREPO" | grep -qiE '^(file://|ext::)'; then
      error "PGXNREPO uses unsafe protocol: $PGXNREPO"
    fi

    # Require valid git URL format (full URLs, not just 'git:' prefix)
    if ! echo "$PGXNREPO" | grep -qE '^(https://|http://|git://|ssh://|[a-zA-Z0-9._-]+@[a-zA-Z0-9._-]+:)'; then
      error "PGXNREPO is not a valid git URL: $PGXNREPO"
    fi
  fi

  # 2. For local repos, verify branch exists
  if [ -d "$PGXNREPO/.git" ]; then
    if ! (cd "$PGXNREPO" && git rev-parse --verify "$PGXNBRANCH" >/dev/null 2>&1); then
      error "Branch $PGXNBRANCH does not exist in $PGXNREPO"
    fi
  fi

  # 3. Check if source repo is dirty and use rsync if needed
  # This matches the legacy test behavior in tests/clone
  local source_is_dirty=0
  if [ -d "$PGXNREPO/.git" ]; then
    # SECURITY: rsync only works with local paths, never remote URLs
    if [[ "$PGXNREPO" == *://* ]]; then
      error "Cannot use rsync with remote URL: $PGXNREPO"
    fi

    if [ -n "$(cd "$PGXNREPO" && git status --porcelain)" ]; then
      source_is_dirty=1
      local current_branch=$(cd "$PGXNREPO" && git symbolic-ref --short HEAD)

      if [ "$current_branch" != "$PGXNBRANCH" ]; then
        error "Source repo is dirty but on wrong branch ($current_branch, expected $PGXNBRANCH)"
      fi

      out "Source repo is dirty and on correct branch, using rsync instead of git subtree"

      # Rsync files from source (git doesn't track empty directories, so do this first)
      run mkdir pgxntool
      assert_success

      run rsync -a "$PGXNREPO/" pgxntool/ --exclude=.git
      assert_success

      # Commit all files at once
      run git add --all
      assert_success

      run git commit -m "Committing unsaved pgxntool changes"
      assert_success
    fi
  fi

  # If source wasn't dirty, use git subtree
  if [ $source_is_dirty -eq 0 ]; then
    run git subtree add -P pgxntool --squash "$PGXNREPO" "$PGXNBRANCH"

    # Capture error output for debugging
    if [ "$status" -ne 0 ]; then
      out "ERROR: git subtree add failed with status $status"
      out "Output: $output"
    fi

    assert_success
  fi

  # Verify pgxntool was added either way
  [ -d "pgxntool" ]
  [ -f "pgxntool/base.mk" ]
}

@test "dirty pgxntool triggers rsync path (or skipped if clean)" {
  # This test verifies the rsync logic for dirty local pgxntool repos
  # Check if pgxntool repo is local
  if ! echo "$PGXNREPO" | grep -qE "^(\.\./|/)"; then
    # Not a local path - rsync not applicable
    # In this case, the test is not relevant, and there should be no rsync commit
    run git log --oneline --grep="Committing unsaved pgxntool changes"
    # If PGXNREPO is not local, rsync commit should NOT exist
    [ -z "$output" ]
    return 0
  fi

  if [ ! -d "$PGXNREPO" ]; then
    error "PGXNREPO should be a valid directory: $PGXNREPO"
  fi

  # Check if it's dirty and on the right branch
  local is_dirty=$(cd "$PGXNREPO" && git status --porcelain)
  local current_branch=$(cd "$PGXNREPO" && git symbolic-ref --short HEAD)

  if [ -z "$is_dirty" ]; then
    # PGXNREPO is clean - rsync should NOT have been used
    run git log --oneline --grep="Committing unsaved pgxntool changes"
    [ -z "$output" ]
  elif [ "$current_branch" != "$PGXNBRANCH" ]; then
    # PGXNREPO is dirty but on wrong branch - should have failed in previous test
    error "PGXNREPO is dirty but on wrong branch ($current_branch, expected $PGXNBRANCH)"
  else
    # PGXNREPO is dirty and on correct branch - rsync should have been used
    run git log --oneline -1 --grep="Committing unsaved pgxntool changes"
    assert_success
  fi
}

@test "TEST_REPO is a valid git repository after clone" {
  # Final validation of clone phase
  [ -d ".git" ]
  run git status
  assert_success
}

# ============================================================================
# SETUP TESTS - Run setup.sh and configure repository
# ============================================================================

@test "META.json does not exist before setup" {
  # Makefile should not exist yet - if it does, previous steps failed
  [ ! -f "Makefile" ]

  # META.json should NOT exist yet
  [ ! -f "META.json" ]
}

@test "setup.sh fails on dirty repository" {
  # Makefile should not exist yet
  [ ! -f "Makefile" ]

  # Make repo dirty
  touch garbage
  git add garbage

  # setup.sh should fail
  run pgxntool/setup.sh
  assert_failure

  # Clean up
  git reset HEAD garbage
  rm garbage
}

@test "setup.sh runs successfully on clean repository" {
  # Makefile should not exist yet
  [ ! -f "Makefile" ]

  # Repository should be clean
  run git status --porcelain
  assert_success
  [ -z "$output" ]

  # Run setup.sh
  run pgxntool/setup.sh
  assert_success
}

@test "setup.sh creates Makefile" {
  assert_file_exists "Makefile"

  # Should include pgxntool/base.mk
  grep -q "include pgxntool/base.mk" Makefile
}

@test "setup.sh creates .gitignore" {
  # Check if .gitignore exists (either in . or ..)
  [ -f ".gitignore" ] || [ -f "../.gitignore" ]
}

@test "META.in.json still exists after setup" {
  # setup.sh should not remove META.in.json
  assert_file_exists "META.in.json"
}

@test "setup.sh generates META.json from META.in.json" {
  # META.json should be created by setup.sh (even with placeholders)
  # It will be regenerated with correct values after we fix META.in.json
  assert_file_exists "META.json"
}

@test "setup.sh creates meta.mk" {
  assert_file_exists "meta.mk"
}

@test "setup.sh creates test directory structure" {
  assert_dir_exists "test"
  assert_file_exists "test/deps.sql"
}

@test "setup.sh changes can be committed" {
  # Should have modified/staged files at this point (from setup.sh)
  run git status --porcelain
  assert_success
  local changes=$(echo "$output" | grep -v '^??')
  [ -n "$changes" ]

  # Commit the changes
  run git commit -am "Test setup"
  assert_success

  # Verify no tracked changes remain (ignore untracked files)
  run git status --porcelain
  assert_success
  local remaining=$(echo "$output" | grep -v '^??')
  [ -z "$remaining" ]
}

# ============================================================================
# POST-SETUP CONFIGURATION - Fix META.in.json placeholders
# ============================================================================
#
# setup.sh creates META.in.json with placeholder "DISTRIBUTION_NAME". We must
# replace this placeholder with the actual extension name ("pgxntool-test")
# and commit it. The next make run will automatically regenerate META.json
# with correct values (META.json has META.in.json as a Makefile dependency).
#
# See pgxntool/build_meta.sh for details on the META.in.json → META.json pattern.

@test "replace placeholders in META.in.json" {
  # Should still have placeholders at this point
  grep -q "DISTRIBUTION_NAME\|EXTENSION_NAME" META.in.json

  # Replace both DISTRIBUTION_NAME and EXTENSION_NAME with pgxntool-test
  # Note: sed -i.bak + rm is the simplest portable solution (works on macOS BSD sed and GNU sed)
  # BSD sed requires an extension argument (can't do just -i), GNU sed allows it
  sed -i.bak -e 's/DISTRIBUTION_NAME/pgxntool-test/g' -e 's/EXTENSION_NAME/pgxntool-test/g' META.in.json
  rm -f META.in.json.bak

  # Verify replacement
  grep -q "pgxntool-test" META.in.json
  ! grep -q "DISTRIBUTION_NAME" META.in.json
  ! grep -q "EXTENSION_NAME" META.in.json
}

@test "commit META.in.json changes" {
  # Should have changes to META.in.json at this point
  run git diff --quiet META.in.json
  assert_failure

  git add META.in.json
  git commit -m "Configure extension name to pgxntool-test"
}

@test "make automatically regenerates META.json from META.in.json" {
  # META.json should still have placeholders at this point
  # (setup.sh creates it, but we haven't run make yet after updating META.in.json)
  grep -q "DISTRIBUTION_NAME\|EXTENSION_NAME" META.json

  # Run make - it will automatically regenerate META.json because META.in.json changed
  # (META.json has META.in.json as a dependency in the Makefile)
  run make
  assert_success

  # Verify META.json was automatically regenerated
  assert_file_exists "META.json"
}

@test "META.json contains correct values" {
  # Verify META.json has the correct extension name, not placeholders
  grep -q "pgxntool-test" META.json
  ! grep -q "DISTRIBUTION_NAME" META.json
  ! grep -q "EXTENSION_NAME" META.json
}

@test "commit auto-generated files" {
  # Should have changes to META.json at this point (from make regenerating it)
  run git diff --quiet META.json
  assert_failure

  # Add META.json and any auto-generated versioned SQL files
  # Versioned SQL files (sql/*--*.sql) are generated by make from sql/*.sql
  # and should be committed per our recommended workflow
  git add META.json
  git add sql/*--*.sql 2>/dev/null || true
  git commit -m "Update auto-generated files (META.json and versioned SQL)"
}

@test "repository is in valid state after setup" {
  # Final validation
  assert_file_exists "Makefile"
  assert_file_exists "META.json"
  assert_dir_exists "pgxntool"

  # Should be able to run make
  run make --version
  assert_success
}

# CRITICAL: This test enables `make dist` to work from a clean repository.
#
# `make dist` has a prerequisite on the `html` target, which builds documentation.
# But `make dist` also requires a clean git repository (no untracked files).
#
# Without this .gitignore entry:
# 1. `make dist` runs `make html`, creating .html files
# 2. `git status` shows .html files as untracked
# 3. `make dist` fails due to dirty repository
#
# By ignoring *.html, generated docs don't make the repo dirty, but are still
# included in distributions (git archive uses index + HEAD, not working tree).
#
# Similarly, meta.mk is a generated file (from META.in.json) that should be ignored.
@test ".gitignore includes generated documentation" {
  # Check what needs to be added (at least one should be missing)
  local needs_html=0
  local needs_meta_mk=0

  if ! grep -q "^\*.html$" .gitignore; then
    needs_html=1
  fi

  if ! grep -q "^meta\.mk$" .gitignore; then
    needs_meta_mk=1
  fi

  # At least one of these should be missing at this point
  [ $needs_html -eq 1 ] || [ $needs_meta_mk -eq 1 ]

  # Add what's needed
  if [ $needs_html -eq 1 ]; then
    echo "*.html" >> .gitignore
  fi

  if [ $needs_meta_mk -eq 1 ]; then
    echo "meta.mk" >> .gitignore
  fi

  git add .gitignore
  git commit -m "Ignore generated files (HTML documentation and meta.mk)"
}

# vi: expandtab sw=2 ts=2
