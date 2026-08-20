#!/bin/bash

# Usage:
#   git-export.sh [--remote <name>] [--no-local] [-o <out-dir>] [<ref>]
#
# Export the tree of a git ref (branch, tag, or commit) to a temporary directory.
# If <ref> is omitted, defaults to the currently checked-out branch.
# By default, prefers the local ref; if not found, falls back to the remote-tracking
# ref (origin/<ref>) with a warning. The output directory name encodes the ref name
# and whether it was resolved locally or from the remote, e.g.:
#   /tmp/git-export-<ref>-local-<pid>
#   /tmp/git-export-<ref>-remote-origin-<pid>
#
# Options:
#   --remote <name>   Remote name for tracking refs (default: origin)
#   --no-local        Prefer remote-tracking ref over local ref
#   -o <out-dir>      Explicit output directory (skips /tmp auto-naming)
#
# Note: this script does NOT fetch/pull — run git-sync-all.sh beforehand to refresh remote refs.

set -e

PREFER_LOCAL=1
REMOTE_NAME="origin"
OUT_DIR=""

# Parse options
while true; do
  case "$1" in
    --no-local)
      PREFER_LOCAL=0
      shift
      ;;
    --remote)
      REMOTE_NAME="$2"
      shift 2
      ;;
    -o|--out)
      OUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

if [ -z "$1" ]; then
  # No ref given — default to the currently checked-out branch
  CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -z "$CURRENT_BRANCH" ] || [ "$CURRENT_BRANCH" = "HEAD" ]; then
    echo "❌ Error: no ref given and current HEAD is detached; please specify a ref."
    echo "Usage: $(basename "$0") [--remote <name>] [--no-local] [-o <out-dir>] [<ref>]"
    exit 1
  fi
  REF_INPUT="$CURRENT_BRANCH"
  echo "ℹ️  No ref given; defaulting to current branch: $REF_INPUT"
else
  REF_INPUT="$1"
fi

REPO_DIR="$(pwd)"

# Check whether it is a Git repository
if [ ! -d "$REPO_DIR/.git" ] && ! git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "❌ Error: $REPO_DIR is not a Git repository directory"
  exit 1
fi

# Resolve <ref> to (RESOLVED_REF, SOURCE) where SOURCE ∈ {local, remote, commit}.
# Preference order controlled by PREFER_LOCAL.
RESOLVED_REF=""
SOURCE=""

try_local() {
  # Local branch
  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/${REF_INPUT}"; then
    RESOLVED_REF="$REF_INPUT"
    SOURCE="local"
    return 0
  fi
  # Local tag
  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/tags/${REF_INPUT}"; then
    RESOLVED_REF="$REF_INPUT"
    SOURCE="local"
    return 0
  fi
  return 1
}

try_remote() {
  if git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/${REMOTE_NAME}/${REF_INPUT}"; then
    RESOLVED_REF="${REMOTE_NAME}/${REF_INPUT}"
    SOURCE="remote"
    return 0
  fi
  return 1
}

try_commit_or_any() {
  # Fall back to any valid rev (commit SHA, fully-qualified ref, etc.)
  if git -C "$REPO_DIR" rev-parse --verify --quiet "${REF_INPUT}^{commit}" >/dev/null; then
    RESOLVED_REF="$REF_INPUT"
    SOURCE="commit"
    return 0
  fi
  return 1
}

if [ "$PREFER_LOCAL" -eq 1 ]; then
  try_local || try_remote || try_commit_or_any || true
else
  try_remote || try_local || try_commit_or_any || true
fi

if [ -z "$RESOLVED_REF" ]; then
  echo "❌ Error: cannot resolve ref [$REF_INPUT] (checked local branch/tag, ${REMOTE_NAME}/${REF_INPUT}, and commit SHA)"
  exit 1
fi

# Print resolution notice
case "$SOURCE" in
  local)
    echo "ℹ️  Resolved [$REF_INPUT] from LOCAL: $RESOLVED_REF"
    ;;
  remote)
    if [ "$PREFER_LOCAL" -eq 1 ]; then
      echo "⚠️  Local ref [$REF_INPUT] not found; falling back to REMOTE: $RESOLVED_REF"
    else
      echo "ℹ️  Resolved [$REF_INPUT] from REMOTE: $RESOLVED_REF"
    fi
    ;;
  commit)
    echo "ℹ️  Resolved [$REF_INPUT] as commit/rev: $RESOLVED_REF"
    ;;
esac

# Show short SHA for confirmation
SHORT_SHA="$(git -C "$REPO_DIR" rev-parse --short "$RESOLVED_REF")"
echo "ℹ️  Commit: $SHORT_SHA"

# Compute output directory
SAFE_REF="${REF_INPUT//\//_}"
if [ -z "$OUT_DIR" ]; then
  if [ "$SOURCE" = "remote" ]; then
    OUT_DIR="/tmp/git-export-${SAFE_REF}-remote-${REMOTE_NAME}-$$"
  else
    OUT_DIR="/tmp/git-export-${SAFE_REF}-${SOURCE}-$$"
  fi
fi

if [ -e "$OUT_DIR" ]; then
  echo "❌ Error: output directory already exists: $OUT_DIR"
  exit 1
fi

mkdir -p "$OUT_DIR"
echo "✅ Exporting [$RESOLVED_REF] ($SHORT_SHA) to: $OUT_DIR"
git -C "$REPO_DIR" archive "$RESOLVED_REF" | tar -x -C "$OUT_DIR"

echo "✅ Done. Files exported to:"
echo "   $OUT_DIR"
