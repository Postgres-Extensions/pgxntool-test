#!/usr/bin/env bats

# Test: misc small base.mk behaviors
#
# Grouped into one suite because each is small enough that a dedicated
# suite file isn't worth the per-suite overhead -- every test below only
# needs a plain foundation checkout, no suite-specific fixture.
#
# - base.mk double-inclusion safety (issue #50): base.mk can end up
#   included twice in one `make` run: an extension's own .mk module
#   includes it, and the extension's Makefile includes it directly too.
#   Without a guard, every target gets redefined, producing
#   overriding-recipe/ignoring-old-recipe warnings at parse time. This is
#   reproduced here by writing a throwaway Makefile that includes
#   pgxntool/base.mk directly AND via an intermediate module -- mirroring
#   the real-world scenario from the issue -- and confirming make parses it
#   without those warnings. (Confirmed by hand that removing the
#   ifndef/endif guard reproduces dozens of these warnings for this exact
#   setup.)
# - bin/version's HISTORY.asc parsing (in isolation -- a stamped version,
#   an unreleased "STABLE" checkout, a missing file, an empty file,
#   malformed first lines), that `make pgxntool-version` is correctly
#   wired to it inside a real embedded pgxntool copy, and (CRITICAL -- see
#   comment below) that it matches the actual, unmodified pgxntool checkout
#   this test suite is running against.
# - DATA includes historical single-version sql files (issue #48): the
#   template already carries sql/pgxntool-test--0.1.0.sql, a manually-written
#   historical full-install script with only one `--` separator (as opposed
#   to an upgrade script like ext--a--b.sql, which has two). `make
#   print-DATA` must list it -- PGXS only installs files named in DATA, so a
#   wildcard that requires two `--` separators silently drops these files
#   from `make install`, breaking `CREATE EXTENSION ext VERSION '0.9.6'` even
#   though the file is tracked in git. No scratch fixture needed: the
#   template's existing historical file already reproduces this.
# - check-duplicate-docs warns about DOCS entries sharing a basename (issue
#   #115): PGXS installs DOCS into one flat directory and refuses to overwrite
#   a file it just installed, so one collision fails the whole install.
# - installcheck's order-only directory prerequisites each have a rule that
#   creates them, so a project with no test/sql/ can still run `make test`.

load ../lib/helpers

setup_file() {
  setup_topdir

  load_test_env "base-mk-misc"
  ensure_foundation "$TEST_DIR"

  export VERSION_SCRIPT="$PGXNREPO/bin/version"
  export SCRATCH_DIR="$TEST_DIR/base-mk-misc-scratch"
}

setup() {
  load_test_env "base-mk-misc"
  cd_test_env

  rm -rf "$SCRATCH_DIR"
  mkdir -p "$SCRATCH_DIR"
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

@test "DATA includes historical single-version sql files (issue #48)" {
  # sql/pgxntool-test--0.1.0.sql is a template-provided historical
  # full-install script (one `--` separator), distinct from the
  # auto-generated current-version file and from upgrade scripts like
  # sql/pgxntool-test--0.1.0--0.1.1.sql (two `--` separators). Before issue
  # #48 was fixed, DATA's wildcard required two `--` separators, so this
  # file was silently never installed.
  run make print-DATA
  assert_success
  assert_contains "$output" "sql/pgxntool-test--0.1.0.sql"
}

# ----------------------------------------------------------------------------
# check-duplicate-docs (issue #115)
# ----------------------------------------------------------------------------
#
# base.mk checks for duplicate DOCS entries from a recipe rather than at parse
# time, because an extension's own Makefile appends to DOCS *after* it
# includes base.mk -- a parse-time check in base.mk structurally cannot see
# those additions, and they're exactly the case worth protecting against. So
# the duplicate below is introduced by a post-include `DOCS +=` in a throwaway
# Makefile, mirroring what a real extension does; a duplicate baked into
# base.mk's own assembly would not exercise the same code path.

@test "all depends on check-duplicate-docs (issue #115)" {
  # Proves the check actually runs before anything is installed: PGXS's
  # `install` depends on `all`. A structural check rather than a real
  # `make install` run, for the same reason as the installcheck/install edge
  # in make-test.bats -- an ordering that happens to hold in one run isn't
  # evidence the dependency exists.
  run make -p -n check-duplicate-docs 2>&1
  assert_success

  local prereq_line
  prereq_line=$(echo "$output" | awk '/^all:/{print; exit}')
  [ -n "$prereq_line" ] || error "all rule not found in 'make -p' database dump"

  echo "$prereq_line" | tr ' ' '\n' | grep -qx check-duplicate-docs || \
    error "all's parsed prerequisite list does not include check-duplicate-docs: $prereq_line"
}

@test "check-duplicate-docs stays quiet on the template's own DOCS (issue #115)" {
  run make -n check-duplicate-docs 2>&1
  assert_success
  assert_not_contains "$output" "more than once"
}

@test "check-duplicate-docs warns about a duplicate added after base.mk is included (issue #115)" {
  # The DOC_DIRS wildcard has already put every template doc/* file in DOCS.
  # - doc/other.html again: the same entry twice.
  # - extra_doc/asc_doc.asc: a different path installing to the same name,
  #   since PGXS flattens DOCS into one directory. The check only compares
  #   strings, so the file needn't exist.
  # - doc/adoc%.adoc: unescaped, its `%` would be a $(filter) wildcard
  #   matching adoc_doc.adoc.
  cat > docs-duplicate-test.mk <<'EOF'
include pgxntool/base.mk
DOCS += doc/other.html extra_doc/asc_doc.asc doc/adoc%.adoc
EOF

  run make -f docs-duplicate-test.mk -n check-duplicate-docs 2>&1
  # A warning, not an error -- a duplicate is worth reporting, but failing the
  # build over it would be worse than the install failure it warns about.
  assert_success
  assert_contains "$output" "DOCS installs other.html more than once (from: doc/other.html doc/other.html)"
  assert_contains "$output" "DOCS installs asc_doc.asc more than once (from: doc/asc_doc.asc extra_doc/asc_doc.asc)"
  assert_contains "$output" "will not overwrite just-created"

  # Files that don't collide must not be named.
  assert_not_contains "$output" "adoc"

  rm -f docs-duplicate-test.mk
}

@test "installcheck creates missing test/sql/, test/expected/ and results/" {
  # Make treats `dir` and `dir/` as different targets, so each order-only
  # prerequisite must be spelled exactly like the rule that creates it.
  # Pointing TESTDIR at a directory that doesn't exist reproduces a project
  # without test/sql/ without touching the shared test environment; setup.sh
  # creates test/sql/, which is why the foundation itself can't show this.
  local testdir="$SCRATCH_DIR/test"

  run make -n installcheck TESTDIR="$testdir" 2>&1
  assert_success
  assert_not_contains "$output" "No rule to make target"
  assert_contains "$output" "mkdir -p $testdir/sql/"
  assert_contains "$output" "mkdir -p $testdir/expected/"
  assert_contains "$output" "mkdir -p $testdir/results/"
}

@test "bin/version prints a stamped version number" {
  echo "2.1.0" > "$SCRATCH_DIR/HISTORY.asc"

  run "$VERSION_SCRIPT" "$SCRATCH_DIR/HISTORY.asc"
  assert_success
  [ "$output" = "2.1.0" ]
}

@test "bin/version prints STABLE for an unreleased checkout" {
  printf 'STABLE\n------\n' > "$SCRATCH_DIR/HISTORY.asc"

  run "$VERSION_SCRIPT" "$SCRATCH_DIR/HISTORY.asc"
  assert_success
  [ "$output" = "STABLE" ]
}

@test "bin/version errors on a missing HISTORY.asc" {
  run "$VERSION_SCRIPT" "$SCRATCH_DIR/does-not-exist.asc"
  assert_failure
  assert_contains "$output" "not found"
}

@test "bin/version errors on an empty HISTORY.asc" {
  : > "$SCRATCH_DIR/HISTORY.asc"

  run "$VERSION_SCRIPT" "$SCRATCH_DIR/HISTORY.asc"
  assert_failure
  assert_contains "$output" "empty"
}

@test "bin/version rejects a malformed first line" {
  for bad in "stable" "v2.1.0" "2.1.0-beta" "2.1" "not a version"; do
    echo "$bad" > "$SCRATCH_DIR/HISTORY.asc"

    run "$VERSION_SCRIPT" "$SCRATCH_DIR/HISTORY.asc"
    assert_failure
    assert_contains "$output" "neither STABLE nor a X.Y.Z version"
  done
}

# CRITICAL: this test must run bin/version directly against the real,
# unmodified $PGXNREPO checkout -- never a scratch file, an rsync'd copy, or
# a cached foundation snapshot. A release PR stamps HISTORY.asc with the
# real version and relies on CI running this exact check to catch a bad
# stamp before it's tagged and pushed -- that guarantee only holds if the
# check reads the literal, current pgxntool/HISTORY.asc. This matters most
# precisely when the top line is NOT "STABLE": that's the release commit
# itself, and a copy-based or stale check could pass against old content and
# let a wrong version ship. Do not weaken this to a scratch-file test or to a
# non-empty check.
@test "bin/version matches the current pgxntool/HISTORY.asc with no modifications" {
  local expected
  expected=$(head -n1 "$PGXNREPO/HISTORY.asc")

  run "$VERSION_SCRIPT"
  assert_success
  [ "$output" = "$expected" ]
}

@test "make pgxntool-version matches the embedded pgxntool/HISTORY.asc" {
  cd "$TEST_REPO"

  local expected
  expected=$(head -n1 pgxntool/HISTORY.asc)

  # --no-print-directory: our own test suite runs under `make test-all`, which
  # propagates MAKEFLAGS/MAKELEVEL to this nested `make` call and would
  # otherwise wrap the output in "make[1]: Entering/Leaving directory" banners.
  run make --no-print-directory pgxntool-version
  assert_success
  [ "$output" = "$expected" ]
}

# vi: expandtab sw=2 ts=2
