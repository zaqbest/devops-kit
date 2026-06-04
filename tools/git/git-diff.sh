#!/bin/bash

# Usage:
#   git-diff.sh [-b|--branch] <target-branch> [<current-branch>]
#     --branch mode: compare two branches (target vs current; current defaults to the currently checked-out branch)
#
#   git-diff.sh <target-branch> [<current-dir>]
#     default mode: compare a branch with a working directory (target branch vs current-dir; current-dir defaults to the current directory)
#
# Both modes run `git fetch` to refresh remote refs before comparing.

set -e

MODE="dir"

# Parse options
while true; do
  case "$1" in
    -b|--branch)
      MODE="branch"
      shift
      ;;
    *)
      break
      ;;
  esac
done

if [ -z "$1" ]; then
  echo "Usage:"
  echo "  $(basename "$0") [-b|--branch] <target-branch> [<current-branch|current-dir>]"
  echo ""
  echo "  -b / --branch  Compare two branches (target-branch vs current-branch)"
  echo "  (default)      Compare a branch with the working directory (target-branch vs current-dir)"
  exit 1
fi

TARGET_BRANCH="$1"

if [ "$MODE" = "branch" ]; then
  CURRENT_BRANCH="${2:-$(git rev-parse --abbrev-ref HEAD)}"
  REPO_DIR="$(pwd)"
else
  CURRENT_DIR="${2:-$(pwd)}"
  REPO_DIR="$CURRENT_DIR"
fi

# Check whether it is a Git repository
if [ ! -d "$REPO_DIR/.git" ] && [ ! -d "$REPO_DIR/../.git" ]; then
  echo "❌ Error: $REPO_DIR is not a Git repository directory"
  exit 1
fi

# Refresh remote refs
echo "🔄 Running git fetch to refresh remote refs..."
git -C "$REPO_DIR" fetch

TMP_DIR_TARGET="/tmp/git-diff-${TARGET_BRANCH}-$$-target"

echo "✅ Exporting branch [$TARGET_BRANCH] to temporary directory: $TMP_DIR_TARGET"
mkdir -p "$TMP_DIR_TARGET"
git -C "$REPO_DIR" archive "$TARGET_BRANCH" | tar -x -C "$TMP_DIR_TARGET"

if [ "$MODE" = "branch" ]; then
  TMP_DIR_CURRENT="/tmp/git-diff-${CURRENT_BRANCH}-$$-current"
  echo "✅ Exporting branch [$CURRENT_BRANCH] to temporary directory: $TMP_DIR_CURRENT"
  mkdir -p "$TMP_DIR_CURRENT"
  git -C "$REPO_DIR" archive "$CURRENT_BRANCH" | tar -x -C "$TMP_DIR_CURRENT"

  echo "🔍 Launching Beyond Compare: left=[$TARGET_BRANCH] right=[$CURRENT_BRANCH]"
  bcompare "$TMP_DIR_TARGET" "$TMP_DIR_CURRENT"

  echo "✅ Comparison complete. Temporary directories kept at:"
  echo "   $TMP_DIR_TARGET"
  echo "   $TMP_DIR_CURRENT"
else
  echo "🔍 Launching Beyond Compare: left=[$TARGET_BRANCH] right=[$CURRENT_DIR]"
  bcompare "$TMP_DIR_TARGET" "$CURRENT_DIR"

  echo "✅ Comparison complete. Temporary directory kept at: $TMP_DIR_TARGET"
fi
