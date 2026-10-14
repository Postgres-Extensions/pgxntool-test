#!/usr/bin/env bats

# Test: inventory of the loops in pgxntool's *.mk files
#
# Fails whenever pgxntool's *.mk files have a loop that
# test/lib/pgxntool-loops.txt doesn't list, or stop having one it lists, so a
# new loop can't land without a test that makes one of its non-last iterations
# fail: a recipe loop hides the failure of every iteration but the last unless
# each one ends in `|| exit 1` or the iterations are chained with &&. Needs no
# pg_config, foundation env, or Postgres.
#
# test/lib/scan-make-loops.awk reads the source text rather than make's
# database (`make -p`, which make-variables.bats uses), because make -p shows
# only recipes in active conditional branches: with default settings the
# diffs-mode verify-results recipe is absent. A missed loop is the one failure
# this test can't afford.
#
# Loops are keyed by file, enclosing context and kind, never by line number or
# neighbouring text, so edits near a loop don't trip the test.
#
# Shell keywords count only at command position, but quoted strings aren't
# stripped (`sh -c "..."` bodies are real shell), so text that opens a quoted
# string or an embedded awk program with "while " or "for x in" is counted
# too. That overmatch is stable, so it's accepted.
#
# Not scanned: recipe text that the *.mk.sh generators echo into meta.mk and
# control.mk. They emit no loops today.

load ../lib/helpers

setup_file() {
  setup_topdir
  load_test_env "make-loops"
}

setup() {
  load_test_env "make-loops"
  SCANNER="$TOPDIR/test/lib/scan-make-loops.awk"
}

# Print "<file>\t<context>\t<kind>" for each loop in pgxntool's *.mk files,
# <file> being the path under pgxntool/.
pgxntool_loops() {
  local files f
  files=$(cd "$PGXNREPO" && find . -name .git -prune -o -name '*.mk' -print | LC_ALL=C sort) || return
  [ -n "$files" ] || error "no *.mk files found under $PGXNREPO" || return
  for f in $files; do
    awk -v file="${f#./}" -f "$SCANNER" "$PGXNREPO/$f" || return
  done
}

@test "every loop in pgxntool's *.mk files is listed in test/lib/pgxntool-loops.txt" {
  local rel=test/lib/pgxntool-loops.txt
  local actual entries listed new stale problems=''
  actual=$(pgxntool_loops)
  actual=$(LC_ALL=C sort <<< "$actual")
  entries=$(awk '!/^#/ && !/^[[:space:]]*$/' "$TOPDIR/$rel")
  listed=$(cut -f1-3 <<< "$entries" | LC_ALL=C sort)

  # comm on sorted input compares as multisets: two loops of one kind in one
  # context need two entries.
  new=$(LC_ALL=C comm -23 <(echo "$actual") <(echo "$listed"))
  stale=$(LC_ALL=C comm -13 <(echo "$actual") <(echo "$listed"))

  [ -z "$new" ] || problems+="
New loop(s) in pgxntool's *.mk files not listed in $rel:
$(sed 's/^/  /' <<< "$new")
A shell loop (or \$(foreach) that generates commands) in a recipe hides the failure of every iteration but the last unless each iteration ends in \`|| exit 1\` or the iterations are chained with &&.
Do these IN ORDER:
  1. Write a test that makes a NON-LAST iteration of this loop fail and asserts make exits non-zero. Confirm it catches the bug: temporarily remove the loop's \`|| exit 1\`, and the test must fail.
  2. Only then add the entry to $rel, naming that test in the coverage column (test:<file>:<@test name>).
Do NOT add the entry just to make this test pass; this list exists to force step 1.
Use make-time:<why> only for a \$(foreach) that runs inside make and emits no shell commands. Never use untested: for a new loop.
"
  [ -z "$stale" ] || problems+="
Listed in $rel but no longer in pgxntool's *.mk files -- remove:
$(sed 's/^/  /' <<< "$stale")
If a loop moved to another context (e.g. a renamed target), fix its entry instead, and check that its coverage test still exercises the loop where it is now.
"

  local file context kind coverage extra path name bad=''
  while IFS=$'\t' read -r file context kind coverage extra; do
    [ -z "$extra" ] || { bad+="  more than four tab-separated fields: $file $context $kind"$'\n'; continue; }
    case "$kind" in
      for|while|until|foreach) ;;
      *) bad+="  unknown kind '$kind': $file $context"$'\n' ;;
    esac
    case "$coverage" in
      test:?*:?*)
        path=${coverage#test:}
        name=${path#*:}
        path=${path%%:*}
        grep -Fq -- "@test \"$name\"" "$TOPDIR/test/$path" 2>/dev/null ||
          bad+="  test/$path has no @test \"$name\" (covering $file $context $kind) -- if it was renamed, update the entry; if it was removed, the loop needs a new failure test"$'\n'
        ;;
      make-time:?*)
        [ "$kind" = foreach ] ||
          bad+="  make-time: is only for \$(foreach), not a shell $kind loop: $file $context"$'\n'
        ;;
      untested:?*) ;;
      *) bad+="  coverage must be test:<path under test/>:<@test name>, make-time:<why> or untested:<why>: $file $context $kind"$'\n' ;;
    esac
  done <<< "$entries"
  [ -z "$bad" ] || problems+="
Problems with entries in $rel:
$bad"

  [ -z "$problems" ] || error "${problems#$'\n'}"
}

@test "scan-make-loops.awk finds each loop shape and skips comments and prose" {
  # Lines starting with ">" start with a tab once written out.
  local fixture="$BATS_TEST_TMPDIR/fixture.mk"
  awk '{ sub(/^>/, "\t") } 1' > "$fixture" <<'EOF'
# make comment: for f in a b; do $(foreach x,y,z); done
RUN_ALL = $(foreach e,a b,./run.sh $(e);)
LOOP_CMD = for f in a b; do echo $$f; done
HASH := $(subst x,#,y) $(foreach z,a,b)
copy:
>@for f in a b; do cp $$f out/ || exit 1; done
>@ls | while read f; do echo $$f; done
>@if true; then for f in a b; do echo $$f; done; fi
>@# disabled: true; for f in a b; do echo $$f; done
>@awk '{for(i in A) print A[i]}' /dev/null
>@echo "for a reason" >&2
gen:
>@$(foreach e,a b,./run.sh $(e);)
use-helper:
>@$(RUN_ALL)
inline: ; for f in a b; do echo $$f; done
$(SRCS:.c=.o):
>@echo hi \
># comment line inside a continued command \
>for f in a b; do echo $$f; done
INDENTED = 1
>INDENTED_LOOP := $(foreach x,a b,$(x))
define TEMPLATE
$(1)-copy:
>for f in $(1); do cp $$$$f out/; done
endef
ifeq (never,taken)
untaken:
>for f in a b; do echo $$f; done
endif
EOF

  local want got
  want='var:RUN_ALL foreach
var:LOOP_CMD for
var:HASH foreach
rule:copy for
rule:copy while
rule:copy for
rule:gen foreach
rule:inline for
rule:$(SRCS:.c=.o) for
var:INDENTED_LOOP foreach
define:TEMPLATE for
rule:untaken for'
  got=$(awk -v file=fixture.mk -f "$SCANNER" "$fixture" | cut -f2- | tr '\t' ' ')
  [ "$got" = "$want" ] || error "scanner output differs from expected:
$(diff -u <(echo "$want") <(echo "$got"))"
}

# vi: expandtab sw=2 ts=2
