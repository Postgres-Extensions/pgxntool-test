#!/usr/bin/env bats

# Test: base.mk double-inclusion safety (issue #50)
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

load ../lib/helpers

setup_file() {
  setup_topdir

  load_test_env "base-mk-include-guard"
  ensure_foundation "$TEST_DIR"
}

setup() {
  load_test_env "base-mk-include-guard"
  cd_test_env
}

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
