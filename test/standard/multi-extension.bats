#!/usr/bin/env bats

# Test: Multi-Extension Support
#
# Tests that pgxntool correctly handles projects with multiple extensions:
# - Each extension has its own .control file with default_version
# - Each extension has its own base SQL file (sql/<ext>.sql)
# - make generates versioned SQL files for each extension (sql/<ext>--<version>.sql)
# - meta.mk contains correct PGXN and PGXNVERSION from META.json
# - control.mk contains correct EXTENSION_<name>_VERSION for each extension
#
# This test uses the template-multi-extension/ template which contains:
# - ext_alpha.control (default_version = '1.0.0')
# - ext_beta.control (default_version = '2.5.0')
# - sql/ext_alpha.sql
# - sql/ext_beta.sql
# - META.in.json (with provides for both extensions)
#
# IMPORTANT: This test does NOT use ensure_foundation() because it needs a
# different template than the default. Instead, it builds its own repository
# from scratch using the same patterns as foundation.bats.

load ../lib/helpers

setup_file() {
  # Set TOPDIR to repository root
  setup_topdir

  # Check if multi-extension environment exists and clean it
  local env_dir="$TOPDIR/test/.envs/multi-extension"
  if [ -d "$env_dir" ]; then
    debug 2 "multi-extension environment exists, cleaning for fresh run"
    clean_env "multi-extension" || return 1
  fi

  # Load test environment (creates .envs/multi-extension/)
  load_test_env "multi-extension" || return 1

  # Override TEST_TEMPLATE to use multi-extension template
  # This MUST be set after load_test_env since load_test_env calls setup_pgxntool_vars
  # which sets TEST_TEMPLATE to the default
  export TEST_TEMPLATE="${TOPDIR}/template-multi-extension"

  # Create state directory
  mkdir -p "$TEST_DIR/.bats-state"
}

setup() {
  load_test_env "multi-extension"
  # Override TEST_TEMPLATE for each test
  export TEST_TEMPLATE="${TOPDIR}/template-multi-extension"

  # Early tests run before TEST_REPO exists, later tests run inside it
  if [ -d "$TEST_REPO" ]; then
    cd "$TEST_REPO"
  else
    cd "$TEST_DIR"
  fi
}

# ============================================================================
# REPOSITORY SETUP - Create test repo from multi-extension template
# ============================================================================

@test "multi-extension template exists" {
  assert_file_exists "$TEST_TEMPLATE/ext_alpha.control"
  assert_file_exists "$TEST_TEMPLATE/ext_beta.control"
  assert_file_exists "$TEST_TEMPLATE/META.in.json"
  assert_file_exists "$TEST_TEMPLATE/sql/ext_alpha.sql"
  assert_file_exists "$TEST_TEMPLATE/sql/ext_beta.sql"
}

@test "can create multi-extension test repository" {
  # Should not exist yet - if it does, environment cleanup failed
  [ ! -d "$TEST_REPO" ]

  run mkdir "$TEST_REPO"
  assert_success

  [ -d "$TEST_REPO" ]
}

@test "git repository is initialized" {
  cd "$TEST_REPO"

  # Should not be initialized yet
  [ ! -d ".git" ]

  run git init
  assert_success

  [ -d ".git" ]
}

@test "template files are copied to repository" {
  cd "$TEST_REPO"

  # Copy multi-extension template files (exclude .DS_Store)
  run rsync -a --exclude='.DS_Store' "$TEST_TEMPLATE"/ .
  assert_success

  # Verify files were copied
  assert_file_exists "ext_alpha.control"
  assert_file_exists "ext_beta.control"
  assert_file_exists "META.in.json"
  assert_file_exists "sql/ext_alpha.sql"
  assert_file_exists "sql/ext_beta.sql"
}

@test "template files are committed" {
  cd "$TEST_REPO"

  run git add .
  assert_success

  run git commit -m "Initial multi-extension project"
  assert_success
}

@test "fake git remote is configured" {
  cd "$TEST_REPO"

  # Create fake remote (bare repository to accept pushes)
  run git init --bare "${TEST_DIR}/fake_repo"
  assert_success

  run git remote add origin "${TEST_DIR}/fake_repo"
  assert_success

  local current_branch=$(git symbolic-ref --short HEAD)
  run git push --set-upstream origin "$current_branch"
  assert_success
}

# ============================================================================
# PGXNTOOL INTEGRATION - Add pgxntool to the repository
# ============================================================================

@test "pgxntool is added to repository" {
  cd "$TEST_REPO"

  # Should not exist yet
  [ ! -d "pgxntool" ]

  # Wait for filesystem timestamp granularity and refresh index
  sleep 1
  run git update-index --refresh
  assert_success

  # Check if pgxntool repo is dirty
  local source_is_dirty=0
  if [ -d "$PGXNREPO/.git" ]; then
    if [ -n "$(cd "$PGXNREPO" && git status --porcelain)" ]; then
      source_is_dirty=1
      local current_branch=$(cd "$PGXNREPO" && git symbolic-ref --short HEAD)

      if [ "$current_branch" != "$PGXNBRANCH" ]; then
        error "Source repo is dirty but on wrong branch ($current_branch, expected $PGXNBRANCH)"
      fi

      out "Source repo is dirty and on correct branch, using rsync instead of git subtree"

      run mkdir pgxntool
      assert_success

      run rsync -a "$PGXNREPO/" pgxntool/ --exclude=.git
      assert_success

      run git add --all
      assert_success

      run git commit -m "Committing unsaved pgxntool changes"
      assert_success
    fi
  fi

  # If source wasn't dirty, use git subtree
  if [ $source_is_dirty -eq 0 ]; then
    run git subtree add -P pgxntool --squash "$PGXNREPO" "$PGXNBRANCH"
    assert_success
  fi

  [ -d "pgxntool" ]
  assert_file_exists "pgxntool/base.mk"
}

@test "setup.sh runs successfully" {
  cd "$TEST_REPO"

  run git status --porcelain
  assert_success
  [ -z "$output" ]

  run pgxntool/setup.sh
  assert_success
}

@test "setup.sh creates Makefile" {
  cd "$TEST_REPO"

  assert_file_exists "Makefile"
  grep -q "include pgxntool/base.mk" Makefile
}

@test "setup changes can be committed" {
  cd "$TEST_REPO"

  run git status --porcelain
  assert_success
  local changes=$(echo "$output" | grep -v '^??')
  [ -n "$changes" ]

  run git commit -am "Add pgxntool setup"
  assert_success
}

# ============================================================================
# META.MK VALIDATION - Check PGXN/PGXNVERSION are correct
# ============================================================================

@test "meta.mk is created" {
  cd "$TEST_REPO"

  assert_file_exists "meta.mk"
}

@test "meta.mk contains correct PGXN" {
  cd "$TEST_REPO"

  # META.in.json has name: "multi-extension-test"
  run grep -E "^PGXN[[:space:]]*:=[[:space:]]*multi-extension-test" meta.mk
  assert_success
}

@test "meta.mk contains correct PGXNVERSION" {
  cd "$TEST_REPO"

  # META.in.json has version: "1.0.0"
  run grep -E "^PGXNVERSION[[:space:]]*:=[[:space:]]*1\.0\.0" meta.mk
  assert_success
}

# ============================================================================
# CONTROL.MK VALIDATION - Check EXTENSION versions are correct
# ============================================================================

@test "control.mk is created" {
  cd "$TEST_REPO"

  assert_file_exists "control.mk"
}

@test "control.mk contains EXTENSION_ext_alpha_VERSION" {
  cd "$TEST_REPO"

  # ext_alpha.control has default_version = '1.0.0'
  run grep -E "^EXTENSION_ext_alpha_VERSION[[:space:]]*:=[[:space:]]*1\.0\.0" control.mk
  assert_success
}

@test "control.mk contains EXTENSION_ext_beta_VERSION" {
  cd "$TEST_REPO"

  # ext_beta.control has default_version = '2.5.0'
  run grep -E "^EXTENSION_ext_beta_VERSION[[:space:]]*:=[[:space:]]*2\.5\.0" control.mk
  assert_success
}

@test "control.mk lists both extensions in EXTENSIONS" {
  cd "$TEST_REPO"

  run grep "EXTENSIONS += ext_alpha" control.mk
  assert_success

  run grep "EXTENSIONS += ext_beta" control.mk
  assert_success
}

# ============================================================================
# VERSIONED SQL FILE GENERATION - Test that make creates correct files
# ============================================================================

@test "versioned SQL files do not exist before make" {
  cd "$TEST_REPO"

  [ ! -f "sql/ext_alpha--1.0.0.sql" ]
  [ ! -f "sql/ext_beta--2.5.0.sql" ]
}

@test "make generates versioned SQL files" {
  cd "$TEST_REPO"

  # Use 'make all' explicitly because the default target in base.mk is META.json
  # (due to it being the first target defined). This is a quirk of base.mk.
  run make all
  assert_success
}

@test "sql/ext_alpha--1.0.0.sql is generated" {
  cd "$TEST_REPO"

  assert_file_exists "sql/ext_alpha--1.0.0.sql"
}

@test "sql/ext_beta--2.5.0.sql is generated" {
  cd "$TEST_REPO"

  assert_file_exists "sql/ext_beta--2.5.0.sql"
}

@test "versioned SQL files contain DO NOT EDIT header" {
  cd "$TEST_REPO"

  run grep -q "DO NOT EDIT" "sql/ext_alpha--1.0.0.sql"
  assert_success

  run grep -q "DO NOT EDIT" "sql/ext_beta--2.5.0.sql"
  assert_success
}

@test "versioned SQL files contain original SQL content" {
  cd "$TEST_REPO"

  # ext_alpha.sql has ext_alpha_add function
  run grep -q "ext_alpha_add" "sql/ext_alpha--1.0.0.sql"
  assert_success

  # ext_beta.sql has ext_beta_multiply function
  run grep -q "ext_beta_multiply" "sql/ext_beta--2.5.0.sql"
  assert_success
}

@test "META.json is generated with correct content" {
  cd "$TEST_REPO"

  assert_file_exists "META.json"

  # Should have correct name and version
  run grep -q '"name".*"multi-extension-test"' META.json
  assert_success

  run grep -q '"version".*"1.0.0"' META.json
  assert_success

  # Should have both extensions in provides
  run grep -q '"ext_alpha"' META.json
  assert_success

  run grep -q '"ext_beta"' META.json
  assert_success
}

# vi: expandtab sw=2 ts=2
