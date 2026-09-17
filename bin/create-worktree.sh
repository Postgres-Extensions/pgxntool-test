#!/usr/bin/env bash
set -euo pipefail

# Script to create worktrees for pgxntool and pgxntool-test
# Usage: ./create-worktree.sh <worktree-name>

if [ $# -ne 1 ]; then
    echo "Usage: $0 <worktree-name>" >&2
    echo "Example: $0 pgxntool-build_test" >&2
    exit 1
fi

WORKTREE_NAME="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREES_BASE="$SCRIPT_DIR/../../worktrees"
WORKTREE_DIR="$WORKTREES_BASE/$WORKTREE_NAME"

# Check if worktree directory already exists
if [ -d "$WORKTREE_DIR" ]; then
    echo "Error: Worktree directory already exists: $WORKTREE_DIR" >&2
    exit 1
fi

# Create base directory
echo "Creating worktree directory: $WORKTREE_DIR"
mkdir -p "$WORKTREE_DIR"

# Create worktrees for each repo
echo "Creating pgxntool worktree..."
cd "$SCRIPT_DIR/../../pgxntool"
git worktree add "$WORKTREE_DIR/pgxntool"

echo "Creating pgxntool-test worktree..."
cd "$SCRIPT_DIR/.."
git worktree add "$WORKTREE_DIR/pgxntool-test"

echo
echo "Worktrees created successfully in:"
echo "  $WORKTREE_DIR/"
echo "    ├── pgxntool/"
echo "    └── pgxntool-test/"

# Resolve to an absolute path since WORKTREE_DIR above is relative to
# SCRIPT_DIR and not safe to paste into a `cd` from an arbitrary shell.
absPath="$(cd "$WORKTREE_DIR" && pwd)"
echo
echo "Absolute path: $absPath"
