#!/usr/bin/env bash
# Quick quota check for tick gating.
# Exits 0 if OK to proceed, 1 if quota is too high.
# Prints the 5-hour utilization percentage to stdout.
# Uses cached data from usage-report.py (no API call — reads cache only).

set -euo pipefail

CACHE_FILE="/home/vela/agent/data/usage-cache.json"
THRESHOLD="${1:-75}"

if [[ ! -f "$CACHE_FILE" ]]; then
    echo "0"
    exit 0
fi

utilization=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    five_hour = data.get('data', {}).get('five_hour', {})
    util = five_hour.get('utilization', 0)
    print(int(util))
except Exception:
    print('0')
" "$CACHE_FILE")

echo "$utilization"

if (( utilization > THRESHOLD )); then
    exit 1
fi
exit 0
