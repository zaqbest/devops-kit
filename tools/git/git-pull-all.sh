#!/bin/bash

# Set start directory from first parameter, default to current directory if not provided
START_DIR="${1:-.}"

echo "Starting Git pull for all repositories in: $START_DIR"
echo "========================================"

for dir in "$START_DIR"/*/; do
    # Skip if not a directory
    if [[ ! -d "$dir" ]]; then
        continue
    fi

    echo ""
    echo "Processing: $(basename "$dir")"
    echo "----------------------------"

    (
        cd "$dir" || {
            echo "❌ Failed to enter directory: $dir"
            continue
        }

        # Check if it's a git repository
        if [[ ! -d ".git" ]]; then
            echo "⚠️  Not a git repository, skipping..."
            continue
        fi

        # Show current branch
        current_branch=$(git branch --show-current 2>/dev/null)
        echo "📍 Current branch: $current_branch"

        # If current branch is not master, ask whether to switch
        #if [[ "$current_branch" != "master" ]]; then
        #    read -p "⚠️  You are on branch '$current_branch'. Switch to 'master' before updating? (y/n): " choice
        #    if [[ "$choice" == "y" || "$choice" == "Y" ]]; then
        #        if git checkout master; then
        #            echo "✅ Switched to master branch."
        #        else
        #            echo "❌ Failed to switch to master branch, skipping..."
        #            exit 1
        #        fi
        #    else
        #        echo "⏩ Staying on '$current_branch' branch."
        #    fi
        #fi

        # Execute git pull
        if git pull; then
            echo "✅ Successfully updated $(basename "$dir")"
        else
            echo "❌ Failed to update $(basename "$dir")"
        fi
    )
done

echo ""
echo "========================================"
echo "Git pull completed for all repositories!"

