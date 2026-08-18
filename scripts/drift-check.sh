#!/bin/sh
set -eu

# Deploy drift detection: compares declared images in docker-compose.yml
# against what's actually running. Alerts via ntfy on mismatch.
#
# Usage: drift-check.sh [--quiet]
#   --quiet: only output if drift is found (for cron use)

PROJECTS_DIR="/home/nosferath/projects"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

quiet=false
[ "${1:-}" = "--quiet" ] && quiet=true

drift_found=""

for compose in "$PROJECTS_DIR"/*/docker-compose.yml; do
    dir=$(dirname "$compose")
    project=$(basename "$dir")

    declared=$(docker compose -f "$compose" config --format json 2>/dev/null \
        | python3 -c "
import sys, json
config = json.load(sys.stdin)
for svc, conf in config.get('services', {}).items():
    img = conf.get('image', '')
    if img and 'build' not in conf:
        print(f'{svc}|{img}')
" 2>/dev/null) || continue

    [ -z "$declared" ] && continue

    running=$(docker compose -f "$compose" ps --format json 2>/dev/null \
        | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    c = json.loads(line)
    print(f'{c[\"Service\"]}|{c[\"Image\"]}|{c[\"State\"]}')
" 2>/dev/null) || continue

    echo "$declared" | while IFS='|' read -r svc declared_img; do
        run_line=$(echo "$running" | grep "^${svc}|" | head -1)

        if [ -z "$run_line" ]; then
            echo "DRIFT $project/$svc: declared=$declared_img but NOT RUNNING"
            echo "$project/$svc NOT_RUNNING" >> /tmp/drift-check.$$
            continue
        fi

        run_img=$(echo "$run_line" | cut -d'|' -f2)
        run_state=$(echo "$run_line" | cut -d'|' -f3)

        if [ "$run_state" != "running" ]; then
            echo "DRIFT $project/$svc: state=$run_state (expected running)"
            echo "$project/$svc STATE=$run_state" >> /tmp/drift-check.$$
            continue
        fi

        if [ "$declared_img" != "$run_img" ]; then
            echo "DRIFT $project/$svc:"
            echo "  declared: $declared_img"
            echo "  running:  $run_img"
            echo "$project/$svc IMAGE_MISMATCH" >> /tmp/drift-check.$$
        fi
    done
done

if [ -f /tmp/drift-check.$$ ]; then
    count=$(wc -l < /tmp/drift-check.$$)
    details=$(cat /tmp/drift-check.$$)
    rm -f /tmp/drift-check.$$

    "$SCRIPT_DIR/ntfy-send.sh" "Deploy drift detected: $count service(s) differ from compose declarations. Run scripts/drift-check.sh for details."
    exit 1
else
    $quiet || echo "No drift detected — all services match their compose declarations."
    rm -f /tmp/drift-check.$$
    exit 0
fi
