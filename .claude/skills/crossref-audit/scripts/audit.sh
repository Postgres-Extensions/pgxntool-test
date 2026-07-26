#!/usr/bin/env bash
# audit.sh [pgxntool-dir] [pgxntool-test-dir]
#
# Cheap, stateful audit for missing cross-references between paired commits
# on master in pgxntool and pgxntool-test. Meant to run every round of a
# long session, not just once at startup, without burning real tokens on
# repeat rounds: it fetches both masters, and if neither has moved since the
# last CLEAN (nothing-flagged) check, exits immediately. State is only
# updated on a clean result -- a flagged issue keeps resurfacing every round
# until it's actually fixed, rather than being silently forgotten.
#
# This is a heuristic aid, not authoritative: it correlates commits via the
# "(issue #N)" phrasing this project's commits use for cross-repo issue
# references (not bare "(#N)", which is usually just the local PR number).
# A flagged result still needs a real judgment call before acting -- see
# SKILL.md. Absence of a flag means "nothing obviously wrong found", not a
# guarantee.
#
# Arguments:
#   pgxntool-dir      : path to a pgxntool checkout (default: ../pgxntool)
#   pgxntool-test-dir : path to a pgxntool-test checkout (default: .)
#
# Exit codes:
#   0 : clean (nothing new since last clean check, or nothing flagged)
#   1 : one or more candidate pairings flagged for review
#   2 : usage/environment error

set -euo pipefail

PGXNTOOL_DIR="${1:-${PGXNTOOL_DIR:-../pgxntool}}"
PGXNTOOL_TEST_DIR="${2:-.}"
STATE_FILE="${CROSSREF_AUDIT_STATE:-/tmp/pgxntool-crossref-audit-state}"

for d in "$PGXNTOOL_DIR" "$PGXNTOOL_TEST_DIR"; do
  # -e (not -d): a linked worktree's .git is a FILE pointing at the main
  # repo's git-dir, not a directory.
  [ -e "$d/.git" ] || { echo "ERROR: '$d' is not a git checkout" >&2; exit 2; }
done

git -C "$PGXNTOOL_DIR" fetch upstream master --tags -q
git -C "$PGXNTOOL_TEST_DIR" fetch upstream master --tags -q

PGXN_HEAD=$(git -C "$PGXNTOOL_DIR" rev-parse upstream/master)
TEST_HEAD=$(git -C "$PGXNTOOL_TEST_DIR" rev-parse upstream/master)

if [ -f "$STATE_FILE" ]; then
  read -r LAST_PGXN LAST_TEST < "$STATE_FILE" || true
  if [ "${LAST_PGXN:-}" = "$PGXN_HEAD" ] && [ "${LAST_TEST:-}" = "$TEST_HEAD" ]; then
    echo "crossref-audit: no new commits on either master since last clean check. Nothing to do."
    exit 0
  fi
fi

last_release_tag() {
  git -C "$1" tag --sort=-creatordate | grep -vi '^release$' | head -1
}

PGXN_TAG=$(last_release_tag "$PGXNTOOL_DIR")
TEST_TAG=$(last_release_tag "$PGXNTOOL_TEST_DIR")

pgxn_commits=$(git -C "$PGXNTOOL_DIR" log --format='%H %s' "$PGXN_TAG"..upstream/master)
test_commits=$(git -C "$PGXNTOOL_TEST_DIR" log --format='%H %s' "$TEST_TAG"..upstream/master)

if [ -z "$pgxn_commits" ] && [ -z "$test_commits" ]; then
  echo "crossref-audit: no commits since last release ($PGXN_TAG / $TEST_TAG) in either repo."
  printf '%s %s\n' "$PGXN_HEAD" "$TEST_HEAD" > "$STATE_FILE"
  exit 0
fi

# Extract issue numbers from "(issue #N)"-style phrasing specifically (not
# bare "#N", which is usually just the local repo's own PR number and would
# cause false cross-repo pairings since PR numbering is independent per repo).
#
# `|| true` is required here, not cosmetic: under `set -e`, a `grep` (or a
# pipeline ending in one) that matches nothing exits 1, and since this
# function's return status is that pipeline's status, calling it for a
# subject line with no "issue #N" (the common case -- most commits don't
# reference one) would otherwise abort the whole script immediately.
extract_issue_refs() { grep -oiE 'issue #[0-9]+' <<<"$1" | grep -oE '[0-9]+' | sort -u || true; }

flagged=0
report=""

while IFS= read -r line; do
  [ -z "$line" ] && continue
  sha=${line%% *}
  subj=${line#* }
  issues=$(extract_issue_refs "$subj")
  [ -z "$issues" ] && continue
  for issue in $issues; do
    match=$(grep -iE "issue #${issue}([^0-9]|$)" <<<"$test_commits" || true)
    [ -z "$match" ] && continue

    body=$(git -C "$PGXNTOOL_DIR" log -1 --format='%b' "$sha")
    if ! grep -qi 'pgxntool-test' <<<"$body"; then
      report+=$'\n'"  PGXNTOOL $sha (issue #$issue): \"$subj\" -- no mention of pgxntool-test in body"
      flagged=1
    fi

    test_sha=$(awk -v i="issue #$issue" 'BEGIN{IGNORECASE=1} $0 ~ i {print $1; exit}' <<<"$test_commits")
    if [ -n "$test_sha" ]; then
      test_body=$(git -C "$PGXNTOOL_TEST_DIR" log -1 --format='%b' "$test_sha")
      if ! grep -qiE '[0-9a-f]{7,40}|github\.com/Postgres-Extensions/pgxntool/(pull|commit)/' <<<"$test_body"; then
        report+=$'\n'"  PGXNTOOL-TEST $test_sha (issue #$issue): no hash or pgxntool PR/commit URL found in body"
        flagged=1
      fi
    fi
  done
done <<<"$pgxn_commits"

if [ "$flagged" -eq 1 ]; then
  echo "crossref-audit: FLAGGED -- possible missing cross-reference(s):"
  echo "$report"
  echo
  echo "Confirm each is a genuine code+test pairing before acting (a shared 'issue #N' string is a strong signal but still worth a sanity check) -- see SKILL.md for the fix-vs-ask rules. State file NOT updated; this will resurface every round until resolved."
  exit 1
fi

pgxn_count=$(grep -c . <<<"$pgxn_commits" || true)
test_count=$(grep -c . <<<"$test_commits" || true)
echo "crossref-audit: clean. Checked $pgxn_count pgxntool / $test_count pgxntool-test commit(s) since last release ($PGXN_TAG / $TEST_TAG)."
printf '%s %s\n' "$PGXN_HEAD" "$TEST_HEAD" > "$STATE_FILE"
exit 0

# vi: expandtab ts=2 sw=2
