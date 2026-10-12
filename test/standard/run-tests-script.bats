#!/usr/bin/env bats

# Test: .claude/skills/test/scripts/run-tests.sh - STATUS/REASON/exit-code logic
#
# This covers the repo's own dev tooling (the /test skill's runner and the
# Makefile's submodule target), not pgxntool. The runner is invoked directly
# from a scratch cwd (its log dir and lock are keyed on pwd) with a stub `make`
# first on PATH, so no foundation environment, real Make, or PostgreSQL is needed.

load ../lib/helpers
load ../lib/assertions

setup_file() {
  setup_topdir
}

setup() {
  export RUN_TESTS="$TOPDIR/.claude/skills/test/scripts/run-tests.sh"
  export WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
  cd "$WORK"
  # Otherwise the runner shells out to pg_lsclusters to derive PGPORT
  unset PGCLUSTER
}

teardown() {
  # The runner keeps its log dir and lock under /tmp, not under BATS_TEST_TMPDIR
  rm -rf "/tmp/pgxntool-test-logs$(cd "$WORK" && pwd | sed 's/\//_/g')"
}

# use_stub <command> <exit_code> [stdout_text] -- shadow <command> on PATH
use_stub() {
  local name="$1"
  shift
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  make_stub_script "bin/$name" "$@" > /dev/null
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "run-tests.sh: non-zero exit with no TAP output fails with the command's own code (#95)" {
  use_stub make 2 "boom"

  run "$RUN_TESTS" test-all
  assert_failure_with_status 2
  assert_contains "$output" "STATUS: FAIL"
  assert_contains "$output" "REASON: command exited 2; no tests ran"
  assert_contains "$output" "EXIT_CODE: 2"
  assert_contains "$output" "(no TAP failures parsed; last 20 lines of full log:)"
  assert_contains "$output" "    boom"
}

@test "run-tests.sh: exit 0 with no tests fails and exits 1" {
  use_stub make 0

  run "$RUN_TESTS" test-all
  assert_failure_with_status 1
  assert_contains "$output" "STATUS: FAIL"
  assert_contains "$output" "REASON: no tests ran"
  assert_contains "$output" "EXIT_CODE: 1"
}

@test "run-tests.sh: non-zero exit with only ok lines fails and passes the code through" {
  use_stub make 7 $'1..2\nok 1 a\nok 2 b'

  run "$RUN_TESTS" test-all
  assert_failure_with_status 7
  assert_contains "$output" "STATUS: FAIL"
  assert_contains "$output" "REASON: command exited 7"
  assert_contains "$output" "EXIT_CODE: 7"
}

@test "run-tests.sh: not ok lines fail the run and are listed under FAILURES" {
  use_stub make 0 $'1..2\nok 1 a\nnot ok 2 b'

  run "$RUN_TESTS" test-all
  assert_failure_with_status 1
  assert_contains "$output" "STATUS: FAIL"
  assert_contains "$output" "REASON: 1 test(s) failed"
  assert_contains "$output" "not ok 2 b"
}

@test "run-tests.sh: TAP plan/count mismatch fails" {
  use_stub make 0 $'1..3\nok 1 a\nok 2 b'

  run "$RUN_TESTS" test-all
  assert_failure_with_status 1
  assert_contains "$output" "STATUS: FAIL"
  assert_contains "$output" "REASON: TAP plan declared 3 tests, 2 reported"
}

@test "run-tests.sh: PASS and PASS_WITH_SKIPS exit 0 with no REASON line" {
  use_stub make 0 $'1..2\nok 1 a\nok 2 b # skip why'

  run "$RUN_TESTS" test-all
  assert_success
  assert_contains "$output" "STATUS: PASS_WITH_SKIPS"
  assert_not_contains "$output" "REASON:"

  use_stub make 0 $'1..2\nok 1 a\nok 2 b'

  run "$RUN_TESTS" test-all
  assert_success
  assert_contains "$output" "STATUS: PASS"
  assert_not_contains "$output" "STATUS: PASS_WITH_SKIPS"
  assert_not_contains "$output" "REASON:"
}

@test "run-tests.sh: .bats path runs 'make test/bats/bin/bats' first and reports either failure" {
  # Stub make fails: bats must not run and make's code is passed through
  use_stub make 4 "submodule trouble"
  mkdir -p "$WORK/test/bats/bin"
  make_stub_script "work/test/bats/bin/bats" 0 $'1..1\nok 1 a' "$WORK/bats-ran" > /dev/null

  run "$RUN_TESTS" some.bats
  assert_failure_with_status 4
  assert_contains "$output" "REASON: command exited 4; no tests ran"
  assert_contains "$output" "submodule trouble"
  assert_file_not_exists "$WORK/bats-ran"

  # Stub make succeeds: bats exiting non-zero without TAP fails with its code
  use_stub make 0
  make_stub_script "work/test/bats/bin/bats" 3 > /dev/null

  run "$RUN_TESTS" some.bats
  assert_failure_with_status 3
  assert_contains "$output" "STATUS: FAIL"
  assert_contains "$output" "REASON: command exited 3; no tests ran"
}

@test "run-tests.sh: extra arguments reach bats literally, not as shell syntax" {
  use_stub make 0
  mkdir -p "$WORK/test/bats/bin"
  cat > "$WORK/test/bats/bin/bats" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/bats-argv"
echo "1..1"
echo "ok 1 a"
EOF
  chmod +x "$WORK/test/bats/bin/bats"

  run "$RUN_TESTS" some.bats --filter 'foo|wc -l'
  assert_success
  [ "$(cat "$BATS_TEST_TMPDIR/bats-argv")" = $'some.bats\n--filter\nfoo|wc -l' ]
}

@test "run-tests.sh: real make error for an unknown target fails" {
  run "$RUN_TESTS" no-such-target
  assert_failure_with_status 2
  assert_contains "$output" "STATUS: FAIL"
}

@test "Makefile: every target that calls test/bats/bin/bats depends on the submodule-init target" {
  cd "$TOPDIR"

  # -B with -n shows the recipe without running it; -p dumps the rule database.
  run make -n -B -p test/bats/bin/bats
  assert_success
  assert_contains "$output" "git submodule update --init --recursive test/bats"

  # Targets whose recipe invokes bats, read from the rule database
  local targets target
  targets=$(awk '/^[A-Za-z0-9_.\/-]+:/ {t=$1; sub(/:$/,"",t)}
                 /^\t.*test\/bats\/bin\/bats/ && t != "" {print t}' <<< "$output" | sort -u)
  [ -n "$targets" ] || error "no target with a bats recipe found in make's rule database"

  for target in $targets; do
    grep -Eq "^$target:.* test/bats/bin/bats( |$)" <<< "$output" ||
      error "$target does not depend on test/bats/bin/bats"
  done
}
