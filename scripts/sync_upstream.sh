#!/bin/bash
# sync_upstream.sh - Ninja upstream sync with RAM limit feature toggle
# Usage as requested: disable our change, sync latest commits, then re-enable
# Hindi comments included

set -e

BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "Current branch: $BRANCH"

# Step 1: Check if we have uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Error: uncommitted changes hain. Pehle commit ya stash karo."
  exit 1
fi

# Step 2: Backup our feature commit(s)
# Assume last commit is RAM limit feature (or all commits since base)
BASE_COMMIT=$(git merge-base HEAD origin/master 2>/dev/null || git merge-base HEAD master 2>/dev/null || echo "HEAD~1")
FEATURE_COMMIT=$(git rev-parse HEAD)
echo "Base commit for diff: $BASE_COMMIT"
echo "Feature commit: $FEATURE_COMMIT"

PATCH_FILE="/tmp/ninja-ram-limit-backup.patch"
git format-patch $BASE_COMMIT..HEAD --stdout > $PATCH_FILE
echo "Backup patch saved to $PATCH_FILE"

# Step 3: Disable feature - revert last feature commit temporarily
# Find commits that touch RAM limit files
echo ""
echo "=== Step: Disabling RAM limit feature (revert) ==="
# We will create a revert commit that disables feature
# If feature is one commit, revert it. If multiple, revert all.

# For simplicity, we assume single feature commit on top. Revert it:
LAST_COMMIT_MSG=$(git log -1 --pretty=%B)
if echo "$LAST_COMMIT_MSG" | grep -q "RAM"; then
  echo "Reverting last RAM limit commit..."
  git revert HEAD --no-edit
  echo "Feature disabled via revert commit."
else
  echo "Last commit is not RAM limit feature, checking for RAM in last 2 commits..."
  # Try to revert all feature commits from base
  # Create a commit that removes RAM feature by resetting files to base
  echo "Creating disable commit manually..."
  git checkout $BASE_COMMIT -- src/build.cc src/build.h src/eval_env.cc src/ninja.cc src/util.cc src/util.h 2>/dev/null || true
  if ! git diff --quiet; then
    git commit -m "TEMP: Disable RAM limit feature for upstream sync" -a
    echo "Disabled via manual file revert."
  else
    echo "Nothing to disable."
  fi
fi

# Step 4: Sync upstream
echo ""
echo "=== Step: Syncing upstream ==="
if git remote | grep -q upstream; then
  echo "Upstream remote already exists."
else
  echo "Adding upstream remote https://github.com/ninja-build/ninja.git"
  git remote add upstream https://github.com/ninja-build/ninja.git
fi

git fetch upstream
echo "Merging upstream/master..."
# Try merge, if fails, try rebase guidance
if git merge upstream/master --no-edit; then
  echo "Merge successful."
else
  echo "Merge conflict! Resolve manually then continue."
  echo "After resolving, run: git merge --continue and then re-enable feature."
  exit 1
fi

# Step 5: Re-enable feature
echo ""
echo "=== Step: Re-enabling RAM limit feature ==="
if [ -f "$PATCH_FILE" ]; then
  # If we created a revert commit earlier, revert the revert to enable
  echo "Reverting the revert commit to re-enable feature..."
  if git log --oneline -1 | grep -q "TEMP: Disable"; then
    git revert HEAD --no-edit
    echo "Feature re-enabled via revert of disable commit."
  else
    # Try to apply patch
    echo "Applying backup patch..."
    # Check if patch can be applied
    if git apply --check "$PATCH_FILE" 2>/dev/null; then
      git apply "$PATCH_FILE"
      git add -A
      git commit -m "Re-enable RAM limit feature after upstream sync

Feature: RAM limit via NINJA_RAM_LIMIT env var
- Parses 2g, 512m etc
- Per edge ram binding
- Heavy jobs (linking 4g with 2g limit) run exclusively"
      echo "Feature re-enabled via patch."
    else
      echo "Patch cannot be applied cleanly due to upstream changes."
      echo "Trying cherry-pick of original feature commit..."
      git cherry-pick $FEATURE_COMMIT || {
        echo "Cherry-pick conflict! Please resolve manually."
        echo "Files: src/build.cc src/build.h src/eval_env.cc src/ninja.cc src/util.cc src/util.h"
        exit 1
      }
    fi
  fi
else
  echo "No backup patch found, trying cherry-pick..."
  git cherry-pick $FEATURE_COMMIT
fi

echo ""
echo "=== Sync complete ==="
echo "Current log:"
git log --oneline -5
echo ""
echo "Build to verify:"
echo "  ./configure.py --bootstrap && ./ninja"
echo ""
echo "Test RAM limit:"
echo "  NINJA_RAM_LIMIT=2g ./ninja -j8 -v"
