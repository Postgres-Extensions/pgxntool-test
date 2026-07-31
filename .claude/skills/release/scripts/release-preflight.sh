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

# 4. Fetch and check sync
#
# If local master is simply behind upstream (a clean fast-forward is
# possible - local has no commits upstream lacks), self-heal: fast-forward
# local master to upstream/master and push the result to the fork remote
# (origin), rather than just warning and leaving it to the user. Genuine
# divergence (local has commits upstream doesn't have) is NOT auto-merged
# or force-pushed - that's left as a hard error requiring manual resolution,
# since silently merging/rebasing here could be lossy.
sync_repo() {
    local repo_path="$1"
    local repo_label="$2"
    local upstream_remote="$3"
    local branch="$4"

    local local_head upstream_head
    local_head=$(git -C "$repo_path" rev-parse HEAD)
    upstream_head=$(git -C "$repo_path" rev-parse "$upstream_remote/master" 2>/dev/null || echo "unknown")

    if [ "$local_head" = "$upstream_head" ]; then
        echo "$repo_label: in sync with $upstream_remote/master ($local_head)"
        return
    fi

    if [ "$branch" != "master" ]; then
        echo "$repo_label: DIVERGED from $upstream_remote/master"
        echo "  local:    $local_head"
        echo "  upstream: $upstream_head"
        echo "  not on master ('$branch') - skipping auto-sync"
        errors+=("$repo_label: local master diverges from $upstream_remote/master and current branch is not master")
        return
    fi

    # Is local a strict ancestor of upstream (i.e. purely behind, with
    # nothing of its own ahead)? Guarded with if/else so a non-zero exit
    # from --is-ancestor (the expected "not an ancestor" case) doesn't trip
    # set -e.
    if git -C "$repo_path" merge-base --is-ancestor "$local_head" "$upstream_head"; then
        echo "$repo_label: BEHIND $upstream_remote/master - fast-forwarding"
        echo "  local:    $local_head"
        echo "  upstream: $upstream_head"
        # NEVER use a plain merge here -- master must only ever fast-forward,
        # never gain a merge commit. --ff-only makes git refuse (non-zero
        # exit) instead of creating a merge commit if a true fast-forward
        # somehow isn't possible (e.g. a race with a concurrent push landing
        # between the ancestor check above and this merge). Guarded with
        # if/else, not `set -e`, so that refusal is caught and reported as
        # the same divergence error below -- never retried with a different
        # strategy (rebase, plain merge, force-push) and never forced.
        if git -C "$repo_path" merge --ff-only "$upstream_remote/master"; then
            git -C "$repo_path" push origin master
            echo "$repo_label: fast-forwarded master $local_head -> $upstream_head and pushed to origin"
        else
            echo "$repo_label: fast-forward merge unexpectedly failed"
            errors+=("$repo_label: git merge --ff-only failed even though local was expected to be a strict ancestor of $upstream_remote/master - resolve manually")
        fi
    else
        echo "$repo_label: DIVERGED from $upstream_remote/master (local has commits upstream lacks)"
        echo "  local:    $local_head"
        echo "  upstream: $upstream_head"
        errors+=("$repo_label: local master has diverged from $upstream_remote/master (not a clean fast-forward) - resolve manually")
    fi
}

echo "--- Sync Status ---"
if [ -n "$PGXNTOOL_UPSTREAM" ]; then
    git -C "$PGXNTOOL_DIR" fetch "$PGXNTOOL_UPSTREAM" 2>/dev/null
    sync_repo "$PGXNTOOL_DIR" "pgxntool" "$PGXNTOOL_UPSTREAM" "$pgxntool_branch"
fi

if [ -n "$PGXNTOOL_TEST_UPSTREAM" ]; then
    git -C "$PGXNTOOL_TEST_DIR" fetch "$PGXNTOOL_TEST_UPSTREAM" 2>/dev/null
    sync_repo "$PGXNTOOL_TEST_DIR" "pgxntool-test" "$PGXNTOOL_TEST_UPSTREAM" "$pgxntool_test_branch"
fi
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
