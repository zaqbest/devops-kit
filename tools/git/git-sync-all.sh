#!/bin/bash

# git-sync-all.sh
#
# Sync one or many git repositories. Two actions:
#
#   fetch   Fetch all remotes, fast-forward every local branch WITHOUT
#           switching branches, AND `git pull --ff-only` the current branch.
#           This is the default.
#   pull    Run `git pull` on the currently checked-out branch of each repo.
#           (Does not touch other local branches.)
#
# Directory resolution:
#   - If <dir> is itself a git repo   -> process it directly
#   - Else                            -> scan one level of subdirectories,
#                                        process each subdirectory that is a
#                                        git repo
#
# Usage:
#   git-sync-all.sh fetch [--fetch-only] [--remote <name>] [--force-tags] [--no-tags] [<dir>]
#   git-sync-all.sh pull  [--ff-only] [--rebase] [<dir>]
#   git-sync-all.sh [<dir>]                     # defaults to `fetch`
#
# fetch options:
#   --fetch-only        Do NOT pull the current branch (fetch remotes + FF
#                       other branches only). Default is to also pull current.
#   --pull-current      Deprecated alias, accepted for backward compat (no-op;
#                       pulling current is now the default).
#   --remote <name>     Restrict operations to a single remote (default: all)
#   --force-tags        DANGEROUS-ish (local only): mirror remote tags exactly.
#                       Adds --prune-tags + --force so local tags that have
#                       been force-moved on the remote get overwritten, and
#                       local tags no longer on the remote get deleted.
#                       By default (without this flag), a "would clobber
#                       existing tag" from the remote fails the fetch — pass
#                       this flag or --no-tags to work around it.
#                       (fetch is read-only from the remote's perspective;
#                       this only rewrites local refs.)
#   --prune-tags        Deprecated alias for --force-tags (kept for compat).
#   --no-tags           Do not fetch tags at all
#
# pull options:
#   --ff-only           Use `git pull --ff-only` (safer, refuses non-FF merges)
#   --rebase            Use `git pull --rebase`
#
# Behavior of `fetch` for each local branch:
#   - current branch      -> `git pull --ff-only` (or skip if --fetch-only)
#   - has upstream + FF   -> update via `git fetch <remote> <rbranch>:<lbranch>`
#   - has upstream + div. -> skip with a warning (manual merge/rebase needed)
#   - no upstream         -> skip (local-only branch)

set -e

# ---------------------------------------------------------------------------
# Parse action + args
# ---------------------------------------------------------------------------
ACTION="fetch"
case "${1:-}" in
  fetch|pull) ACTION="$1"; shift ;;
  -h|--help)
    sed -n '3,50p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

# fetch options
PULL_CURRENT=1        # default: fetch also pulls the current branch
REMOTE_FILTER=""
FORCE_TAGS=0          # default: temperate — don't force-update or prune local tags. Opt-in via --force-tags.
NO_TAGS=0
FETCH_FLAG_SEEN=0     # tracks whether ANY fetch-only flag was passed (for the pull-mode guard)

# pull options
PULL_ARGS=()

INPUT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --pull-current)  PULL_CURRENT=1; FETCH_FLAG_SEEN=1; shift ;;   # deprecated: now the default, kept for compat
    --fetch-only)    PULL_CURRENT=0; FETCH_FLAG_SEEN=1; shift ;;
    --remote)        REMOTE_FILTER="$2"; FETCH_FLAG_SEEN=1; shift 2 ;;
    --force-tags)    FORCE_TAGS=1; FETCH_FLAG_SEEN=1; shift ;;
    --prune-tags)    FORCE_TAGS=1; FETCH_FLAG_SEEN=1; shift ;;     # deprecated alias for --force-tags
    --no-tags)       NO_TAGS=1; FETCH_FLAG_SEEN=1; shift ;;
    --ff-only)       PULL_ARGS+=("--ff-only"); shift ;;
    --rebase)        PULL_ARGS+=("--rebase"); shift ;;
    -h|--help)
      sed -n '3,50p' "$0" | sed 's/^# \{0,1\}//'
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

# Guard against flag/action mixups
if [ "$ACTION" = "pull" ] && [ "$FETCH_FLAG_SEEN" -eq 1 ]; then
  echo "❌ fetch-only options (--fetch-only/--pull-current/--remote/--force-tags/--prune-tags/--no-tags) are not valid with 'pull'"
  exit 1
fi
if [ "$ACTION" = "fetch" ] && [ "${#PULL_ARGS[@]}" -gt 0 ]; then
  echo "❌ pull-only options (--ff-only/--rebase) are not valid with 'fetch'"
  exit 1
fi

# Totals (shared, updated by both actions)
TOTAL_REPOS=0
TOTAL_UPDATED=0   # fetch: branches updated;  pull: successful pulls
TOTAL_FAILED=0

# ---------------------------------------------------------------------------
# Action: fetch — fetch all remotes, FF each local branch without switching
# ---------------------------------------------------------------------------
action_fetch() {
  local repo_dir="$1"

  # Build fetch options for tags
  local FETCH_TAG_OPTS=()
  if [ "$NO_TAGS" -eq 1 ]; then
    FETCH_TAG_OPTS+=("--no-tags")
  else
    FETCH_TAG_OPTS+=("--tags")
    if [ "$FORCE_TAGS" -eq 1 ]; then
      # Opt-in: mirror remote tags exactly.
      # --prune-tags removes local tags gone from remote;
      # --force allows local tags whose remote moved to be overwritten
      # (otherwise fetch fails with "would clobber existing tag").
      FETCH_TAG_OPTS+=("--prune-tags" "--force")
    fi
  fi

  # Helper: print a hint after a fetch failure, so users know the escape hatches.
  fetch_failure_hint() {
    if [ "$NO_TAGS" -eq 0 ] && [ "$FORCE_TAGS" -eq 0 ]; then
      echo "   ↳ hint: if this is a 'would clobber existing tag' rejection, rerun with --force-tags (rewrites local tags to match remote) or --no-tags (skip tag sync)."
    fi
  }

  # Step 1: fetch remotes
  if [ -n "$REMOTE_FILTER" ]; then
    echo "🔄 Fetching remote '$REMOTE_FILTER' (--prune ${FETCH_TAG_OPTS[*]})..."
    if ! git -C "$repo_dir" fetch --prune "${FETCH_TAG_OPTS[@]}" "$REMOTE_FILTER"; then
      echo "❌ fetch failed for $repo_dir"
      fetch_failure_hint
      TOTAL_FAILED=$((TOTAL_FAILED + 1))
      return 0
    fi
  else
    echo "🔄 Fetching all remotes (--prune ${FETCH_TAG_OPTS[*]})..."
    if ! git -C "$repo_dir" fetch --all --prune "${FETCH_TAG_OPTS[@]}"; then
      echo "❌ fetch failed for $repo_dir"
      fetch_failure_hint
      TOTAL_FAILED=$((TOTAL_FAILED + 1))
      return 0
    fi
  fi

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
        printf "  ⏭️  %-40s (current branch, skipped due to --fetch-only)\n" "$branch"
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

  TOTAL_UPDATED=$((TOTAL_UPDATED + updated_count))
}

# ---------------------------------------------------------------------------
# Action: pull — plain `git pull` on the current branch
# ---------------------------------------------------------------------------
action_pull() {
  local repo_dir="$1"

  local current_branch
  current_branch="$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD || echo '(detached HEAD)')"
  echo "📍 Current branch: $current_branch"

  if [ "$current_branch" = "(detached HEAD)" ]; then
    echo "⚠️  Detached HEAD, skipping pull."
    return 0
  fi

  if git -C "$repo_dir" pull "${PULL_ARGS[@]}"; then
    echo "✅ Successfully updated $(basename "$repo_dir")"
    TOTAL_UPDATED=$((TOTAL_UPDATED + 1))
  else
    echo "❌ Failed to update $(basename "$repo_dir")"
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
  fi
}

# ---------------------------------------------------------------------------
# Shared per-repo wrapper: header + dispatch to action
# ---------------------------------------------------------------------------
process_repo() {
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

  TOTAL_REPOS=$((TOTAL_REPOS + 1))

  case "$ACTION" in
    fetch) action_fetch "$repo_dir" ;;
    pull)  action_pull  "$repo_dir" ;;
  esac
}

# ---------------------------------------------------------------------------
# Walk: single repo, or one level of subdirectories
# ---------------------------------------------------------------------------
if git -C "$INPUT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  process_repo "$INPUT_DIR"
else
  echo "🔍 '$INPUT_DIR' is not a git repo. Scanning one level of subdirectories..."
  found_any=0
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
if [ "$ACTION" = "fetch" ]; then
  echo "✅ All done (fetch)."
  echo "   Repositories processed: $TOTAL_REPOS"
  echo "   Total branches updated: $TOTAL_UPDATED"
  if [ "$TOTAL_FAILED" -gt 0 ]; then
    echo "   Repositories with fetch failure: $TOTAL_FAILED"
  fi
else
  echo "✅ All done (pull)."
  echo "   Repositories processed: $TOTAL_REPOS"
  echo "   Successful:             $TOTAL_UPDATED"
  if [ "$TOTAL_FAILED" -gt 0 ]; then
    echo "   Failed:                 $TOTAL_FAILED"
  fi
fi
echo "════════════════════════════════════════════════════════════"
