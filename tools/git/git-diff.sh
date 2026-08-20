#!/bin/bash

# Usage:
#   git-diff.sh [-b|--branch] [--no-local] <target-branch> [<current-branch>]
#     --branch mode: compare two branches (target vs current; current defaults to the currently checked-out branch)
#
#   git-diff.sh [--no-local] <target-branch> [<current-dir>]
#     default mode: compare a branch with a working directory (target branch vs current-dir; current-dir defaults to the current directory)
#
# By default, prefers the local branch over the remote-tracking branch (e.g. origin/<branch>).
# Use --no-local to force using remote-tracking branches when they exist.
# Note: this script does NOT fetch/pull — run git-sync-all.sh beforehand to refresh remote refs.

set -e

MODE="dir"
PREFER_LOCAL=1
REMOTE_NAME="origin"

# Parse options
while true; do
  case "$1" in
    -b|--branch)
      MODE="branch"
      shift
      ;;
    --no-local)
      PREFER_LOCAL=0
      shift
      ;;
    --remote)
      REMOTE_NAME="$2"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

if [ -z "$1" ]; then
  echo "Usage:"
  echo "  $(basename "$0") [-b|--branch] [--no-local] [--remote <name>] <target-branch> [<current-branch|current-dir>]"
  echo ""
  echo "  -b / --branch     Compare two branches (target-branch vs current-branch)"
  echo "  --no-local        Prefer remote-tracking refs over local branches"
  echo "  --remote <name>   Remote name to use for tracking refs (default: origin)"
  echo "  (default)         Compare a branch with the working directory (target-branch vs current-dir)"
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

# Refresh remote refs is delegated to git-sync-all.sh — no fetch here.

# Resolve a branch name to the ref used for archive.
# If PREFER_LOCAL=1 (default), try the local branch first, then fall back to remote-tracking ref.
# If PREFER_LOCAL=0, try the remote-tracking ref first, then fall back to the local branch.
resolve_ref() {
  local branch="$1"

  if [ "$PREFER_LOCAL" -eq 1 ]; then
    # Prefer local branch / tag / any valid rev first
    if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/${branch}"; then
      echo "$branch"
      return 0
    fi
    # Fall back to remote-tracking ref
    if git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/${REMOTE_NAME}/${branch}"; then
      echo "${REMOTE_NAME}/${branch}"
      return 0
    fi
    # Last resort: any rev (tags, SHAs, fully-qualified refs)
    if git -C "$REPO_DIR" rev-parse --verify --quiet "$branch" >/dev/null; then
      echo "$branch"
      return 0
    fi
  else
    # Prefer remote-tracking ref first
    if git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/${REMOTE_NAME}/${branch}"; then
      echo "${REMOTE_NAME}/${branch}"
      return 0
    fi
    # Fall back to local branch / tag / any valid rev
    if git -C "$REPO_DIR" rev-parse --verify --quiet "$branch" >/dev/null; then
      echo "$branch"
      return 0
    fi
  fi

  echo ""
  return 1
}

TARGET_REF="$(resolve_ref "$TARGET_BRANCH")"
if [ -z "$TARGET_REF" ]; then
  echo "❌ Error: cannot resolve target branch [$TARGET_BRANCH] (neither local ref nor ${REMOTE_NAME}/${TARGET_BRANCH} exists)"
  exit 1
fi
echo "ℹ️  Target ref resolved to: $TARGET_REF"

TMP_DIR_TARGET="/tmp/git-diff-${TARGET_BRANCH//\//_}-$$-target"

echo "✅ Exporting [$TARGET_REF] to temporary directory: $TMP_DIR_TARGET"
mkdir -p "$TMP_DIR_TARGET"
git -C "$REPO_DIR" archive "$TARGET_REF" | tar -x -C "$TMP_DIR_TARGET"

if [ "$MODE" = "branch" ]; then
  CURRENT_REF="$(resolve_ref "$CURRENT_BRANCH")"
  if [ -z "$CURRENT_REF" ]; then
    echo "❌ Error: cannot resolve current branch [$CURRENT_BRANCH]"
    exit 1
  fi
  echo "ℹ️  Current ref resolved to: $CURRENT_REF"

  TMP_DIR_CURRENT="/tmp/git-diff-${CURRENT_BRANCH//\//_}-$$-current"
  echo "✅ Exporting [$CURRENT_REF] to temporary directory: $TMP_DIR_CURRENT"
  mkdir -p "$TMP_DIR_CURRENT"
  git -C "$REPO_DIR" archive "$CURRENT_REF" | tar -x -C "$TMP_DIR_CURRENT"

  echo "🔍 Launching Beyond Compare: left=[$TARGET_REF] right=[$CURRENT_REF]"
  bcompare "$TMP_DIR_TARGET" "$TMP_DIR_CURRENT"

  echo "✅ Comparison complete. Temporary directories kept at:"
  echo "   $TMP_DIR_TARGET"
  echo "   $TMP_DIR_CURRENT"
else
  echo "🔍 Launching Beyond Compare: left=[$TARGET_REF] right=[$CURRENT_DIR]"
  bcompare "$TMP_DIR_TARGET" "$CURRENT_DIR"

  echo "✅ Comparison complete. Temporary directory kept at: $TMP_DIR_TARGET"
fi