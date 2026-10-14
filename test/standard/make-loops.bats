#!/usr/bin/env bats

# Test: inventory of the loops in pgxntool's *.mk files
#
# Fails whenever pgxntool's *.mk files have a loop that
# test/lib/pgxntool-loops.txt doesn't list, stop having one it lists, or change
# the text of the line containing one, so a new loop can't land without a test
# that makes one of its non-last iterations fail, and a changed one can't land
# without a fresh look at whether it still fails make: a recipe loop hides the
# failure of every iteration but the last unless each one ends in `|| exit 1`
# or the iterations are chained with &&. Needs no pg_config, foundation env, or
# Postgres.
#
# test/lib/scan-make-loops.awk reads the source text rather than make's
# database (`make -p`, which make-variables.bats uses), because make -p shows
# only recipes in active conditional branches: with default settings the
# diffs-mode verify-results recipe is absent. A missed loop is the one failure
# this test can't afford.
#
# Loops are keyed by file, enclosing context and kind, never by line number or
# neighbouring text, so edits near a loop don't trip the test. Each entry also
# holds a fingerprint of the logical line containing the loop, which any edit
# to that line other than whitespace changes: that line is what make sees the
# exit status of, including any command after `done` that replaces the loop's.
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

# Reads scan-make-loops.awk output and inserts each loop's fingerprint, the CRC
# that cksum prints for its text, before the text.
loop_fingerprints() {
  local file context kind text crc
  while IFS=$'\t' read -r file context kind text; do
    [ -n "$file" ] || continue
    crc=$(printf '%s\n' "$text" | cksum) || return
    printf '%s\t%s\t%s\t%s\t%s\n' "$file" "$context" "$kind" "${crc%% *}" "$text"
  done
}

# Print "<file>\t<context>\t<kind>\t<fingerprint>\t<text>" for each loop in
# pgxntool's *.mk files, <file> being the path under pgxntool/.
pgxntool_loops() {
  local files f loops=''
  files=$(cd "$PGXNREPO" && find . -name .git -prune -o -name '*.mk' -print | LC_ALL=C sort) || return
  [ -n "$files" ] || error "no *.mk files found under $PGXNREPO" || return
  for f in $files; do
    loops+=$(awk -v file="${f#./}" -f "$SCANNER" "$PGXNREPO/$f") || return
    loops+=$'\n'
  done
  loop_fingerprints <<< "$loops"
}

# compare_loops <entries> <loops>: both are "<file>\t<context>\t<kind>\t
# <fingerprint>\t..." lines, and <loops> has each loop's text in field 5.
# Prints sorted records, tab-separated, keyed by the first three fields:
#   new <key>    per loop beyond the key's entry count
#   unlisted <key> <fingerprint> <text>
#                per loop of such a key whose fingerprint no entry has
#   stale <key>  per entry beyond the key's loop count
#   changed <key> <fingerprint> <text> <listed fingerprint>
#                per loop whose fingerprint no entry has, when the counts
#                match, paired in input order with an unmatched entry
compare_loops() {
  awk -F '\t' '
    NF == 0 { next }
    { key = $1 FS $2 FS $3; keys[key] }
    FILENAME == ARGV[1] { entry[key, ++entry_count[key]] = $4; next }
    { loop[key, ++loop_count[key]] = $4; text[key, loop_count[key]] = $5 }
    END {
      for (key in keys) {
        entries = entry_count[key] + 0
        loops = loop_count[key] + 0
        for (i = 1; i <= entries; i++) left[key, entry[key, i]]++
        unmatched_loops = 0
        for (i = 1; i <= loops; i++) {
          if (left[key, loop[key, i]] > 0) left[key, loop[key, i]]--
          else unmatched_loop[++unmatched_loops] = i
        }
        unmatched_entries = 0
        for (i = 1; i <= entries; i++) {
          if (left[key, entry[key, i]] > 0) {
            left[key, entry[key, i]]--
            unmatched_entry[++unmatched_entries] = entry[key, i]
          }
        }
        if (loops > entries) {
          for (i = entries; i < loops; i++) print "new" FS key
          for (i = 1; i <= unmatched_loops; i++)
            print "unlisted" FS key FS loop[key, unmatched_loop[i]] FS text[key, unmatched_loop[i]]
        } else if (loops < entries) {
          for (i = loops; i < entries; i++) print "stale" FS key
        } else {
          for (i = 1; i <= unmatched_loops; i++)
            print "changed" FS key FS loop[key, unmatched_loop[i]] FS text[key, unmatched_loop[i]] FS unmatched_entry[i]
        }
      }
    }' <(printf '%s\n' "$1") <(printf '%s\n' "$2") | LC_ALL=C sort
}

# fixture_fingerprint <makefile text>: the fingerprint of the text's only loop.
# A ">" at the start of a line stands for a tab.
fixture_fingerprint() {
  local fixture="$BATS_TEST_TMPDIR/fingerprint.mk" loops
  awk '{ sub(/^>/, "\t") } 1' > "$fixture" <<< "$1" || return
  loops=$(awk -v file=fixture.mk -f "$SCANNER" "$fixture") || return
  loops=$(loop_fingerprints <<< "$loops") || return
  case $loops in
    ''|*$'\n'*) error "expected exactly one loop in the fixture, got:
$loops"; return ;;
  esac
  cut -f4 <<< "$loops"
}

@test "every loop in pgxntool's *.mk files is listed in test/lib/pgxntool-loops.txt" {
  local rel=test/lib/pgxntool-loops.txt
  local actual entries differences problems=''
  actual=$(pgxntool_loops)
  entries=$(awk '!/^#/ && !/^[[:space:]]*$/' "$TOPDIR/$rel")
  differences=$(compare_loops "$entries" "$actual")

  local tag file context kind fingerprint text listed tab=$'\t'
  local new='' unlisted='' stale='' changed='' changed_fingerprints=''
  while IFS=$'\t' read -r tag file context kind fingerprint text listed; do
    case "$tag" in
      new) new+="  $file$tab$context$tab$kind"$'\n' ;;
      unlisted) unlisted+="  $file$tab$context$tab$kind$tab$fingerprint$tab$text"$'\n' ;;
      stale) stale+="  $file$tab$context$tab$kind"$'\n' ;;
      changed)
        changed+="  $file$tab$context$tab$kind$tab(listed fingerprint: $listed)
    The line containing it is now: $text
    To see what changed, run this in pgxntool: git log -p -- $file (or git diff -- $file)
"
        changed_fingerprints+="  $file$tab$context$tab$kind$tab$fingerprint"$'\n'
        ;;
    esac
  done <<< "$differences"

  [ -z "$new" ] || problems+="
New loop(s) in pgxntool's *.mk files not listed in $rel:
${new%$'\n'}
A shell loop (or \$(foreach) that generates commands) in a recipe hides the failure of every iteration but the last unless each iteration ends in \`|| exit 1\` or the iterations are chained with &&.
Do these IN ORDER:
  1. Write a test that makes a NON-LAST iteration of this loop fail and asserts make exits non-zero. Confirm it catches the bug: temporarily remove the loop's \`|| exit 1\`, and the test must fail.
  2. Only then add the entry to $rel, with the loop's fingerprint from the list below and that test in the coverage column (test:<file>:<@test name>).
Do NOT add the entry just to make this test pass; this list exists to force step 1.
Use make-time:<why> only for a \$(foreach) that runs inside make and emits no shell commands. Never use untested: for a new loop.
Fingerprints of the unlisted loops, each followed by the line containing it:
${unlisted%$'\n'}
"
  [ -z "$changed" ] || problems+="
Changed loop(s) in pgxntool's *.mk files: the line containing each one no longer matches the fingerprint listed in $rel.
${changed%$'\n'}
Do these IN ORDER:
  1. Read the loop as it is now and confirm that a failure in ANY iteration, not just the last, still fails make: each iteration ends in \`|| exit 1\` or the iterations are chained with &&, there is no \`-\` prefix, and nothing after \`done\` replaces the loop's exit status.
  2. For a test: entry, confirm the named test still exercises the loop as changed: temporarily remove the loop's error handling, and the test must fail. For untested: or make-time:, recheck that the stated reason still holds.
  3. Only then update the fingerprint.
New fingerprint(s), for step 3:
${changed_fingerprints%$'\n'}
Do NOT update the fingerprint just to make this test pass.
"
  [ -z "$stale" ] || problems+="
Listed in $rel but no longer in pgxntool's *.mk files -- remove:
${stale%$'\n'}
If a loop moved to another context (e.g. a renamed target), fix its entry instead, and check that its coverage test still exercises the loop where it is now.
"

  local coverage extra path name bad=''
  while IFS=$'\t' read -r file context kind fingerprint coverage extra; do
    [ -z "$extra" ] || { bad+="  more than five tab-separated fields: $file $context $kind"$'\n'; continue; }
    case "$kind" in
      for|while|until|foreach) ;;
      *) bad+="  unknown kind '$kind': $file $context"$'\n' ;;
    esac
    case "$fingerprint" in
      ''|*[!0-9]*) bad+="  fingerprint '$fingerprint' isn't a number: $file $context $kind"$'\n' ;;
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

@test "compare_loops tells a changed loop from a new or a stale one" {
  local entries loops want got
  entries=$(tr '|' '\t' <<'EOF'
f.mk|rule:same|for|1|test:x
f.mk|rule:changed|for|2|test:x
f.mk|rule:pair|foreach|7|make-time:x
f.mk|rule:pair|foreach|7|make-time:x
f.mk|rule:fewer|for|3|test:x
f.mk|rule:fewer|for|3|test:x
f.mk|rule:more|for|4|test:x
EOF
)
  loops=$(tr '|' '\t' <<'EOF'
f.mk|rule:same|for|1|same text
f.mk|rule:changed|for|5|changed text
f.mk|rule:pair|foreach|8|pair text
f.mk|rule:pair|foreach|8|pair text
f.mk|rule:fewer|for|3|fewer text
f.mk|rule:more|for|4|more text
f.mk|rule:more|for|6|added text
EOF
)
  want=$(tr '|' '\t' <<'EOF'
changed|f.mk|rule:changed|for|5|changed text|2
changed|f.mk|rule:pair|foreach|8|pair text|7
changed|f.mk|rule:pair|foreach|8|pair text|7
new|f.mk|rule:more|for
stale|f.mk|rule:fewer|for
unlisted|f.mk|rule:more|for|6|added text
EOF
)
  got=$(compare_loops "$entries" "$loops")
  [ "$got" = "$want" ] || error "compare_loops output differs from expected:
$(diff -u <(echo "$want") <(echo "$got"))"
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
  got=$(awk -v file=fixture.mk -f "$SCANNER" "$fixture" | cut -f2,3 | tr '\t' ' ')
  [ "$got" = "$want" ] || error "scanner output differs from expected:
$(diff -u <(echo "$want") <(echo "$got"))"
}

@test "a loop's fingerprint covers its whole logical line and ignores only whitespace" {
  local base='copy:
>@echo before
>@for f in a b; do \
>  cp $$f out/ || exit 1; \
>done
>@echo after'
  local original respaced no_exit ignored before after
  original=$(fixture_fingerprint "$base")
  case $original in
    ''|*[!0-9]*) error "fingerprint '$original' isn't a number"; return ;;
  esac
  # Blanks become runs of spaces and tabs, and every recipe line is indented further.
  respaced=$(fixture_fingerprint "$(awk '{ sub(/^>/, ">\t "); gsub(/ /, " \t ") } 1' <<< "$base")")
  no_exit=$(fixture_fingerprint "${base/ || exit 1/}")
  ignored=$(fixture_fingerprint "${base/>@for/>-@for}")
  before=$(fixture_fingerprint "${base/echo before/echo other; echo before}")
  after=$(fixture_fingerprint "${base/echo after/echo other}")

  [ "$respaced" = "$original" ] || error "a whitespace-only change altered the fingerprint"
  [ "$no_exit" != "$original" ] ||
    error "removing \`|| exit 1\` from a continuation line left the fingerprint unchanged"
  [ "$ignored" != "$original" ] || error "adding a \`-\` prefix left the fingerprint unchanged"
  [ "$before" = "$original" ] || error "editing the recipe line before the loop's altered its fingerprint"
  [ "$after" = "$original" ] || error "editing the recipe line after the loop's altered its fingerprint"
}

# vi: expandtab sw=2 ts=2
