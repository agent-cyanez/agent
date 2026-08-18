#!/bin/sh
# Browse a URL via Browserless and return the page content.
# Usage: browse.sh <url> [selector]
#   url      — the page to load
#   selector — optional CSS selector to extract (default: body text)
#
# Requires BROWSERLESS_TOKEN in .env and Browserless running on localhost:3100.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$AGENT_DIR/.env" ]; then
    export $(grep -v '^#' "$AGENT_DIR/.env" | grep BROWSERLESS_TOKEN | xargs)
fi

URL="${1:?Usage: browse.sh <url> [selector]}"
SELECTOR="${2:-body}"
BROWSERLESS_URL="http://127.0.0.1:3100"
ALLOWLIST="$AGENT_DIR/config/domain-allowlist.txt"

# Extract domain from URL and check against allowlist
DOMAIN=$(echo "$URL" | sed -E 's|^https?://||' | sed 's|/.*||' | sed 's|:.*||')
if [ -f "$ALLOWLIST" ]; then
    if ! grep -qxF "$DOMAIN" <(grep -v '^#' "$ALLOWLIST" | grep -v '^$'); then
        echo "BLOCKED: domain '$DOMAIN' is not on the allowlist ($ALLOWLIST)" >&2
        echo "To allow this domain, add it to $ALLOWLIST" >&2
        exit 1
    fi
fi

curl -s "${BROWSERLESS_URL}/content?token=${BROWSERLESS_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "{
    \"url\": \"${URL}\",
    \"waitForSelector\": { \"selector\": \"${SELECTOR}\", \"timeout\": 15000 },
    \"gotoOptions\": { \"waitUntil\": \"networkidle2\", \"timeout\": 30000 }
  }"
