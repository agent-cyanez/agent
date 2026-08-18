#!/bin/sh
set -eu

# Creates Forgejo webhooks for standalone project repos
# so pushes to master/main trigger auto-deploy via deploy-webhook.
#
# Requires: admin access to the repos (or a Forgejo admin token).
# Usage: FORGEJO_TOKEN=<admin-token> WEBHOOK_SECRET=<secret> ./setup-deploy-webhooks.sh

FORGEJO_URL="${FORGEJO_URL:-http://nos-nas:3001}"
WEBHOOK_ENDPOINT="http://localhost:9000/hooks/deploy-project"

: "${FORGEJO_TOKEN:?Set FORGEJO_TOKEN to a token with admin access on the target repos}"
: "${WEBHOOK_SECRET:?Set WEBHOOK_SECRET to the deploy webhook HMAC secret}"

REPOS="buda-bot walkingpad kobo-article-pipeline pollaya-bot homepage"

for repo in $REPOS; do
    echo "=== $repo ==="

    existing=$(curl -sf \
        -H "Authorization: token $FORGEJO_TOKEN" \
        "$FORGEJO_URL/api/v1/repos/Nosferath/$repo/hooks" 2>/dev/null \
        | python3 -c "
import sys, json
hooks = json.load(sys.stdin)
for h in hooks:
    if 'deploy-project' in h.get('config', {}).get('url', ''):
        print(h['id'])
        break
" 2>/dev/null || echo "")

    if [ -n "$existing" ]; then
        echo "  Already has deploy webhook (id=$existing), skipping"
        continue
    fi

    response=$(curl -sf -X POST \
        -H "Authorization: token $FORGEJO_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"type\": \"forgejo\",
            \"config\": {
                \"url\": \"$WEBHOOK_ENDPOINT\",
                \"content_type\": \"json\",
                \"secret\": \"$WEBHOOK_SECRET\"
            },
            \"events\": [\"push\"],
            \"branch_filter\": \"master main\",
            \"active\": true
        }" \
        "$FORGEJO_URL/api/v1/repos/Nosferath/$repo/hooks" 2>&1)

    if echo "$response" | python3 -c "import sys,json; h=json.load(sys.stdin); print(f'  Created webhook id={h[\"id\"]}')" 2>/dev/null; then
        :
    else
        echo "  FAILED: $response"
    fi
done

echo ""
echo "Done. Test with: curl -X POST http://localhost:9000/hooks/deploy-project"
echo "(Forgejo will auto-trigger on next push to master/main)"
