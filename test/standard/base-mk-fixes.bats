#!/usr/bin/env bats

# Test: assorted base.mk fixes (issues #7, #50, #53)
#
# These three fixes are grouped in one file because each is a small,
# self-contained check against base.mk mechanics with no PostgreSQL
# dependency: EXTRA_CLEAN's target directory, the PGXN_REMOTE override, and
# the base.mk double-include guard.

load ../lib/helpers

setup_file() {
  setup_topdir

  load_test_env "base-mk-fixes"
  ensure_foundation "$TEST_DIR"
}

setup() {
  load_test_env "base-mk-fixes"
  cd_test_env
}

# ============================================================================
# #7 - EXTRA_CLEAN must target the real $(TESTOUT)/results/ directory
# ============================================================================
#
# PGXS's pg_regress_clean_files unconditionally rm -rf's a top-level results/,
# but pg_regress actually writes to $(TESTOUT)/results/ (test/results/ by
# default, via --outputdir in REGRESS_OPTS). EXTRA_CLEAN used to list a
# nonexistent top-level results/ instead of the real directory, so `make
# clean` never removed actual test output.

@test "EXTRA_CLEAN lists the real TESTOUT/results directory" {
  run make print-EXTRA_CLEAN
  assert_success
  assert_contains "$output" "test/results/"
}

@test "make clean removes the real test/results output directory" {
  mkdir -p test/results
  touch test/results/dummy.out
  assert_dir_exists "test/results"

  run make clean
  assert_success
  assert_dir_not_exists "test/results"
}

# ============================================================================
# #53 - PGXN_REMOTE override for tag/rmtag/forcetag/dist
# ============================================================================
#
# tag/rmtag hardcoded the "origin" remote, so a maintainer whose origin is a
# personal fork would silently re-tag the wrong repo. PGXN_REMOTE ?= origin
# preserves the default while allowing an override.

@test "PGXN_REMOTE defaults to origin for tag and rmtag" {
  run make -n tag 2>&1
  assert_success
  assert_contains "$output" "git push origin"

  run make -n rmtag 2>&1
  assert_success
  assert_contains "$output" "git fetch origin"
}

@test "PGXN_REMOTE overrides the remote used by tag and rmtag" {
  run make -n tag PGXN_REMOTE=upstream 2>&1
  assert_success
  assert_contains "$output" "git push upstream"
  assert_not_contains "$output" "git push origin"

  run make -n rmtag PGXN_REMOTE=upstream 2>&1
  assert_success
  assert_contains "$output" "git fetch upstream"
  assert_not_contains "$output" "git fetch origin"
}

# ============================================================================
# #50 - base.mk include guard
# ============================================================================
#
# base.mk can end up included twice in one `make` run: an extension's own
# .mk module includes it, and the extension's Makefile includes it directly
# too. Without a guard, every target gets redefined, producing
# overriding-recipe/ignoring-old-recipe warnings at parse time. This is
# reproduced here by writing a throwaway Makefile that includes
# pgxntool/base.mk directly AND via an intermediate module -- mirroring the
# real-world scenario from the issue -- and confirming make parses it
# without those warnings. (Confirmed by hand that removing the ifndef/endif
# guard reproduces dozens of these warnings for this exact setup.)

@test "base.mk tolerates being included twice in one make run" {
  cat > double-include-module.mk <<'EOF'
include pgxntool/base.mk
EOF
  cat > double-include-test.mk <<'EOF'
include pgxntool/base.mk
include double-include-module.mk
EOF

  run make -f double-include-test.mk -n all 2>&1
  assert_success
  assert_not_contains "$output" "overriding recipe"
  assert_not_contains "$output" "ignoring old recipe"

  rm -f double-include-module.mk double-include-test.mk
}

# vi: expandtab sw=2 ts=2
