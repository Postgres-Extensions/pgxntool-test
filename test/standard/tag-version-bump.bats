#!/usr/bin/env bats

# Test: post-tag-version-bump (pgxntool issue #20)
#
# `make post-tag-version-bump` bumps each extension's default_version to a
# placeholder alias (PGXNTOOL_POST_TAG_VERSION, default "stable") so ongoing
# development after a release doesn't silently regenerate and overwrite the
# just-released version's SQL file. It's a separate, explicitly-invoked
# target -- NOT wired into `tag`/`dist`.
#
# Split by what each layer owns (see CLAUDE.md "Test Each Layer for What It
# Actually Owns"):
# - bump-default-version.sh's own decision logic (parsing/rewriting
#   default_version, argument validation, error cases) is tested directly
#   against scratch control files -- no make, no foundation, no PostgreSQL.
# - post-tag-version-bump's own wiring (does it pass the right script/args)
#   is proven via make -n dry-runs and a stub script substituted through
#   _PGXNTOOL_POST_TAG_VERSION_BUMP_SCRIPT -- not by depending on the real script's
#   behavior.
# - One real end-to-end test proves the pieces actually work together.

load ../lib/helpers
load ../lib/assertions

setup_file() {
  setup_topdir
  load_test_env "tag-version-bump"

  # Build once for every make-based test below. The dry-run/stub tests don't
  # strictly need it, but the end-to-end test needs a fully-built, clean repo.
  ensure_foundation "$TEST_DIR"
  cd "$TEST_REPO"
  make
  assert_git_clean
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

@test "bump-default-version.sh: rewrites only default_version's value, leaving other occurrences of the old version and the file mode alone" {
  cat > "$SCRATCH/ext.control" <<'EOT'
# Released as 2.5.0
comment = 'Supersedes 2.5.0 of the old extension'
#default_version = '2.5.0'
default_version = '2.5.0' # 2.5.0 in a trailing comment (should be unchanged)
module_pathname = '$libdir/ext-2.5.0'
EOT
  # Non-default mode (not mktemp's 600 or the 644 umask default) so the check below catches a rewrite that resets it
  chmod 664 "$SCRATCH/ext.control"

  run "$SCRIPT" stable "$SCRATCH/ext.control"
  assert_success

  assert_file_content "$SCRATCH/ext.control" <<'EOT'
# Released as 2.5.0
comment = 'Supersedes 2.5.0 of the old extension'
#default_version = '2.5.0'
default_version = 'stable' # 2.5.0 in a trailing comment (should be unchanged)
module_pathname = '$libdir/ext-2.5.0'
EOT

  local mode
  mode=$(stat -c %a "$SCRATCH/ext.control" 2>/dev/null || stat -f %Lp "$SCRATCH/ext.control")
  [ "$mode" = 664 ] || error "Expected mode 664 after bump, got $mode"
}

@test "assert_file_content: passes on matching content, fails and prints a diff on mismatch" {
  printf 'a\nb\n' > "$SCRATCH/f"
  local diff_text rc

  rc=0
  assert_file_content "$SCRATCH/f" <<<$'a\nb' || rc=$?
  [ "$rc" -eq 0 ] || error "Expected match to pass, got status $rc"

  # out() writes to fd 3; fold it into stdout to capture the diff
  rc=0
  diff_text=$(assert_file_content "$SCRATCH/f" 3>&1 <<<$'a\nc') || rc=$?
  [ "$rc" -ne 0 ] || error "Expected mismatch to fail, got status 0"
  [[ "$diff_text" == *'# -c'* && "$diff_text" == *'# +b'* ]] || error "Expected diff lines -c/+b in: $diff_text"
}

@test "bump-default-version.sh: rewrites a double-quoted default_version, normalizing to single quotes" {
  echo 'default_version = "1.0.0"' > "$SCRATCH/ext.control"

  run "$SCRIPT" stable "$SCRATCH/ext.control"
  assert_success

  assert_file_content "$SCRATCH/ext.control" <<'EOF'
default_version = 'stable'
EOF
}

@test "bump-default-version.sh: rewrites an unquoted default_version, preserving a trailing comment" {
  echo 'default_version = 1.0 # bare' > "$SCRATCH/ext.control"

  run "$SCRIPT" stable "$SCRATCH/ext.control"
  assert_success

  assert_file_content "$SCRATCH/ext.control" <<'EOF'
default_version = 'stable' # bare
EOF
}

@test "bump-default-version.sh: accepts only letters, digits, '.' and '-' in the new version" {
  local v
  for v in stable 1.2.3 1.0-rc1 Stable-RC.1 A9; do
    echo "default_version = '1.0'" > "$SCRATCH/ext.control"
    run "$SCRIPT" "$v" "$SCRATCH/ext.control"
    assert_success
    assert_file_content "$SCRATCH/ext.control" <<<"default_version = '$v'"
  done

  for v in 'a/b' 'a&b' 'a\b' 'a b' 'a_b' "it's" 'a"b' 'a;b' '1.0+x' 'a'$'\n''b'; do
    echo "default_version = '1.0'" > "$SCRATCH/ext.control"
    run "$SCRIPT" "$v" "$SCRATCH/ext.control"
    assert_failure
    assert_contains "$output" "Invalid version"
    assert_file_content "$SCRATCH/ext.control" <<<"default_version = '1.0'"
  done
}

@test "bump-default-version.sh: a failing grep reports grep's stderr and exit code" {
  local fakebin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$fakebin"
  printf '#!/bin/sh\necho "fake grep: boom" >&2\nexit 2\n' > "$fakebin/grep"
  chmod +x "$fakebin/grep"
  echo "default_version = '1.0'" > "$SCRATCH/ext.control"

  PATH="$fakebin:$PATH" run "$SCRIPT" stable "$SCRATCH/ext.control"
  assert_failure
  assert_contains "$output" "grep failed (exit 2)"
  assert_contains "$output" "fake grep: boom"
}

@test "bump-default-version.sh: updates multiple control files in one invocation" {
  echo "default_version = '1.0.0'" > "$SCRATCH/a.control"
  echo "default_version = '2.0.0'" > "$SCRATCH/b.control"

  run "$SCRIPT" dev "$SCRATCH/a.control" "$SCRATCH/b.control"
  assert_success

  assert_file_content "$SCRATCH/a.control" <<'EOF'
default_version = 'dev'
EOF
  assert_file_content "$SCRATCH/b.control" <<'EOF'
default_version = 'dev'
EOF
}

@test "bump-default-version.sh: error cases (missing file, missing/duplicate default_version, bad usage)" {
  run "$SCRIPT" stable "$SCRATCH/nope.control"
  assert_failure
  assert_contains "$output" "not found"

  echo "comment = 'no version here'" > "$SCRATCH/no-version.control"
  run "$SCRIPT" stable "$SCRATCH/no-version.control"
  assert_failure
  assert_contains "$output" "Expected exactly one default_version line"
  assert_contains "$output" "found 0"

  printf "default_version = '1.0.0'\ndefault_version = '2.0.0'\n" > "$SCRATCH/dup.control"
  run "$SCRIPT" stable "$SCRATCH/dup.control"
  assert_failure
  assert_contains "$output" "Expected exactly one default_version line"
  assert_contains "$output" "found 2"

  run "$SCRIPT" stable
  assert_failure
  assert_contains "$output" "Usage:"

  echo "default_version = '1.0'" > "$SCRATCH/ext.control"
  run "$SCRIPT" "it's" "$SCRATCH/ext.control"
  assert_failure
  assert_contains "$output" "Invalid version"
  run "$SCRIPT" "" "$SCRATCH/ext.control"
  assert_failure
  assert_contains "$output" "Invalid version"

  # A value the rewrite can't match must fail, not report success unchanged
  echo "default_version =" > "$SCRATCH/empty.control"
  run "$SCRIPT" stable "$SCRATCH/empty.control"
  assert_failure
  assert_contains "$output" "Could not rewrite"
}

# ============================================================================
# `post-tag-version-bump`: dry-run coverage
# ============================================================================

# Rides on the repo setup_file built.
setup_foundation_repo() {
  assert_cd "$TEST_REPO"
}

@test "make -n post-tag-version-bump: invocation is shown, re-valued based on the override variable" {
  setup_foundation_repo

  # Default: placeholder "stable"
  run make -n post-tag-version-bump
  assert_success
  assert_contains "$output" "bump-default-version.sh stable pgxntool-test.control"

  # Custom placeholder value is substituted through
  run make -n post-tag-version-bump PGXNTOOL_POST_TAG_VERSION=dev-next
  assert_success
  assert_contains "$output" "bump-default-version.sh dev-next pgxntool-test.control"
}

# ============================================================================
# `post-tag-version-bump`: real execution, stub script (proves invocation, not behavior)
# ============================================================================

@test "make post-tag-version-bump: stub is invoked" {
  setup_foundation_repo

  local marker="$BATS_TEST_TMPDIR/invoked"
  local stub=$(make_stub_script post-tag-stub 0 "" "$marker")

  run make post-tag-version-bump _PGXNTOOL_POST_TAG_VERSION_BUMP_SCRIPT="$stub"
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

# Must stay the last test in this file: it commits the bump, leaving
# default_version = 'stable' in the shared environment.
@test "make post-tag-version-bump: real script bumps default_version and freezes the current version's SQL file" {
  setup_foundation_repo

  git ls-files --error-unmatch sql/pgxntool-test--0.1.1.sql >/dev/null
  local released
  released=$(cat sql/pgxntool-test--0.1.1.sql)

  run make post-tag-version-bump
  assert_success

  assert_file_content pgxntool-test.control <<'EOF'
comment = 'Test extension for pgxntool'
default_version = 'stable'
requires = 'plpgsql'
schema = 'public'
EOF

  # Post-release development: a base SQL change must land only in the
  # placeholder's file, and that file must be ignored.
  echo "-- post-release change" >> sql/pgxntool-test.sql
  git commit -q -am "Bump to stable; post-release change"
  run make
  assert_success
  assert_git_clean
  [ "$(cat sql/pgxntool-test--0.1.1.sql)" = "$released" ] || error "sql/pgxntool-test--0.1.1.sql changed after the bump"
  assert_contains "$(cat sql/pgxntool-test--stable.sql)" "post-release change"

  # The update script from the released version must stay trackable
  git check-ignore -q sql/pgxntool-test--stable.sql || error "sql/pgxntool-test--stable.sql should be ignored"
  touch sql/pgxntool-test--0.1.1--stable.sql
  run git check-ignore sql/pgxntool-test--0.1.1--stable.sql
  assert_failure
  rm sql/pgxntool-test--0.1.1--stable.sql
}

# vi: expandtab sw=2 ts=2
