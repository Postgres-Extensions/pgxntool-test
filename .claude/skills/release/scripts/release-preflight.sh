#!/usr/bin/env bash
# release-preflight.sh - Pre-flight checks for pgxntool release
#
# Validates both repositories are ready for release and outputs
# structured results. Run from the pgxntool-test directory.
#
# Usage: release-preflight.sh [VERSION]
#
# Exit codes:
#   0 - All checks passed (warnings may exist)
#   1 - Errors found (must fix before release)

set -euo pipefail

TOPDIR="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
source "$TOPDIR/util.sh"

PGXNTOOL_DIR="../pgxntool"
PGXNTOOL_TEST_DIR="."
VERSION="${1:-}"

errors=()
warnings=()

# Find the git remote pointing to Postgres-Extensions for a repo.
# Uses [./] anchor to prevent "pgxntool" from matching "pgxntool-test".
find_upstream_remote() {
    local repo_path="$1"
    local repo_name="$2"
    git -C "$repo_path" remote -v \
        | grep "Postgres-Extensions/${repo_name}[./]" \
        | head -1 \
        | awk '{print $1}'
}

echo "=== Pre-flight Checks ==="
echo

# 1. Identify upstream remotes
echo "--- Upstream Remotes ---"
PGXNTOOL_UPSTREAM=$(find_upstream_remote "$PGXNTOOL_DIR" "pgxntool")
PGXNTOOL_TEST_UPSTREAM=$(find_upstream_remote "$PGXNTOOL_TEST_DIR" "pgxntool-test")

if [ -n "$PGXNTOOL_UPSTREAM" ]; then
    pgxntool_url=$(git -C "$PGXNTOOL_DIR" remote get-url "$PGXNTOOL_UPSTREAM")
    echo "pgxntool: remote=\"$PGXNTOOL_UPSTREAM\" url=$pgxntool_url"
else
    echo "pgxntool: ERROR - no remote pointing to Postgres-Extensions/pgxntool"
    echo "  Fix: cd $PGXNTOOL_DIR && git remote add upstream https://github.com/Postgres-Extensions/pgxntool.git"
    errors+=("pgxntool: no upstream remote")
fi

if [ -n "$PGXNTOOL_TEST_UPSTREAM" ]; then
    pgxntool_test_url=$(git -C "$PGXNTOOL_TEST_DIR" remote get-url "$PGXNTOOL_TEST_UPSTREAM")
    echo "pgxntool-test: remote=\"$PGXNTOOL_TEST_UPSTREAM\" url=$pgxntool_test_url"
else
    echo "pgxntool-test: ERROR - no remote pointing to Postgres-Extensions/pgxntool-test"
    echo "  Fix: git remote add upstream https://github.com/Postgres-Extensions/pgxntool-test.git"
    errors+=("pgxntool-test: no upstream remote")
fi
echo

# 2. Check working directories
echo "--- Working Directories ---"
pgxntool_status=$(git -C "$PGXNTOOL_DIR" status --porcelain)
pgxntool_test_status=$(git -C "$PGXNTOOL_TEST_DIR" status --porcelain)

if [ -z "$pgxntool_status" ]; then
    echo "pgxntool: clean"
else
    echo "pgxntool: DIRTY"
    echo "$pgxntool_status" | sed 's/^/  /'
    errors+=("pgxntool: working directory is dirty")
fi

if [ -z "$pgxntool_test_status" ]; then
    echo "pgxntool-test: clean"
else
    echo "pgxntool-test: DIRTY"
    echo "$pgxntool_test_status" | sed 's/^/  /'
    errors+=("pgxntool-test: working directory is dirty")
fi
echo

# 3. Check branches
echo "--- Branches ---"
pgxntool_branch=$(git -C "$PGXNTOOL_DIR" branch --show-current)
pgxntool_test_branch=$(git -C "$PGXNTOOL_TEST_DIR" branch --show-current)

echo "pgxntool: $pgxntool_branch"
echo "pgxntool-test: $pgxntool_test_branch"
[ "$pgxntool_branch" = "master" ] || errors+=("pgxntool: on branch '$pgxntool_branch', not master")
[ "$pgxntool_test_branch" = "master" ] || errors+=("pgxntool-test: on branch '$pgxntool_test_branch', not master")
echo

# 4. Sync local master and the fork from upstream
#
# Uses `gh repo sync` -- the CLI equivalent of GitHub's "Sync fork" button
# -- rather than hand-rolled git fetch/merge/push plumbing. By default it
# performs a fast-forward-only update and FAILS (non-zero exit) rather than
# creating a merge commit or rewriting history if a true fast-forward isn't
# possible. NEVER pass --force to either call below -- that switches gh to
# a hard reset instead of refusing, which could destroy commits on
# whichever side gets reset.
#
# Two independent syncs per repo, since either can go stale independently
# of the other (e.g. a prior run updated local but was interrupted before
# reaching the fork sync, or local already matched upstream from an earlier
# session so there was never a reason to touch the fork):
#   1. `gh repo sync` (no destination-repository argument, run from inside
#      the local clone) updates local master from its upstream parent.
#   2. `gh repo sync <owner>/<fork>` updates the fork on GitHub directly
#      (the actual "Sync fork" button equivalent), independent of #1.
# Both calls resolve their source (the upstream parent) via GitHub's own
# fork-parent metadata, not our locally-configured remote names -- so this
# works regardless of what the upstream remote happens to be named locally.
fork_slug() {
    local repo_path="$1"
    git -C "$repo_path" remote get-url origin \
        | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##'
}

sync_repo() {
    local repo_path="$1"
    local repo_label="$2"
    local slug output

    slug=$(fork_slug "$repo_path")

    echo "$repo_label: syncing local master from upstream (gh repo sync)..."
    if output=$(cd "$repo_path" && gh repo sync 2>&1); then
        if [ -n "$output" ]; then
            echo "$output" | sed 's/^/  /'
        fi
    else
        echo "$output" | sed 's/^/  /'
        errors+=("$repo_label: gh repo sync (local) failed -- local master may have diverged from upstream in a way that isn't a clean fast-forward; resolve manually")
        return
    fi

    echo "$repo_label: syncing fork ($slug) from upstream (gh repo sync $slug)..."
    if output=$(gh repo sync "$slug" 2>&1); then
        if [ -n "$output" ]; then
            echo "$output" | sed 's/^/  /'
        fi
    else
        echo "$output" | sed 's/^/  /'
        errors+=("$repo_label: gh repo sync (fork $slug) failed -- the fork's master may have diverged from upstream in a way that isn't a clean fast-forward; this is unexpected since the fork should be a pure mirror, and needs manual investigation rather than an automatic overwrite")
    fi
}

echo "--- Sync Status ---"
sync_repo "$PGXNTOOL_DIR" "pgxntool"
sync_repo "$PGXNTOOL_TEST_DIR" "pgxntool-test"
echo

# 5. Version checks
if [ -n "$VERSION" ]; then
    echo "--- Version: $VERSION ---"

    # Validate format
    if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Format: valid"
    else
        echo "Format: INVALID (must be X.Y.Z)"
        errors+=("Version '$VERSION' is not in X.Y.Z format")
    fi

    # Check existing tags
    pgxntool_tag=$(git -C "$PGXNTOOL_DIR" tag -l "$VERSION")
    pgxntool_test_tag=$(git -C "$PGXNTOOL_TEST_DIR" tag -l "$VERSION")

    if [ -n "$pgxntool_tag" ]; then
        echo "pgxntool tag: ALREADY EXISTS"
        errors+=("Tag $VERSION already exists in pgxntool")
    else
        echo "pgxntool tag: available"
    fi

    if [ -n "$pgxntool_test_tag" ]; then
        echo "pgxntool-test tag: ALREADY EXISTS"
        errors+=("Tag $VERSION already exists in pgxntool-test")
    else
        echo "pgxntool-test tag: available"
    fi
    echo
fi

# 6. HISTORY.asc
echo "--- HISTORY.asc ---"
if grep -q '^STABLE$' "$PGXNTOOL_DIR/HISTORY.asc"; then
    echo "STABLE section: found"
    # Show entries under STABLE (between STABLE header and next section)
    sed -n '/^STABLE$/,/^[^ ]/{ /^STABLE$/d; /^------$/d; /^$/d; /^[^ ]/q; p; }' "$PGXNTOOL_DIR/HISTORY.asc" | head -20
else
    echo "STABLE section: NOT FOUND"
    warnings+=("No STABLE section in HISTORY.asc - no changes documented for release")
fi
echo

# Summary
echo "=== Summary ==="
if array_not_empty "${#errors[@]}"; then
    echo "ERRORS (must fix before release):"
    for e in "${errors[@]}"; do
        echo "  - $e"
    done
fi
if array_not_empty "${#warnings[@]}"; then
    echo "WARNINGS (may need attention):"
    for w in "${warnings[@]}"; do
        echo "  - $w"
    done
fi
if ! array_not_empty "${#errors[@]}" && ! array_not_empty "${#warnings[@]}"; then
    echo "All checks passed!"
fi

# Output remote names for use by caller
echo
echo "=== Remote Names ==="
echo "PGXNTOOL_UPSTREAM=$PGXNTOOL_UPSTREAM"
echo "PGXNTOOL_TEST_UPSTREAM=$PGXNTOOL_TEST_UPSTREAM"

! array_not_empty "${#errors[@]}"
