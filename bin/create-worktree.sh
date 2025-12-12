#!/bin/bash
set -euo pipefail

# Script to create worktrees for pgxntool, pgxntool-test, and pgxntool-test-template
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

echo "Creating pgxntool-test-template worktree..."
cd "$SCRIPT_DIR/../../pgxntool-test-template"
git worktree add "$WORKTREE_DIR/pgxntool-test-template"

echo ""
echo "Worktrees created successfully in:"
echo "  $WORKTREE_DIR/"
echo "    ├── pgxntool/"
echo "    ├── pgxntool-test/"
echo "    └── pgxntool-test-template/"
