#!/usr/bin/env bash
# renovate-conflict-check.sh — detect Renovate PRs that conflict with disabled rules
#
# Reads renovate.json from the repo, extracts packages with enabled:false,
# then checks if the PR's changed files update any of those packages.
#
# Usage: renovate-conflict-check.sh <repo-path> <branch> [base-branch]
# Exit 0: no conflict. Exit 1: conflict found. Exit 2: error.

set -euo pipefail

REPO_PATH="${1:?Usage: renovate-conflict-check.sh <repo-path> <branch> [base-branch]}"
BRANCH="${2:?Usage: renovate-conflict-check.sh <repo-path> <branch> [base-branch]}"
BASE="${3:-master}"

if [[ ! -d "$REPO_PATH/.git" ]]; then
    echo "ERROR: $REPO_PATH is not a git repository" >&2
    exit 2
fi

cd "$REPO_PATH"

RENOVATE_JSON=""
for f in renovate.json .renovaterc .renovaterc.json; do
    if git show "$BASE:$f" &>/dev/null 2>&1; then
        RENOVATE_JSON=$(git show "$BASE:$f" 2>/dev/null)
        break
    fi
done

if [[ -z "$RENOVATE_JSON" ]]; then
    exit 0
fi

TMPFILE=$(mktemp)
echo "$RENOVATE_JSON" > "$TMPFILE"
trap 'rm -f "$TMPFILE"' EXIT

DISABLED_PACKAGES=$(python3 -c "
import json, re, sys

with open('$TMPFILE') as f:
    raw = f.read()

try:
    config = json.loads(raw)
except json.JSONDecodeError:
    raw = re.sub(r'\\\\(?![\"\\\\\/bfnrtu])', r'\\\\\\\\', raw)
    try:
        config = json.loads(raw)
    except Exception:
        sys.exit(0)

for rule in config.get('packageRules', []):
    blocked = rule.get('enabled') is False or 'allowedVersions' in rule
    if blocked:
        constraint = rule.get('allowedVersions', 'disabled')
        for n in rule.get('matchPackageNames', []):
            print(f'{n}|{constraint}')
        for p in rule.get('matchPackagePatterns', []):
            print(f'PATTERN:{p}|{constraint}')
" 2>/dev/null)

if [[ -z "$DISABLED_PACKAGES" ]]; then
    exit 0
fi

BRANCH_TITLE=$(git log --format='%s' "$BASE..$BRANCH" 2>/dev/null | head -1)

# Revert branches restore the prior state — they are the fix, not the problem
if [[ "$BRANCH_TITLE" == Revert* ]] || [[ "$BRANCH" == *revert* ]]; then
    echo "OK: revert branch, skipping conflict check"
    exit 0
fi

DIFF_CONTENT=$(git diff "$BASE...$BRANCH" 2>/dev/null)

CONFLICTS=()
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pkg="${line%%|*}"
    constraint="${line#*|}"
    if [[ "$pkg" == PATTERN:* ]]; then
        continue
    fi
    pkg_lower=$(echo "$pkg" | tr '[:upper:]' '[:lower:]')
    title_lower=$(echo "$BRANCH_TITLE" | tr '[:upper:]' '[:lower:]')
    if echo "$title_lower" | grep -qi "$pkg_lower"; then
        CONFLICTS+=("$pkg [constraint: $constraint] (found in branch title: $BRANCH_TITLE)")
        continue
    fi
    if echo "$DIFF_CONTENT" | grep -qi "\"$pkg_lower\"\|: *$pkg_lower\|FROM $pkg_lower"; then
        CONFLICTS+=("$pkg [constraint: $constraint] (found in diff)")
    fi
done <<< "$DISABLED_PACKAGES"

if [[ ${#CONFLICTS[@]} -gt 0 ]]; then
    echo "CONFLICT: PR updates packages with version constraints in renovate.json:"
    for c in "${CONFLICTS[@]}"; do
        echo "  ✗ $c"
    done
    echo ""
    echo "Check renovate.json packageRules for the constraint reason before merging."
    exit 1
fi

echo "OK: no conflicts with constrained Renovate packages"
exit 0
