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
# - ext_beta.control (default_version = '2.5.0' with trailing comment)
# - sql/ext_alpha.sql
# - sql/ext_beta.sql
# - META.in.json (with provides for both extensions)
#
# Note: ext_beta.control intentionally has MULTIPLE spaces before the trailing comment
# on default_version. This exercises parse_control_file's whitespace trimming to catch
# both the single-space-only bug (issue #25) and the multiple-spaces bug (issue #26).
# Do not reduce the spaces or remove the comment from ext_beta.control.

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

  # Create state directory
  mkdir -p "$TEST_DIR/.bats-state"

  # Build test repository from multi-extension template
  # This handles: git init, copy template, commit, fake remote, add pgxntool, setup.sh
  build_test_repo_from_template "${TOPDIR}/template-multi-extension" || return 1
}

setup() {
  load_test_env "multi-extension"
  cd_test_env
}

# ============================================================================
# META.MK VALIDATION - Check PGXN/PGXNVERSION are correct
# ============================================================================

@test "meta.mk is created" {
  assert_file_exists "meta.mk"
}

@test "meta.mk contains correct PGXN" {
  # META.in.json has name: "multi-extension-test"
  run grep -E "^PGXN[[:space:]]*:=[[:space:]]*multi-extension-test" meta.mk
  assert_success
}

@test "meta.mk contains correct PGXNVERSION" {
  # META.in.json has version: "1.0.0"
  run grep -E "^PGXNVERSION[[:space:]]*:=[[:space:]]*1\.0\.0" meta.mk
  assert_success
}

# ============================================================================
# CONTROL.MK VALIDATION - Check EXTENSION versions are correct
# ============================================================================

@test "control.mk is created" {
  assert_file_exists "control.mk"
}

@test "control.mk contains EXTENSION_ext_alpha_VERSION" {
  # ext_alpha.control has default_version = '1.0.0'
  run grep -E "^EXTENSION_ext_alpha_VERSION[[:space:]]*:=[[:space:]]*1\.0\.0" control.mk
  assert_success
}

@test "control.mk contains EXTENSION_ext_beta_VERSION" {
  # ext_beta.control has default_version = '2.5.0'
  run grep -E "^EXTENSION_ext_beta_VERSION[[:space:]]*:=[[:space:]]*2\.5\.0" control.mk
  assert_success
}

@test "control.mk lists both extensions in EXTENSIONS" {
  run grep "EXTENSIONS += ext_alpha" control.mk
  assert_success

  run grep "EXTENSIONS += ext_beta" control.mk
  assert_success
}

# ============================================================================
# VERSIONED SQL FILE GENERATION - Test that make creates correct files
# ============================================================================

@test "versioned SQL files do not exist before make" {
  [ ! -f "sql/ext_alpha--1.0.0.sql" ]
  [ ! -f "sql/ext_beta--2.5.0.sql" ]
}

@test "make generates versioned SQL files" {
  # Use 'make all' explicitly because the default target in base.mk is META.json
  # (due to it being the first target defined). This is a quirk of base.mk.
  run make all
  assert_success

  # Also verify pgtle generation works — ext_beta.control has multiple spaces before
  # a trailing comment on default_version to exercise parse_control_file whitespace
  # trimming (issues #25, #26).
  run make pgtle
  assert_success
  local dir found=0
  for dir in pg_tle/*/; do
    [ -d "$dir" ] || break
    found=1
    [ -f "${dir}ext_alpha.sql" ] || error "make pgtle did not generate ${dir}ext_alpha.sql"
    [ -f "${dir}ext_beta.sql" ] || error "make pgtle did not generate ${dir}ext_beta.sql"
  done
  [ "$found" = 1 ] || error "make pgtle generated no pg_tle/<range>/ directory"
}

@test "sql/ext_alpha--1.0.0.sql is generated" {
  assert_file_exists "sql/ext_alpha--1.0.0.sql"
}

@test "sql/ext_beta--2.5.0.sql is generated" {
  assert_file_exists "sql/ext_beta--2.5.0.sql"
}

@test "versioned SQL files contain DO NOT EDIT header" {
  run grep -q "DO NOT EDIT" "sql/ext_alpha--1.0.0.sql"
  assert_success

  run grep -q "DO NOT EDIT" "sql/ext_beta--2.5.0.sql"
  assert_success
}

@test "versioned SQL files contain original SQL content" {
  # ext_alpha.sql has ext_alpha_add function
  run grep -q "ext_alpha_add" "sql/ext_alpha--1.0.0.sql"
  assert_success

  # ext_beta.sql has ext_beta_multiply function
  run grep -q "ext_beta_multiply" "sql/ext_beta--2.5.0.sql"
  assert_success
}

@test "META.json is generated with correct content" {
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

# Sets first_ext and pgtle_dir (the 1.4.0 range directory) in the caller's scope.
load_first_ext_and_pgtle_dir() {
  run make print-_PGXNTOOL_EXTENSIONS
  assert_success
  local list=${output#*set to \"} exts
  read -ra exts <<< "${list%\"}"
  first_ext=${exts[0]}
  [ ${#exts[@]} -ge 2 ] || error "need at least 2 extensions, got: $output"
  debug 2 "first extension: $first_ext"
  pgtle_dir=$(pgxntool/pgtle.sh --get-dir 1.4.0) || error "pgtle.sh --get-dir 1.4.0 failed"
}

# Leaves pg_tle/ generated by make pgtle; must run before the "make pgtle fails" test.
@test "make print-pgtle fails when cat fails for a non-last extension" {
  local first_ext pgtle_dir
  load_first_ext_and_pgtle_dir

  # A fixed target version keeps print-pgtle from querying a live pg_tle.
  local version=1.4.0
  local target="$pgtle_dir/$first_ext.sql"
  local marker="$BATS_TEST_TMPDIR/fake-cat-matched"

  # Fails only on the file print-pgtle cats for the first extension; every
  # other call goes to the real cat, since the pgtle prerequisite's pgtle.sh
  # uses cat too.
  local fakebin="$BATS_TEST_TMPDIR/fakebin" real_cat
  real_cat=$(type -P cat)
  mkdir -p "$fakebin"
  cat > "$fakebin/cat" <<EOF
#!/usr/bin/env bash
if [ \$# -eq 1 ] && [ "\$1" = $(printf %q "$target") ]; then
  touch $(printf %q "$marker")
  echo "fake cat: failing on \$1" >&2
  exit 1
fi
exec $(printf %q "$real_cat") "\$@"
EOF
  chmod +x "$fakebin/cat"

  PATH="$fakebin:$PATH" run make print-pgtle PGXNTOOL_PGTLE_TARGET_VERSION="$version"
  assert_failure
  [ -f "$marker" ] || error "fake cat never saw $target; output: $output"
  assert_contains "$output" "fake cat: failing on $target"
}

# Leaves a directory at pg_tle/<range>/<first_ext>.sql, which breaks print-pgtle; must run after it.
@test "make pgtle fails when pgtle.sh fails for a non-last extension" {
  local first_ext pgtle_dir
  load_first_ext_and_pgtle_dir

  # A directory where pgtle.sh writes its output file makes it fail for the
  # first extension only; the make call's own exit status is what's asserted.
  rm -rf pg_tle
  mkdir -p "$pgtle_dir/$first_ext.sql"
  run make pgtle
  assert_failure
}

# vi: expandtab sw=2 ts=2
