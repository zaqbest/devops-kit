#!/bin/bash

# git-pull-all.sh
#
# Run `git pull` on one or many repositories.
#
# Directory resolution:
#   - If <dir> is itself a git repo   -> pull it directly
#   - Else                            -> scan one level of subdirectories,
#                                        pull each subdirectory that is a git repo
#
# Usage:
#   git-pull-all.sh [--ff-only] [--rebase] [<dir>]
#
# Options:
#   --ff-only    Use `git pull --ff-only` (safer, refuses non-FF merges)
#   --rebase     Use `git pull --rebase`
#   <dir>        A git repo, or a parent directory containing repos (default: .)

set -e

PULL_ARGS=()
INPUT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ff-only)
      PULL_ARGS+=("--ff-only")
      shift
      ;;
    --rebase)
      PULL_ARGS+=("--rebase")
      shift
      ;;
    -h|--help)
      sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      if [ -z "$INPUT_DIR" ]; then
        INPUT_DIR="$1"
      else
        echo "❌ Unexpected argument: $1"
        exit 1
      fi
      shift
      ;;
  esac
done

INPUT_DIR="${INPUT_DIR:-.}"

if [ ! -d "$INPUT_DIR" ]; then
  echo "❌ Error: '$INPUT_DIR' is not a directory"
  exit 1
fi

TOTAL_REPOS=0
TOTAL_SUCCESS=0
TOTAL_FAILED=0

pull_repo() {
  local repo_dir="$1"

  if ! git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "⚠️  Not a git repository, skipping: $repo_dir"
    return 0
  fi

  repo_dir="$(git -C "$repo_dir" rev-parse --show-toplevel)"

  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "📂 Repository: $repo_dir"
  echo "════════════════════════════════════════════════════════════"

  local current_branch
  current_branch="$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD || echo '(detached HEAD)')"
  echo "📍 Current branch: $current_branch"

  TOTAL_REPOS=$((TOTAL_REPOS + 1))

  if [ "$current_branch" = "(detached HEAD)" ]; then
    echo "⚠️  Detached HEAD, skipping pull."
    return 0
  fi

  if git -C "$repo_dir" pull "${PULL_ARGS[@]}"; then
    echo "✅ Successfully updated $(basename "$repo_dir")"
    TOTAL_SUCCESS=$((TOTAL_SUCCESS + 1))
  else
    echo "❌ Failed to update $(basename "$repo_dir")"
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
  fi
}

if git -C "$INPUT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Single repository mode
  pull_repo "$INPUT_DIR"
else
  # Multi-repo mode: scan one level of subdirectories
  echo "🔍 '$INPUT_DIR' is not a git repo. Scanning one level of subdirectories..."
  found_any=0
  for sub in "$INPUT_DIR"/*/; do
    [ -d "$sub" ] || continue
    if git -C "$sub" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      found_any=1
      pull_repo "$sub"
    fi
  done
  if [ "$found_any" -eq 0 ]; then
    echo "⚠️  No git repositories found in immediate subdirectories of '$INPUT_DIR'."
    exit 1
  fi
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "✅ Git pull completed."
echo "   Repositories processed: $TOTAL_REPOS"
echo "   Successful:             $TOTAL_SUCCESS"
if [ "$TOTAL_FAILED" -gt 0 ]; then
  echo "   Failed:                 $TOTAL_FAILED"
fi
echo "════════════════════════════════════════════════════════════"