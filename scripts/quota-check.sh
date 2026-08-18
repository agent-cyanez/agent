#!/usr/bin/env bash
# Quick quota check for tick gating.
# Prints the 5-hour utilization percentage to stdout.
# Exits 0 if OK to proceed, 1 if quota is too high.
#
# Key defense: if the cached resets_at is in the past, the quota has
# definitionally reset — return 0 immediately, don't trust stale %.

set -euo pipefail

CACHE_FILE="/home/vela/agent/data/usage-cache.json"
THRESHOLD="${1:-75}"

if [[ ! -f "$CACHE_FILE" ]]; then
    echo "0"
    exit 0
fi

utilization=$(python3 -c "
import json, sys, time
from datetime import datetime, timezone
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    five_hour = data.get('data', {}).get('five_hour', {})
    util = five_hour.get('utilization', 0)
    resets_at = five_hour.get('resets_at', '')

    # If the reset time has passed, the cached % is invalid — quota has reset
    if resets_at:
        reset_dt = datetime.fromisoformat(resets_at)
        if datetime.now(timezone.utc) > reset_dt:
            print(0)
            sys.exit(0)

    print(int(util))
except Exception:
    print(0)
" "$CACHE_FILE" 2>/dev/null)

echo "$utilization"

if (( utilization > THRESHOLD )); then
    exit 1
fi
exit 0
