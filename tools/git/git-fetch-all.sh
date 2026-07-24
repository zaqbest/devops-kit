#!/bin/bash

# git-fetch-all.sh
#
# Fetch all remotes and fast-forward every local branch to its upstream
# WITHOUT switching branches, for one or many repositories.
#
# Directory resolution:
#   - If <dir> is itself a git repo         -> process it directly
#   - Else                                  -> scan one level of subdirectories,
#                                              process each subdirectory that is a git repo
#
# Behavior for each local branch:
#   - current branch      -> skip (or run `git pull --ff-only` if --pull-current)
#   - has upstream + FF   -> update via `git fetch <remote> <rbranch>:<lbranch>`
#   - has upstream + div. -> skip with a warning (manual merge/rebase needed)
#   - no upstream         -> skip (local-only branch)
#
# Usage:
#   git-fetch-all.sh [--pull-current] [--remote <name>] [--prune-tags] [--no-tags] [<dir>]
#
# Options:
#   --pull-current      Also run `git pull --ff-only` on the currently checked-out branch
#   --remote <name>     Restrict operations to a single remote (default: all remotes)
#   --prune-tags        Also remove local tags that no longer exist on the remote
#   --no-tags           Do not fetch tags at all
#   <dir>               A git repo, or a parent directory containing repos (default: .)

set -e

PULL_CURRENT=0
REMOTE_FILTER=""
INPUT_DIR=""
PRUNE_TAGS=0
NO_TAGS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --pull-current)
      PULL_CURRENT=1
      shift
      ;;
    --remote)
      REMOTE_FILTER="$2"
      shift 2
      ;;
    --prune-tags)
      PRUNE_TAGS=1
      shift
      ;;
    --no-tags)
      NO_TAGS=1
      shift
      ;;
    -h|--help)
      sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'
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

# ---------------------------------------------------------------------------
# Core: process a single repository
# ---------------------------------------------------------------------------
process_repo() {
  local repo_dir="$1"

  if ! git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "⚠️  Not a git repository, skipping: $repo_dir"
    return 0
  fi

  # Normalize to top-level of the working tree
  repo_dir="$(git -C "$repo_dir" rev-parse --show-toplevel)"

  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "📂 Repository: $repo_dir"
  echo "════════════════════════════════════════════════════════════"

  # Build fetch options for tags
  local FETCH_TAG_OPTS=()
  if [ "$NO_TAGS" -eq 1 ]; then
    FETCH_TAG_OPTS+=("--no-tags")
  else
    FETCH_TAG_OPTS+=("--tags")
    if [ "$PRUNE_TAGS" -eq 1 ]; then
      FETCH_TAG_OPTS+=("--prune-tags")
    fi
  fi

  # Step 1: fetch all remotes (branches + tags)
  if [ -n "$REMOTE_FILTER" ]; then
    echo "🔄 Fetching remote '$REMOTE_FILTER' (--prune ${FETCH_TAG_OPTS[*]})..."
    if ! git -C "$repo_dir" fetch --prune "${FETCH_TAG_OPTS[@]}" "$REMOTE_FILTER"; then
      echo "❌ fetch failed for $repo_dir"
      TOTAL_FAILED=$((TOTAL_FAILED + 1))
      return 0
    fi
  else
    echo "🔄 Fetching all remotes (--prune ${FETCH_TAG_OPTS[*]})..."
    if ! git -C "$repo_dir" fetch --all --prune "${FETCH_TAG_OPTS[@]}"; then
      echo "❌ fetch failed for $repo_dir"
      TOTAL_FAILED=$((TOTAL_FAILED + 1))
      return 0
    fi
  fi

  # Determine current branch (empty string if detached HEAD)
  local CURRENT_BRANCH
  CURRENT_BRANCH="$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD || true)"

  echo ""
  echo "📋 Processing local branches:"

  local updated_count=0
  local skipped_current=0
  local skipped_diverged=0
  local skipped_no_upstream=0
  local skipped_other_remote=0

  while IFS=$'\t' read -r branch upstream; do
    [ -z "$branch" ] && continue

    if [ "$branch" = "$CURRENT_BRANCH" ]; then
      if [ "$PULL_CURRENT" -eq 1 ]; then
        if [ -z "$upstream" ]; then
          printf "  ➖ %-40s (current branch, no upstream, skipped)\n" "$branch"
          skipped_no_upstream=$((skipped_no_upstream + 1))
          continue
        fi
        echo "  ⏳ $branch (current branch, running 'git pull --ff-only')..."
        if git -C "$repo_dir" pull --ff-only; then
          printf "  ✅ %-40s (current branch, pulled)\n" "$branch"
          updated_count=$((updated_count + 1))
        else
          printf "  ⚠️  %-40s (current branch, pull failed - likely diverged)\n" "$branch"
          skipped_diverged=$((skipped_diverged + 1))
        fi
      else
        printf "  ⏭️  %-40s (current branch, skipped; use --pull-current or run 'git pull' manually)\n" "$branch"
        skipped_current=$((skipped_current + 1))
      fi
      continue
    fi

    if [ -z "$upstream" ]; then
      printf "  ➖ %-40s (no upstream, skipped)\n" "$branch"
      skipped_no_upstream=$((skipped_no_upstream + 1))
      continue
    fi

    local upstream_remote="${upstream%%/*}"
    if [ -n "$REMOTE_FILTER" ] && [ "$upstream_remote" != "$REMOTE_FILTER" ]; then
      printf "  ⏸️  %-40s (tracks '%s', skipped by --remote filter)\n" "$branch" "$upstream"
      skipped_other_remote=$((skipped_other_remote + 1))
      continue
    fi

    if ! git -C "$repo_dir" rev-parse --verify --quiet "$upstream" >/dev/null; then
      printf "  ➖ %-40s (upstream '%s' gone, skipped)\n" "$branch" "$upstream"
      skipped_no_upstream=$((skipped_no_upstream + 1))
      continue
    fi

    local local_sha remote_sha
    local_sha="$(git -C "$repo_dir" rev-parse "$branch")"
    remote_sha="$(git -C "$repo_dir" rev-parse "$upstream")"

    if [ "$local_sha" = "$remote_sha" ]; then
      printf "  ✔️  %-40s (already up to date with %s)\n" "$branch" "$upstream"
      continue
    fi

    if git -C "$repo_dir" merge-base --is-ancestor "$local_sha" "$remote_sha"; then
      local remote_name="${upstream%%/*}"
      local remote_branch="${upstream#*/}"

      if git -C "$repo_dir" fetch "$remote_name" "${remote_branch}:${branch}" >/dev/null 2>&1; then
        local short_old short_new
        short_old="$(git -C "$repo_dir" rev-parse --short "$local_sha")"
        short_new="$(git -C "$repo_dir" rev-parse --short "$remote_sha")"
        printf "  ✅ %-40s (updated: %s -> %s via %s)\n" "$branch" "$short_old" "$short_new" "$upstream"
        updated_count=$((updated_count + 1))
      else
        printf "  ❌ %-40s (fast-forward failed unexpectedly)\n" "$branch"
        skipped_diverged=$((skipped_diverged + 1))
      fi
      continue
    fi

    if git -C "$repo_dir" merge-base --is-ancestor "$remote_sha" "$local_sha"; then
      printf "  ⬆️  %-40s (local is ahead of %s, nothing to fetch)\n" "$branch" "$upstream"
    else
      printf "  ⚠️  %-40s (diverged from %s, manual merge/rebase needed)\n" "$branch" "$upstream"
      skipped_diverged=$((skipped_diverged + 1))
    fi

  done < <(git -C "$repo_dir" for-each-ref \
              --format='%(refname:short)%09%(upstream:short)' \
              refs/heads)

  echo ""
  echo "  Summary: updated=$updated_count, skipped(current)=$skipped_current, skipped(diverged)=$skipped_diverged, skipped(no-upstream)=$skipped_no_upstream$([ -n "$REMOTE_FILTER" ] && echo ", skipped(other-remote)=$skipped_other_remote")"

  TOTAL_REPOS=$((TOTAL_REPOS + 1))
  TOTAL_UPDATED=$((TOTAL_UPDATED + updated_count))
}

# ---------------------------------------------------------------------------
# Main: figure out whether INPUT_DIR is a repo or a container of repos
# ---------------------------------------------------------------------------
TOTAL_REPOS=0
TOTAL_UPDATED=0
TOTAL_FAILED=0

if git -C "$INPUT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Single repository mode
  process_repo "$INPUT_DIR"
else
  # Multi-repo mode: scan one level of subdirectories
  echo "🔍 '$INPUT_DIR' is not a git repo. Scanning one level of subdirectories..."
  found_any=0
  # Use a loop that handles spaces safely
  for sub in "$INPUT_DIR"/*/; do
    [ -d "$sub" ] || continue
    if git -C "$sub" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      found_any=1
      process_repo "$sub"
    fi
  done
  if [ "$found_any" -eq 0 ]; then
    echo "⚠️  No git repositories found in immediate subdirectories of '$INPUT_DIR'."
    exit 1
  fi
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "✅ All done."
echo "   Repositories processed: $TOTAL_REPOS"
echo "   Total branches updated: $TOTAL_UPDATED"
if [ "$TOTAL_FAILED" -gt 0 ]; then
  echo "   Repositories with fetch failure: $TOTAL_FAILED"
fi
echo "════════════════════════════════════════════════════════════"
