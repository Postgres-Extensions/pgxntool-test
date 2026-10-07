#!/usr/bin/env bats

# Test: inventory of the make variables pgxntool defines
#
# Fails whenever pgxntool's *.mk files define a variable that
# test/lib/pgxntool-variables.txt doesn't classify, or stop defining one it
# lists, so every new variable gets a deliberate api/internal/legacy/external
# decision. Needs pg_config (for PGXS) but no foundation env or Postgres.
#
# The list comes from make's own database (`make -p`), keeping each variable
# whose "# makefile (from 'pgxntool/<file>.mk', ...)" origin line points into
# pgxntool. That origin is the variable's *last* assignment, so a variable
# pgxntool sets but PGXS later appends to (REGRESS_OPTS) shows up as PGXS's and
# isn't listed. Variables that only ever arrive on a sub-make command line
# (_PGXNTOOL_TEST_BUILD_ACTIVE) don't appear either.
#
# Variables generated into the extension's meta.mk/control.mk (PGXN,
# PGXNVERSION, EXTENSION_*) are deliberately out of scope: those files live
# outside pgxntool/, so the origin filter drops them. Whether they need their
# own naming rule is a separate question.

load ../lib/helpers

setup_file() {
  setup_topdir
  load_test_env "make-variables"
}

setup() {
  load_test_env "make-variables"
}

# Print the sorted names of every variable whose last assignment is in
# pgxntool/*.mk, from a bare scratch extension that includes base.mk.
pgxntool_make_variables() {
  local dir="$BATS_TEST_TMPDIR/inventory"
  mkdir -p "$dir/test/sql" "$dir/test/build" "$dir/test/install"
  ln -s "$PGXNREPO" "$dir/pgxntool"
  echo 'include pgxntool/base.mk' > "$dir/Makefile"
  # Test-build and test/install variables are defined only when those
  # directories hold .sql files.
  touch "$dir/test/sql/a.sql" "$dir/test/build/a.sql" "$dir/test/install/a.sql"
  # Pre-existing generated files keep make from trying to regenerate them
  # (which fails noisily without a control file or META.in.json).
  touch "$dir/META.json" "$dir/meta.mk" "$dir/control.mk"

  # A clean environment keeps env/command-line origins (MAKEFLAGS from the
  # outer make, an exported TESTDIR, ...) from masking pgxntool's own
  # assignments. PG_CONFIG is honored by putting its directory on PATH.
  local path="$PATH"
  [ -n "${PG_CONFIG:-}" ] && path="$(dirname "$PG_CONFIG"):$path"

  # The goal doesn't exist on purpose: -p dumps the database regardless, and
  # nothing gets built. make's exit status is therefore always nonzero.
  (cd "$dir" && env -i PATH="$path" HOME="$HOME" make -pn __no_such_target__ 2>/dev/null) |
    awk '
      /^# makefile \(from .pgxntool\/[^\047]*\.mk., line [0-9]+\)$/ {
        if ((getline line) > 0) {
          n = split(line, f, /[ \t]+/)
          name = (f[1] == "define" || f[1] == "override") ? f[2] : f[1]
          print name
        }
      }' | LC_ALL=C sort -u
}

@test "every make variable pgxntool defines is classified in test/lib/pgxntool-variables.txt" {
  command -v pg_config >/dev/null || [ -n "${PG_CONFIG:-}" ] ||
    error "pg_config not found; PGXS is needed to parse base.mk"

  local rel=test/lib/pgxntool-variables.txt
  local list="$TOPDIR/$rel"
  local actual expected
  actual=$(pgxntool_make_variables)
  expected=$(grep -v -e '^#' -e '^[[:space:]]*$' "$list" | awk '{print $2}' | LC_ALL=C sort -u)

  # Guard against a vacuous pass if the enumeration itself breaks.
  echo "$actual" | grep -qx '_PGXNTOOL_BASE_MK_INCLUDED' ||
    error "variable enumeration found nothing from pgxntool/base.mk; got: $actual"

  local problems=''
  local unclassified stale
  unclassified=$(LC_ALL=C comm -23 <(echo "$actual") <(echo "$expected"))
  stale=$(LC_ALL=C comm -13 <(echo "$actual") <(echo "$expected"))
  [ -z "$unclassified" ] || problems+="
New variable(s) not classified -- add each to $rel as api (PGXNTOOL_*), internal (_PGXNTOOL_*), or, for a PGXS/make-owned name, external; new legacy entries are not allowed:
$unclassified
"
  [ -z "$stale" ] || problems+="
Listed in $rel but no longer defined by pgxntool -- remove:
$stale
"

  # Each class must match its naming rule.
  local mismatched
  mismatched=$(grep -v -e '^#' -e '^[[:space:]]*$' "$list" | awk '
    $1 !~ /^(api|internal|legacy|external)$/ { print "unknown class: " $0; next }
    $1 == "api"      && $2 !~ /^PGXNTOOL_/            { print "api name must start with PGXNTOOL_: " $2 }
    $1 == "internal" && $2 !~ /^_(PGXNTOOL|pgxntool)_/ { print "internal name must start with _PGXNTOOL_: " $2 }
    $1 != "internal" && $2 ~ /^_(PGXNTOOL|pgxntool)_/  { print "_PGXNTOOL_ name must be classed internal: " $2 }
  ')
  [ -z "$mismatched" ] || problems+="
Class/name mismatches in $rel:
$mismatched
"

  [ -z "$problems" ] || error "$problems"
}
