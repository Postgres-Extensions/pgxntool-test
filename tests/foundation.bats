#!/usr/bin/env bats

# Test: Foundation - Create base TEST_REPO
#
# This is the foundation test that creates the minimal usable TEST_REPO environment.
# It combines repository cloning and initial setup (setup.sh).
#
# All other tests depend on this foundation:
# - Sequential tests (01-meta, 02-dist, 03-setup-final) build on this base
# - Independent tests (test-doc, test-make-results) copy this base to their own environment
#
# The foundation is created once in .envs/foundation/ and then copied to other
# test environments for speed. Run `make foundation` to rebuild from scratch.

load helpers

setup_file() {
  debug 1 ">>> ENTER setup_file: foundation (PID=$$)"

  # Set TOPDIR
  cd "$BATS_TEST_DIRNAME/.."
  export TOPDIR=$(pwd)

  # Foundation always runs in "foundation" environment
  load_test_env "foundation" || return 1

  # Create state directory if needed
  mkdir -p "$TEST_DIR/.bats-state"

  debug 1 "<<< EXIT setup_file: foundation (PID=$$)"
}

setup() {
  load_test_env "foundation"

  # Only cd to TEST_REPO if it exists
  # Tests 1-2 create the directory, so they don't need to be in it
  # Tests 3+ need to be in TEST_REPO
  if [ -d "$TEST_REPO" ]; then
    cd "$TEST_REPO"
  fi
}

teardown_file() {
  debug 1 ">>> ENTER teardown_file: foundation (PID=$$)"
  mark_test_complete "foundation"
  debug 1 "<<< EXIT teardown_file: foundation (PID=$$)"
}

# ============================================================================
# CLONE TESTS - Create and configure repository
# ============================================================================

@test "test environment variables are set" {
  [ -n "$TEST_TEMPLATE" ]
  [ -n "$TEST_REPO" ]
  [ -n "$PGXNREPO" ]
  [ -n "$PGXNBRANCH" ]
}

@test "can create TEST_REPO directory" {
  # Skip if already exists (prerequisite already met)
  if [ -d "$TEST_REPO" ]; then
    skip "TEST_REPO already exists"
  fi

  mkdir "$TEST_REPO"
  [ -d "$TEST_REPO" ]
}

@test "template repository clones successfully" {
  # Skip if already cloned
  if [ -d "$TEST_REPO/.git" ]; then
    skip "TEST_REPO already cloned"
  fi

  # Clone the template
  run git clone "$TEST_TEMPLATE" "$TEST_REPO"
  assert_success
  [ -d "$TEST_REPO/.git" ]
}

@test "fake git remote is configured" {
  cd "$TEST_REPO"

  # Skip if already configured
  if git remote get-url origin 2>/dev/null | grep -q "fake_repo"; then
    skip "Fake remote already configured"
  fi

  # Create fake remote
  git init --bare ../fake_repo >/dev/null 2>&1

  # Replace origin with fake
  git remote remove origin
  git remote add origin ../fake_repo

  # Verify
  local origin_url=$(git remote get-url origin)
  assert_contains "$origin_url" "fake_repo"
}

@test "current branch pushes to fake remote" {
  cd "$TEST_REPO"

  # Skip if already pushed
  if git branch -r | grep -q "origin/"; then
    skip "Already pushed to fake remote"
  fi

  local current_branch=$(git symbolic-ref --short HEAD)
  run git push --set-upstream origin "$current_branch"
  assert_success

  # Verify branch exists on remote
  git branch -r | grep -q "origin/$current_branch"

  # Verify repository is in consistent state after push
  run git status
  assert_success
}

@test "pgxntool is added to repository" {
  cd "$TEST_REPO"

  # Skip if pgxntool already exists
  if [ -d "pgxntool" ]; then
    skip "pgxntool directory already exists"
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
      mkdir pgxntool
      rsync -a "$PGXNREPO/" pgxntool/ --exclude=.git

      # Commit all files at once
      git add --all
      git commit -m "Committing unsaved pgxntool changes"
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
  cd "$TEST_REPO"

  # This test verifies the rsync logic for dirty local pgxntool repos
  # Skip if pgxntool repo is not local or not dirty
  if ! echo "$PGXNREPO" | grep -q "^\.\./"; then
    if ! echo "$PGXNREPO" | grep -q "^/"; then
      skip "PGXNREPO is not a local path"
    fi
  fi

  if [ ! -d "$PGXNREPO" ]; then
    skip "PGXNREPO directory does not exist"
  fi

  # Check if it's dirty and on the right branch
  local is_dirty=$(cd "$PGXNREPO" && git status --porcelain)
  local current_branch=$(cd "$PGXNREPO" && git symbolic-ref --short HEAD)

  if [ -z "$is_dirty" ]; then
    skip "PGXNREPO is not dirty - rsync path not needed"
  fi

  if [ "$current_branch" != "$PGXNBRANCH" ]; then
    skip "PGXNREPO is on $current_branch, not $PGXNBRANCH"
  fi

  # If we got here, rsync should have been used
  # Look for the commit message about uncommitted changes
  run git log --oneline -1 --grep="Committing unsaved pgxntool changes"
  assert_success
}

@test "TEST_REPO is a valid git repository after clone" {
  cd "$TEST_REPO"

  # Final validation of clone phase
  [ -d ".git" ]
  run git status
  assert_success
}

# ============================================================================
# SETUP TESTS - Run setup.sh and configure repository
# ============================================================================

@test "META.json does not exist before setup" {
  cd "$TEST_REPO"

  # Skip if Makefile exists (setup already ran)
  if [ -f "Makefile" ]; then
    skip "setup.sh already completed"
  fi

  # META.json should NOT exist yet
  [ ! -f "META.json" ]
}

@test "setup.sh fails on dirty repository" {
  cd "$TEST_REPO"

  # Skip if Makefile already exists (setup already ran)
  if [ -f "Makefile" ]; then
    skip "setup.sh already completed"
  fi

  # Make repo dirty
  touch garbage
  git add garbage

  # setup.sh should fail
  run pgxntool/setup.sh
  [ "$status" -ne 0 ]

  # Clean up
  git reset HEAD garbage
  rm garbage
}

@test "setup.sh runs successfully on clean repository" {
  cd "$TEST_REPO"

  # Skip if Makefile already exists
  if [ -f "Makefile" ]; then
    skip "Makefile already exists"
  fi

  # Repository should be clean
  run git status --porcelain
  [ -z "$output" ]

  # Run setup.sh
  run pgxntool/setup.sh
  assert_success
}

@test "setup.sh creates Makefile" {
  cd "$TEST_REPO"

  assert_file_exists "Makefile"

  # Should include pgxntool/base.mk
  grep -q "include pgxntool/base.mk" Makefile
}

@test "setup.sh creates .gitignore" {
  cd "$TEST_REPO"

  # Check if .gitignore exists (either in . or ..)
  [ -f ".gitignore" ] || [ -f "../.gitignore" ]
}

@test "META.in.json still exists after setup" {
  cd "$TEST_REPO"

  # setup.sh should not remove META.in.json
  assert_file_exists "META.in.json"
}

@test "setup.sh generates META.json from META.in.json" {
  cd "$TEST_REPO"

  # META.json should be created by setup.sh (even with placeholders)
  # It will be regenerated with correct values after we fix META.in.json
  assert_file_exists "META.json"
}

@test "setup.sh creates meta.mk" {
  cd "$TEST_REPO"

  assert_file_exists "meta.mk"
}

@test "setup.sh creates test directory structure" {
  cd "$TEST_REPO"

  assert_dir_exists "test"
  assert_file_exists "test/deps.sql"
}

@test "setup.sh changes can be committed" {
  cd "$TEST_REPO"

  # Skip if already committed (check for modified/staged files, not untracked)
  local changes=$(git status --porcelain | grep -v '^??')
  if [ -z "$changes" ]; then
    skip "No changes to commit"
  fi

  # Commit the changes
  run git commit -am "Test setup"
  assert_success

  # Verify no tracked changes remain (ignore untracked files)
  local remaining=$(git status --porcelain | grep -v '^??')
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
  cd "$TEST_REPO"

  # Skip if already replaced
  if ! grep -q "DISTRIBUTION_NAME\|EXTENSION_NAME" META.in.json; then
    skip "Placeholders already replaced"
  fi

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
  cd "$TEST_REPO"

  # Skip if no changes
  if git diff --quiet META.in.json 2>/dev/null; then
    skip "No META.in.json changes to commit"
  fi

  git add META.in.json
  git commit -m "Configure extension name to pgxntool-test"
}

@test "make automatically regenerates META.json from META.in.json" {
  cd "$TEST_REPO"

  # Skip if META.json already has correct name
  if grep -q "pgxntool-test" META.json && ! grep -q "DISTRIBUTION_NAME" META.json; then
    skip "META.json already correct"
  fi

  # Run make - it will automatically regenerate META.json because META.in.json changed
  # (META.json has META.in.json as a dependency in the Makefile)
  run make
  assert_success

  # Verify META.json was automatically regenerated
  assert_file_exists "META.json"
}

@test "META.json contains correct values" {
  cd "$TEST_REPO"

  # Verify META.json has the correct extension name, not placeholders
  grep -q "pgxntool-test" META.json
  ! grep -q "DISTRIBUTION_NAME" META.json
  ! grep -q "EXTENSION_NAME" META.json
}

@test "commit auto-generated META.json" {
  cd "$TEST_REPO"

  # Skip if no changes
  if git diff --quiet META.json 2>/dev/null; then
    skip "No META.json changes to commit"
  fi

  git add META.json
  git commit -m "Update META.json (auto-generated from META.in.json)"
}

@test "repository is in valid state after setup" {
  cd "$TEST_REPO"

  # Final validation
  assert_file_exists "Makefile"
  assert_file_exists "META.json"
  assert_dir_exists "pgxntool"

  # Should be able to run make
  run make --version
  assert_success
}

@test "template files are copied to root" {
  cd "$TEST_REPO"

  # Skip if already copied
  if [ -f "TEST_DOC.asc" ]; then
    skip "Template files already copied"
  fi

  # Copy template files from t/ to root
  [ -d "t" ] || skip "No t/ directory"

  cp -R t/* .

  # Verify files exist
  [ -f "TEST_DOC.asc" ] || [ -d "doc" ] || [ -d "sql" ]
}

# CRITICAL: This test makes TEST_REPO behave like a real extension repository.
#
# In real extensions using pgxntool, source files (doc/, sql/, test/input/)
# are tracked in git. Our test template has them in t/ for historical reasons,
# but we copy them to root here.
#
# WHY THIS MATTERS: `make dist` uses `git archive` which only packages tracked
# files. Without committing these files, distributions would be empty.
@test "template files are committed" {
  cd "$TEST_REPO"

  # Check if template files need to be committed
  local files_to_add=""
  if [ -f "TEST_DOC.asc" ] && git status --porcelain TEST_DOC.asc | grep -q "^??"; then
    files_to_add="$files_to_add TEST_DOC.asc"
  fi
  if [ -d "doc" ] && git status --porcelain doc/ | grep -q "^??"; then
    files_to_add="$files_to_add doc/"
  fi
  if [ -d "sql" ] && git status --porcelain sql/ | grep -q "^??"; then
    files_to_add="$files_to_add sql/"
  fi
  if [ -d "test/input" ] && git status --porcelain test/input/ | grep -q "^??"; then
    files_to_add="$files_to_add test/input/"
  fi

  if [ -z "$files_to_add" ]; then
    skip "No untracked template files to commit"
  fi

  # Add template files
  git add $files_to_add
  run git commit -m "Add extension template files

These files would normally be part of the extension repository.
They're copied from t/ to root as part of extension setup."
  assert_success

  # Verify commit succeeded (no untracked template files remain)
  local untracked=$(git status --porcelain | grep "^?? " | grep -E "(TEST_DOC|doc/|sql/|test/input/)" || echo "")
  [ -z "$untracked" ]
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
@test ".gitignore includes generated documentation" {
  cd "$TEST_REPO"

  # Check if already added
  if grep -q "^\*.html$" .gitignore; then
    skip "*.html already in .gitignore"
  fi

  echo "*.html" >> .gitignore
  git add .gitignore
  git commit -m "Ignore generated HTML documentation"
}

@test ".gitattributes is committed for export-ignore support" {
  cd "$TEST_REPO"

  # Skip if already committed
  if git ls-files --error-unmatch .gitattributes >/dev/null 2>&1; then
    skip ".gitattributes already committed"
  fi

  # Create .gitattributes if it doesn't exist (template has it but it's not tracked)
  if [ ! -f ".gitattributes" ]; then
    cat > .gitattributes <<EOF
.gitattributes export-ignore
.claude/ export-ignore
EOF
  fi

  # Commit .gitattributes so export-ignore works in make dist
  git add .gitattributes
  git commit -m "Add .gitattributes for export-ignore support"
}


# vi: expandtab sw=2 ts=2
