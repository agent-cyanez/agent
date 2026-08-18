#!/usr/bin/env bash
# Send a message via ntfy and log it to the outbox.
# Usage: ntfy-send.sh [-t title] message
# The outbox (data/outbox.jsonl) preserves every sent message so future sessions
# can look back at exactly what was communicated.
#
# Topic ("vela") and title ("Vela") are handled automatically.
# Pass ONLY the message body text — do not include topic or title in the message.

set -euo pipefail

VELA_DIR="/home/vela/agent"
NTFY_URL="http://127.0.0.1:8888"
NTFY_TOPIC="vela"
OUTBOX="$VELA_DIR/data/outbox.jsonl"

TITLE="Vela"
while getopts "t:" opt; do
    case $opt in
        t) TITLE="$OPTARG" ;;
        *) ;;
    esac
done
shift $((OPTIND - 1))

MESSAGE="$*"

if [[ -z "$MESSAGE" ]]; then
    echo "Usage: ntfy-send.sh [-t title] message" >&2
    exit 1
fi

# Cooldown: block sends within 90s of the last send to prevent duplicate replies
COOLDOWN_FILE="$VELA_DIR/data/.ntfy-last-send"
COOLDOWN_SECS=90
if [[ -f "$COOLDOWN_FILE" ]]; then
    last_send=$(cat "$COOLDOWN_FILE")
    now=$(date +%s)
    elapsed=$(( now - last_send ))
    if (( elapsed < COOLDOWN_SECS )); then
        echo "[BLOCKED] ntfy send blocked — ${elapsed}s since last send (cooldown ${COOLDOWN_SECS}s). Message NOT sent." >&2
        echo "Blocked message: $MESSAGE" >&2
        exit 1
    fi
fi
date +%s > "$COOLDOWN_FILE"

curl -s "$NTFY_URL/$NTFY_TOPIC" -H "Title: $TITLE" -d "$MESSAGE"

TIMESTAMP=$(date -Iseconds)
python3 -c "
import json, sys
entry = {
    'timestamp': sys.argv[1],
    'topic': sys.argv[2],
    'title': sys.argv[3],
    'message': sys.argv[4]
}
print(json.dumps(entry))
" "$TIMESTAMP" "$NTFY_TOPIC" "$TITLE" "$MESSAGE" >> "$OUTBOX"
