#!/bin/sh
set -eu

# Sync all Vela repo clones with their remotes.
# Switches to default branch, fast-forward pulls, and prunes merged branches.
# Safe: never force-pushes or discards uncommitted work.

REPOS_DIR="/home/vela/repos"
DEFAULT_BRANCH="master"

log() { echo "[sync-repos] $*"; }

synced=0
errors=0

for repo_dir in "$REPOS_DIR"/*/; do
    [ -d "$repo_dir/.git" ] || continue
    name=$(basename "$repo_dir")

    if [ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]; then
        log "$name: dirty working tree, skipping"
        continue
    fi

    git -C "$repo_dir" fetch --prune origin 2>/dev/null || {
        log "$name: fetch failed"
        errors=$((errors + 1))
        continue
    }

    branch=$(git -C "$repo_dir" symbolic-ref --short HEAD 2>/dev/null || echo "")
    target="$DEFAULT_BRANCH"
    if ! git -C "$repo_dir" rev-parse --verify "origin/$target" >/dev/null 2>&1; then
        target="main"
    fi

    if [ "$branch" != "$target" ]; then
        git -C "$repo_dir" checkout "$target" 2>/dev/null || {
            log "$name: checkout $target failed"
            errors=$((errors + 1))
            continue
        }
    fi

    local_head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null)
    remote_head=$(git -C "$repo_dir" rev-parse "origin/$target" 2>/dev/null)
    if [ "$local_head" != "$remote_head" ]; then
        if git -C "$repo_dir" merge-base --is-ancestor "origin/$target" HEAD 2>/dev/null; then
            # Local is ahead — reset to origin (work should be on branches, not local master)
            git -C "$repo_dir" reset --hard "origin/$target" 2>/dev/null
            log "$name: reset $target to origin (was ahead)"
        elif ! git -C "$repo_dir" merge --ff-only "origin/$target" 2>/dev/null; then
            log "$name: ff-only merge failed (local diverged?)"
            errors=$((errors + 1))
            continue
        fi
    fi

    # Prune local branches already merged or with deleted remotes
    merged=$(git -C "$repo_dir" branch --merged "$target" 2>/dev/null | grep -v "^\*" | grep -vE "^\s*(master|main)\s*$" || true)
    if [ -n "$merged" ]; then
        for b in $merged; do
            git -C "$repo_dir" branch -d "$b" 2>/dev/null && log "$name: pruned merged branch $b"
        done
    fi

    # Prune branches whose remote tracking branch is gone
    gone=$(git -C "$repo_dir" branch -v 2>/dev/null | grep '\[gone\]' | awk '{print $1}' || true)
    if [ -n "$gone" ]; then
        for b in $gone; do
            git -C "$repo_dir" branch -D "$b" 2>/dev/null && log "$name: pruned gone branch $b"
        done
    fi

    synced=$((synced + 1))
done

log "Done: $synced synced, $errors errors"
