#!/usr/bin/env bats

# Test: post-tag-version-bump (pgxntool issue #20)
#
# `make post-tag-version-bump` bumps each extension's default_version to a
# placeholder alias (PGXNTOOL_POST_TAG_VERSION, default "stable") so ongoing
# development after a release doesn't silently regenerate and overwrite the
# just-released version's SQL file. It's a separate, explicitly-invoked
# target -- NOT wired into `tag`/`dist` -- because both of those run
# routinely outside of an actual release (including from this project's own
# test suite) and `dist` is documented/tested to leave the repository clean;
# see base.mk's comment above the target definition for the full reasoning.
#
# Split by what each layer owns (see CLAUDE.md "Test Each Layer for What It
# Actually Owns"):
# - bump-default-version.sh's own decision logic (parsing/rewriting
#   default_version, argument validation, error cases) is tested directly
#   against scratch control files -- no make, no foundation, no PostgreSQL.
# - post-tag-version-bump's own wiring (does it pass the right script/args,
#   does PGXNTOOL_ENABLE_POST_TAG_VERSION_BUMP=no genuinely make it a no-op)
#   is proven via make -n dry-runs and a stub script substituted through
#   _POST_TAG_VERSION_BUMP_SCRIPT -- not by depending on the real script's
#   behavior.
# - One real end-to-end test proves the pieces actually work together.

load ../lib/helpers
load ../lib/assertions

setup_file() {
  setup_topdir
  load_test_env "tag-version-bump"
}

# ============================================================================
# bump-default-version.sh: pure script-logic unit tests
# ============================================================================

setup() {
  load_test_env "tag-version-bump"
  export SCRIPT="$PGXNREPO/bump-default-version.sh"

  # Fresh scratch directory per test -- no foundation/TEST_REPO needed for
  # the script-logic tests below.
  export SCRATCH="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$SCRATCH"
}

@test "bump-default-version.sh: rewrites a single-quoted default_version, preserving a trailing comment" {
  cat > "$SCRATCH/ext.control" <<'EOF'
comment = 'my extension'
default_version = '2.5.0' # DO NOT REMOVE
relocatable = false
EOF

  run "$SCRIPT" stable "$SCRATCH/ext.control"
  assert_success

  run cat "$SCRATCH/ext.control"
  assert_contains "$output" "default_version = 'stable' # DO NOT REMOVE"
  assert_contains "$output" "comment = 'my extension'"
  assert_contains "$output" "relocatable = false"
}

@test "bump-default-version.sh: rewrites a double-quoted default_version, normalizing to single quotes" {
  echo 'default_version = "1.0.0"' > "$SCRATCH/ext.control"

  run "$SCRIPT" stable "$SCRATCH/ext.control"
  assert_success

  run cat "$SCRATCH/ext.control"
  assert_contains "$output" "default_version = 'stable'"
}

@test "bump-default-version.sh: updates multiple control files in one invocation" {
  echo "default_version = '1.0.0'" > "$SCRATCH/a.control"
  echo "default_version = '2.0.0'" > "$SCRATCH/b.control"

  run "$SCRIPT" dev "$SCRATCH/a.control" "$SCRATCH/b.control"
  assert_success

  run cat "$SCRATCH/a.control"
  assert_contains "$output" "default_version = 'dev'"
  run cat "$SCRATCH/b.control"
  assert_contains "$output" "default_version = 'dev'"
}

@test "bump-default-version.sh: error cases (missing file, missing/duplicate default_version, bad usage)" {
  run "$SCRIPT" stable "$SCRATCH/nope.control"
  assert_failure
  assert_contains "$output" "not found"

  echo "comment = 'no version here'" > "$SCRATCH/no-version.control"
  run "$SCRIPT" stable "$SCRATCH/no-version.control"
  assert_failure
  assert_contains "$output" "Expected exactly one default_version line"

  printf "default_version = '1.0.0'\ndefault_version = '2.0.0'\n" > "$SCRATCH/dup.control"
  run "$SCRIPT" stable "$SCRATCH/dup.control"
  assert_failure
  assert_contains "$output" "Expected exactly one default_version line"

  run "$SCRIPT" stable
  assert_failure
  assert_contains "$output" "Usage:"
}

# ============================================================================
# `post-tag-version-bump`: dry-run coverage
# ============================================================================

setup_foundation_repo() {
  load_test_env "tag-version-bump"
  ensure_foundation "$TEST_DIR"
  assert_cd "$TEST_REPO"

  # PGXNTOOL_CONTROL_FILES (the control-file list the target's invocation is
  # built from) is set unconditionally at parse time in base.mk, but build
  # once anyway so this matches how the target is actually used, and so the
  # real end-to-end test below has a normal, fully-built repo to work from.
  run make
  assert_success
  assert_git_clean
}

@test "make -n post-tag-version-bump: invocation is shown, disabled as a no-op, or re-valued based on the override variables" {
  setup_foundation_repo

  # Default: enabled, placeholder "stable"
  run make -n post-tag-version-bump
  assert_success
  assert_contains "$output" "bump-default-version.sh stable pgxntool-test.control"

  # Disabled: the whole target is replaced by a no-op echo (ifeq-gated at
  # parse time in base.mk, like check-stale-expected's ENABLE flag)
  run make -n post-tag-version-bump PGXNTOOL_ENABLE_POST_TAG_VERSION_BUMP=no
  assert_success
  assert_not_contains "$output" "bump-default-version.sh"
  assert_contains "$output" "disabled, doing nothing"

  # Custom placeholder value is substituted through
  run make -n post-tag-version-bump PGXNTOOL_POST_TAG_VERSION=dev-next
  assert_success
  assert_contains "$output" "bump-default-version.sh dev-next pgxntool-test.control"

  # Invalid enable value is a hard, immediate make error (pgxntool_validate_yesno)
  run make -n post-tag-version-bump PGXNTOOL_ENABLE_POST_TAG_VERSION_BUMP=maybe
  assert_failure
  assert_contains "$output" "PGXNTOOL_ENABLE_POST_TAG_VERSION_BUMP must be"
}

# ============================================================================
# `post-tag-version-bump`: real execution, stub script (proves invocation, not behavior)
# ============================================================================

@test "make post-tag-version-bump: stub is invoked when enabled, never invoked when disabled" {
  setup_foundation_repo

  local marker="$BATS_TEST_TMPDIR/invoked"
  local stub=$(make_stub_script post-tag-stub 0 "" "$marker")

  # Disabled: must not run the stub, and must not touch the control file
  run make post-tag-version-bump PGXNTOOL_ENABLE_POST_TAG_VERSION_BUMP=no _POST_TAG_VERSION_BUMP_SCRIPT="$stub"
  assert_success
  assert_file_not_exists "$marker"
  assert_git_clean

  # Enabled: stub must run
  run make post-tag-version-bump _POST_TAG_VERSION_BUMP_SCRIPT="$stub"
  assert_success
  assert_file_exists "$marker"
}

@test "make post-tag-version-bump: refuses to run against a dirty working tree" {
  setup_foundation_repo

  echo "-- unrelated uncommitted change" >> sql/pgxntool-test.sql
  run make post-tag-version-bump
  assert_failure
  assert_contains "$output" "Untracked changes"

  # Restore clean state for later tests sharing this environment
  git checkout -- sql/pgxntool-test.sql
}

# ============================================================================
# `post-tag-version-bump`: one real end-to-end smoke test
# ============================================================================

@test "make post-tag-version-bump: real script bumps default_version and freezes the current version's SQL file" {
  setup_foundation_repo

  run make post-tag-version-bump
  assert_success

  run cat pgxntool-test.control
  assert_contains "$output" "default_version = 'stable'"

  # Next build regenerates the placeholder's file and leaves the
  # already-released 0.1.1 file alone
  run make
  assert_success
  assert_file_exists "sql/pgxntool-test--stable.sql"
  assert_file_exists "sql/pgxntool-test--0.1.1.sql"
}

# vi: expandtab sw=2 ts=2
