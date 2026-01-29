#!/usr/bin/env bats

# Test: update-setup-files.sh - 3-way merge of setup files after pgxntool sync
#
# This test validates the behavior of update-setup-files.sh, which handles
# merging changes to files that were initially copied by setup.sh:
# - _.gitignore -> .gitignore
# - test/deps.sql -> test/deps.sql
#
# The script does 3-way merge using git merge-file when both pgxntool
# and the user have modified the same file.

load ../lib/helpers
load ../lib/assertions

setup_file() {
  setup_topdir
  load_test_env "update-setup-files"
  ensure_foundation "$TEST_DIR"
  # Save initial commit for resetting between tests
  cd "$TEST_REPO"
  export INITIAL_COMMIT=$(git rev-parse HEAD)
}

setup() {
  load_test_env "update-setup-files"
  cd "$TEST_REPO"
  # Reset to initial state to prevent test pollution
  git reset --hard "$INITIAL_COMMIT" >/dev/null 2>&1
  git clean -fd >/dev/null 2>&1
}

# =============================================================================
# Scenario 1: pgxntool template unchanged - should skip
# =============================================================================

@test "skip update when pgxntool template unchanged" {
  local old_commit=$(git log -1 --format=%H -- pgxntool/)

  # User modifies their .gitignore
  echo "# user customization" >> .gitignore
  run git add .gitignore
  assert_success
  run git commit -m "User customization"
  assert_success

  # Run update (pgxntool unchanged)
  run pgxntool/update-setup-files.sh "$old_commit"
  assert_success

  # User's customization should still be there
  grep -q "# user customization" .gitignore
}

# =============================================================================
# Scenario 2: pgxntool changed, user unchanged - auto-update
# =============================================================================

@test "auto-update when user has not modified file" {
  # First, ensure .gitignore matches the template exactly
  # (Foundation may have modified it, e.g., added *.html for docs)
  cp pgxntool/_.gitignore .gitignore
  run git add .gitignore
  assert_success
  run git commit -m "Reset .gitignore to match template"
  assert_success

  local old_commit=$(git log -1 --format=%H -- pgxntool/)

  # Modify pgxntool template
  echo "# pgxntool new feature" >> pgxntool/_.gitignore
  run git add pgxntool/_.gitignore
  assert_success
  run git commit -m "Update pgxntool template"
  assert_success

  # Run update
  run pgxntool/update-setup-files.sh "$old_commit"
  assert_success

  # Verify file was auto-updated
  assert_contains "$output" "updated"
  grep -q "# pgxntool new feature" .gitignore
}

# =============================================================================
# Scenario 3: Both changed, clean merge possible
# =============================================================================

@test "clean merge when changes don't conflict" {
  local old_commit=$(git log -1 --format=%H -- pgxntool/)

  # User modifies END of their .gitignore
  echo "# user customization at end" >> .gitignore
  run git add .gitignore
  assert_success
  run git commit -m "User customization"
  assert_success

  # pgxntool modifies BEGINNING of template (different location)
  local tmp_file=$(mktemp)
  echo "# pgxntool new header" > "$tmp_file"
  cat pgxntool/_.gitignore >> "$tmp_file"
  mv "$tmp_file" pgxntool/_.gitignore
  run git add pgxntool/_.gitignore
  assert_success
  run git commit -m "Update pgxntool template"
  assert_success

  # Run update
  run pgxntool/update-setup-files.sh "$old_commit"
  assert_success

  # Verify both changes present (clean merge)
  assert_contains "$output" "merged cleanly"
  grep -q "# pgxntool new header" .gitignore
  grep -q "# user customization at end" .gitignore

  # No conflict markers
  ! grep -q "<<<<<<" .gitignore
}

# =============================================================================
# Scenario 4: Both changed, conflict
# =============================================================================

@test "conflict markers when changes overlap" {
  local old_commit=$(git log -1 --format=%H -- pgxntool/)

  # Get the first line to modify
  local first_line=$(head -1 .gitignore)

  # User modifies first line
  sed -i.bak "1s/.*/${first_line} - user modified/" .gitignore
  rm -f .gitignore.bak
  run git add .gitignore
  assert_success
  run git commit -m "User modifies first line"
  assert_success

  # pgxntool also modifies first line (differently)
  sed -i.bak "1s/.*/${first_line} - pgxntool modified/" pgxntool/_.gitignore
  rm -f pgxntool/_.gitignore.bak
  run git add pgxntool/_.gitignore
  assert_success
  run git commit -m "pgxntool modifies first line"
  assert_success

  # Run update
  run pgxntool/update-setup-files.sh "$old_commit"
  assert_success  # Script succeeds but reports conflicts

  # Verify conflict markers present
  assert_contains "$output" "CONFLICTS"
  grep -q "<<<<<<" .gitignore
  grep -q ">>>>>>" .gitignore
}

# =============================================================================
# Scenario 5: User file missing - create
# =============================================================================

@test "create file when user file missing" {
  local old_commit=$(git log -1 --format=%H -- pgxntool/)

  # Delete user's file
  rm .gitignore
  run git add .gitignore
  assert_success
  run git commit -m "Remove .gitignore"
  assert_success

  # Run update
  run pgxntool/update-setup-files.sh "$old_commit"
  assert_success

  # Verify file was created
  assert_contains "$output" "creating"
  [ -f .gitignore ]
}

# =============================================================================
# Symlink tests
# =============================================================================

@test "symlink verification passes for correct target" {
  local old_commit=$(git log -1 --format=%H -- pgxntool/)

  # Symlink should already exist and be correct from foundation
  [ -L test/pgxntool ]

  run pgxntool/update-setup-files.sh "$old_commit"
  assert_success

  # Should not report any symlink issues
  ! echo "$output" | grep -q "symlink points to"
}

@test "symlink with wrong target reports warning" {
  local old_commit=$(git log -1 --format=%H -- pgxntool/)

  # Change symlink to wrong target
  rm test/pgxntool
  ln -s /wrong/target test/pgxntool

  run pgxntool/update-setup-files.sh "$old_commit"
  assert_success  # Script doesn't fail, just warns

  # Should report wrong target
  assert_contains "$output" "symlink points to"
  assert_contains "$output" "wrong/target"
}

@test "missing symlink is created" {
  local old_commit=$(git log -1 --format=%H -- pgxntool/)

  # Remove symlink
  rm test/pgxntool

  run pgxntool/update-setup-files.sh "$old_commit"
  assert_success

  # Verify symlink was created
  assert_contains "$output" "creating symlink"
  [ -L test/pgxntool ]
}

# vi: expandtab sw=2 ts=2
