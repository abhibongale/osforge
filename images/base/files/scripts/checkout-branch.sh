#!/bin/bash
# Checkout a specific branch/tag/commit in a git repository
# This script runs inside the container

set -euo pipefail

REPO_PATH="${1:-}"
BRANCH="${2:-}"

if [[ -z "$REPO_PATH" ]] || [[ -z "$BRANCH" ]]; then
    echo "Usage: checkout-branch.sh <repo-path> <branch|tag|commit>"
    exit 1
fi

if [[ ! -d "$REPO_PATH/.git" ]]; then
    echo "[checkout-branch] ERROR: Not a git repository: $REPO_PATH"
    exit 1
fi

echo "[checkout-branch] Checking out $BRANCH in $REPO_PATH"

cd "$REPO_PATH"

# Fetch latest
git fetch --all --tags || true

# Checkout the specified branch/tag/commit
if git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1; then
    # It's a remote branch
    echo "[checkout-branch] Checking out remote branch: origin/$BRANCH"
    git checkout -B "$BRANCH" "origin/$BRANCH"
elif git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
    # It's a local branch, tag, or commit
    echo "[checkout-branch] Checking out: $BRANCH"
    git checkout "$BRANCH"
else
    echo "[checkout-branch] ERROR: Branch/tag/commit not found: $BRANCH"
    exit 1
fi

# Show what we checked out
git log -1 --oneline
echo "[checkout-branch] Successfully checked out $BRANCH"
