#!/usr/bin/env bash
# merge-gate.sh — deterministic self-merge policy enforcement
#
# Inspects a branch diff against its base and classifies changes as
# auto-mergeable or patron-review-required. Returns exit 0 for auto-merge,
# exit 1 for patron-required, exit 2 for errors.
#
# Usage:
#   merge-gate.sh <repo-path> <branch> [base-branch]
#   merge-gate.sh --check <repo-path> <branch> [base-branch]   (dry-run, no merge)
#   merge-gate.sh --explain <repo-path> <branch> [base-branch] (show reasoning)
#
# The script never merges anything itself — it only renders a verdict.

set -euo pipefail

MODE="check"
EXPLAIN=false
NEEDS_TESTS=false

while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --check)   MODE="check"; shift ;;
        --explain) EXPLAIN=true; shift ;;
        *)         echo "Unknown flag: $1" >&2; exit 2 ;;
    esac
done

REPO_PATH="${1:?Usage: merge-gate.sh [--check|--explain] <repo-path> <branch> [base-branch]}"
BRANCH="${2:?Usage: merge-gate.sh [--check|--explain] <repo-path> <branch> [base-branch]}"
BASE="${3:-master}"

if [[ ! -d "$REPO_PATH/.git" ]]; then
    echo "ERROR: $REPO_PATH is not a git repository" >&2
    exit 2
fi

cd "$REPO_PATH"

if ! git rev-parse --verify "$BRANCH" &>/dev/null; then
    echo "ERROR: branch '$BRANCH' does not exist" >&2
    exit 2
fi

if ! git rev-parse --verify "$BASE" &>/dev/null; then
    if git rev-parse --verify "main" &>/dev/null; then
        BASE="main"
    else
        echo "ERROR: base branch '$BASE' does not exist" >&2
        exit 2
    fi
fi

CHANGED_FILES=$(git diff --name-only "$BASE...$BRANCH" 2>/dev/null)

if [[ -z "$CHANGED_FILES" ]]; then
    echo "VERDICT: NO_CHANGES — nothing to merge"
    exit 0
fi

# --- Classification rules ---
# Each changed file is tagged as SAFE or REVIEW. If any file is REVIEW,
# the whole PR requires patron review.

DOMINATED_BY_REVIEW=false
REVIEW_REASONS=()
SAFE_REASONS=()
TEST_REASONS=()

classify_file() {
    local f="$1"

    # === ALWAYS REQUIRE REVIEW ===

    # Database migrations (Rails, Alembic, any framework)
    if [[ "$f" =~ ^db/migrate/ ]] || [[ "$f" == "db/schema.rb" ]]; then
        REVIEW_REASONS+=("MIGRATION: $f")
        DOMINATED_BY_REVIEW=true
        return
    fi

    # Database schema definitions embedded in code
    if [[ "$f" == "src/database.py" ]] || [[ "$f" == "app/database.py" ]]; then
        local diff_content
        diff_content=$(git diff "$BASE...$BRANCH" -- "$f" 2>/dev/null || true)
        if echo "$diff_content" | grep -qiE '(CREATE TABLE|ALTER TABLE|DROP TABLE|ADD COLUMN|schema|migration)'; then
            REVIEW_REASONS+=("SCHEMA_CHANGE: $f")
            DOMINATED_BY_REVIEW=true
            return
        fi
    fi

    # Credential and secret files
    if [[ "$f" == ".env" ]] || [[ "$f" =~ \.env\. ]] || \
       [[ "$f" == "config/credentials.yml.enc" ]] || \
       [[ "$f" =~ (secret|credential|token|key) ]]; then
        REVIEW_REASONS+=("CREDENTIALS: $f")
        DOMINATED_BY_REVIEW=true
        return
    fi

    # Deploy configuration (Kamal, CI/CD)
    if [[ "$f" == "config/deploy.yml" ]] || [[ "$f" == ".kamal/"* ]]; then
        REVIEW_REASONS+=("DEPLOY_CONFIG: $f")
        DOMINATED_BY_REVIEW=true
        return
    fi

    # Auth and security initializers
    if [[ "$f" =~ config/initializers/(content_security_policy|devise|auth|cors) ]]; then
        REVIEW_REASONS+=("SECURITY_CONFIG: $f")
        DOMINATED_BY_REVIEW=true
        return
    fi

    # Route changes (new endpoints = new UX)
    if [[ "$f" == "config/routes.rb" ]]; then
        REVIEW_REASONS+=("ROUTES: $f")
        DOMINATED_BY_REVIEW=true
        return
    fi

    # === CONTEXT-DEPENDENT: compose file changes ===
    if [[ "$f" =~ docker-compose\.ya?ml$ ]]; then
        local diff_content
        diff_content=$(git diff "$BASE...$BRANCH" -- "$f" 2>/dev/null || true)

        # Port changes need review (networking/security)
        if echo "$diff_content" | grep -qE '^\+.*ports:' || \
           echo "$diff_content" | grep -qE '^\+\s*-\s*"?[0-9]+:[0-9]+"?'; then
            REVIEW_REASONS+=("PORT_CHANGE: $f")
            DOMINATED_BY_REVIEW=true
            return
        fi

        # New volume mounts need review (data access)
        if echo "$diff_content" | grep -qE '^\+.*volumes:' || \
           echo "$diff_content" | grep -qE '^\+\s*-\s*[./]'; then
            REVIEW_REASONS+=("VOLUME_CHANGE: $f")
            DOMINATED_BY_REVIEW=true
            return
        fi

        # Network mode changes need review
        if echo "$diff_content" | grep -qE '^\+.*network_mode:'; then
            REVIEW_REASONS+=("NETWORK_CHANGE: $f")
            DOMINATED_BY_REVIEW=true
            return
        fi

        # Image tag bumps, env vars, healthchecks, labels — safe
        SAFE_REASONS+=("COMPOSE_CONFIG: $f (image/env/healthcheck/label change)")
        return
    fi

    # === ALWAYS SAFE ===

    # Lockfiles and dependency pins
    if [[ "$f" =~ (requirements\.lock|Gemfile\.lock|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|poetry\.lock)$ ]]; then
        SAFE_REASONS+=("LOCKFILE: $f")
        return
    fi

    # Dependency declarations (Gemfile, requirements.txt, pyproject.toml deps)
    if [[ "$f" =~ ^(Gemfile|requirements\.txt)$ ]]; then
        SAFE_REASONS+=("DEPENDENCY: $f")
        return
    fi

    # Renovate / CI config
    if [[ "$f" == "renovate.json" ]] || [[ "$f" =~ ^\.forgejo/workflows/ ]] || \
       [[ "$f" =~ ^\.github/workflows/ ]]; then
        SAFE_REASONS+=("CI_CONFIG: $f")
        return
    fi

    # Dockerfile changes (healthchecks, build optimizations)
    if [[ "$f" =~ Dockerfile$ ]]; then
        local diff_content
        diff_content=$(git diff "$BASE...$BRANCH" -- "$f" 2>/dev/null || true)
        # New EXPOSE or USER directives need review
        if echo "$diff_content" | grep -qE '^\+\s*(EXPOSE|USER)\s'; then
            REVIEW_REASONS+=("DOCKERFILE_SECURITY: $f")
            DOMINATED_BY_REVIEW=true
            return
        fi
        SAFE_REASONS+=("DOCKERFILE: $f")
        return
    fi

    # Test files
    if [[ "$f" =~ ^tests?/ ]] || [[ "$f" =~ _test\.(py|rb|js|ts)$ ]] || \
       [[ "$f" =~ test_[^/]*\.(py|rb|js|ts)$ ]]; then
        SAFE_REASONS+=("TEST: $f")
        return
    fi

    # Documentation and config metadata
    if [[ "$f" =~ \.(md|txt|yml|yaml|json|toml|cfg|ini)$ ]] && \
       [[ ! "$f" =~ (database|deploy|secret|credential|auth) ]]; then
        SAFE_REASONS+=("CONFIG/DOCS: $f")
        return
    fi

    # Homepage dashboard config (display-only)
    if [[ "$f" =~ ^config/(services|settings|widgets|bookmarks|docker)\.yaml$ ]]; then
        SAFE_REASONS+=("DASHBOARD_CONFIG: $f")
        return
    fi

    # Static assets
    if [[ "$f" =~ \.(css|scss|html|erb|svg|png|jpg|ico)$ ]]; then
        SAFE_REASONS+=("STATIC: $f")
        return
    fi

    # === SOURCE CODE: auto-merge allowed if tests pass ===
    # Bug fixes with tests are self-mergeable per the contribution framework.
    # The gate flags them as TEST_REQUIRED — caller must run and verify the suite.
    if [[ "$f" =~ \.(py|rb|js|ts|go|rs|ex|exs)$ ]]; then
        TEST_REASONS+=("SOURCE_CODE: $f")
        NEEDS_TESTS=true
        return
    fi

    # Template/view files — test-gated (could change UX, but testable)
    if [[ "$f" =~ \.(erb|jinja2?|hbs|ejs)$ ]]; then
        TEST_REASONS+=("TEMPLATE: $f")
        NEEDS_TESTS=true
        return
    fi

    # Anything else unrecognized — flag for review
    REVIEW_REASONS+=("UNKNOWN: $f")
    DOMINATED_BY_REVIEW=true
}

# Classify every changed file
while IFS= read -r file; do
    classify_file "$file"
done <<< "$CHANGED_FILES"

# --- Verdict ---

if $EXPLAIN || [[ "$MODE" == "check" ]]; then
    echo "=== Merge Gate Analysis ==="
    echo "Repo:   $(basename "$REPO_PATH")"
    echo "Branch: $BRANCH → $BASE"
    echo "Files:  $(echo "$CHANGED_FILES" | wc -l)"
    echo ""

    if [[ ${#SAFE_REASONS[@]} -gt 0 ]]; then
        echo "SAFE (auto-merge allowed):"
        for r in "${SAFE_REASONS[@]}"; do
            echo "  ✓ $r"
        done
    fi

    if [[ ${#TEST_REASONS[@]} -gt 0 ]]; then
        echo ""
        echo "TEST REQUIRED (auto-merge if tests pass):"
        for r in "${TEST_REASONS[@]}"; do
            echo "  ~ $r"
        done
    fi

    if [[ ${#REVIEW_REASONS[@]} -gt 0 ]]; then
        echo ""
        echo "REVIEW REQUIRED (patron must approve):"
        for r in "${REVIEW_REASONS[@]}"; do
            echo "  ✗ $r"
        done
    fi

    echo ""
fi

if $DOMINATED_BY_REVIEW; then
    echo "VERDICT: PATRON_REVIEW — $(echo "${REVIEW_REASONS[*]}" | head -c 200)"
    exit 1
elif $NEEDS_TESTS; then
    echo "VERDICT: TEST_REQUIRED — auto-merge allowed if test suite passes"
    exit 0
else
    echo "VERDICT: AUTO_MERGE — all changes in safe categories"
    exit 0
fi
