#!/usr/bin/env bats

# Test: .gitattributes export-ignore support
#
# Tests that .gitattributes is properly handled by make dist:
# - make dist fails with uncommitted .gitattributes (with helpful error)
# - make dist succeeds with committed .gitattributes
# - export-ignore directives in .gitattributes are respected in distributions

load ../lib/helpers
load ../lib/dist-files

setup_file() {
  # Set TOPDIR
  setup_topdir


  # Independent test - gets its own isolated environment with foundation TEST_REPO
  load_test_env "gitattributes"
  ensure_foundation "$TEST_DIR"
}

setup() {
  load_test_env "gitattributes"
  cd "$TEST_REPO"
  
  # Clean up test files from previous test runs
  rm -f test-export-ignore.txt
}

@test "make dist fails with uncommitted .gitattributes" {
  # Remove .gitattributes if it exists from previous test
  rm -f .gitattributes
  git rm --cached .gitattributes 2>/dev/null || true
  
  # Create .gitattributes but don't commit it
  cat > .gitattributes <<EOF
.gitattributes export-ignore
.claude/ export-ignore
EOF

  # Verify .gitattributes exists and is untracked
  [ -f ".gitattributes" ] || error ".gitattributes file was not created"
  ! git ls-files --error-unmatch .gitattributes >/dev/null 2>&1 || error ".gitattributes should be untracked"

  # make dist should fail because tag requires a clean repo
  # (tag runs before dist-only, so it fails first on untracked .gitattributes)
  run make dist
  assert_failure
  # tag fails with "Untracked changes!" when .gitattributes is untracked
  assert_contains "$output" "Untracked changes"
  # Verify .gitattributes is the untracked file
  assert_contains "$output" ".gitattributes"
}

@test "make dist succeeds with committed .gitattributes" {
  # Remove .gitattributes if it exists from previous test (both tracked and untracked)
  if git ls-files --error-unmatch .gitattributes >/dev/null 2>&1; then
    git rm --cached .gitattributes
    git commit -m "Remove .gitattributes for testing" || true
  fi
  rm -f .gitattributes
  
  # Create and commit .gitattributes
  cat > .gitattributes <<EOF
.gitattributes export-ignore
.claude/ export-ignore
EOF

  # Verify file exists before adding
  [ -f ".gitattributes" ] || error ".gitattributes file was not created"
  
  run git add .gitattributes
  assert_success
  
  # Commit the file
  run git commit -m "Add .gitattributes for export-ignore support"
  # If commit fails because there's nothing to commit (already committed), that's OK
  # But we need to ensure the file is actually committed, not just staged
  if [ "$status" -ne 0 ]; then
    # Commit failed - check if file is already committed
    run git log -1 --oneline -- .gitattributes
    if [ "$status" -ne 0 ]; then
      # File is not committed - this is an error
      error "Failed to commit .gitattributes and file is not already committed"
    fi
  fi

  # Ensure the commit completed and repo is clean (no staged or modified files)
  run git status --porcelain
  assert_success
  # Filter out untracked files - we only care about tracked changes
  local tracked_changes=$(echo "$output" | grep -v "^??")
  [ -z "$tracked_changes" ] || error "Repository has tracked changes after commit: $tracked_changes"

  # Extract distribution name and version from META.json
  local distribution_name=$(grep '"name"' META.json | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
  local version=$(grep '"version"' META.json | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
  local dist_file="../${distribution_name}-${version}.zip"

  # Clean up version tag if it exists (local and remote)
  git tag -d "$version" 2>/dev/null || true
  git push origin --delete "$version" 2>/dev/null || true

  # make dist should now succeed
  run make dist
  assert_success
  [ -f "$dist_file" ] || error "Distribution file not found: $dist_file"

  # Verify .gitattributes is NOT in the distribution (export-ignore)
  local files=$(get_distribution_files "$dist_file")
  echo "$files" | grep -q "\.gitattributes" && error ".gitattributes should be excluded from distribution (export-ignore)" || true
}

@test "export-ignore directives work in distributions" {
  # Remove .gitattributes and test file if they exist from previous test
  if git ls-files --error-unmatch .gitattributes >/dev/null 2>&1; then
    git rm --cached .gitattributes 2>/dev/null || true
  fi
  if git ls-files --error-unmatch test-export-ignore.txt >/dev/null 2>&1; then
    git rm --cached test-export-ignore.txt 2>/dev/null || true
  fi
  rm -f .gitattributes test-export-ignore.txt
  
  # Create .gitattributes with export-ignore for a test file
  cat > .gitattributes <<EOF
.gitattributes export-ignore
.claude/ export-ignore
test-export-ignore.txt export-ignore
EOF

  # Create a test file that should be excluded
  echo "This should not be in the distribution" > test-export-ignore.txt
  git add .gitattributes test-export-ignore.txt
  run git commit -m "Add .gitattributes and test file"
  assert_success

  # Extract distribution name and version
  local distribution_name=$(grep '"name"' META.json | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
  local version=$(grep '"version"' META.json | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1)
  local dist_file="../${distribution_name}-${version}.zip"

  # Clean up version tag if it exists (local and remote)
  git tag -d "$version" 2>/dev/null || true
  git push origin --delete "$version" 2>/dev/null || true

  # Ensure repo is clean before make dist (allow untracked files, just no modified/tracked changes)
  run git status --porcelain
  assert_success
  # Filter out untracked files - we only care about tracked changes
  local tracked_changes=$(echo "$output" | grep -v "^??")
  [ -z "$tracked_changes" ] || error "Repository has tracked changes before make dist: $tracked_changes"

  # Create distribution
  run make dist
  assert_success
  [ -f "$dist_file" ]

  # Verify test-export-ignore.txt is NOT in the distribution
  local files=$(get_distribution_files "$dist_file")
  echo "$files" | grep -q "test-export-ignore.txt" && error "test-export-ignore.txt should be excluded from distribution (export-ignore)" || true

  # Verify .gitattributes itself is NOT in the distribution
  echo "$files" | grep -q "\.gitattributes" && error ".gitattributes should be excluded from distribution (export-ignore)" || true
}

# vi: expandtab sw=2 ts=2

