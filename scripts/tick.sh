#!/usr/bin/env bash
# Vela tick — cron entry point
# Runs every N minutes. Invokes Claude CLI to perform a work cycle.

set -euo pipefail

export PATH="/home/vela/.local/bin:$PATH"

VELA_DIR="/home/vela/agent"
DATA_DIR="$VELA_DIR/data"
LOCK_FILE="$DATA_DIR/tick.lock"
LOG_FILE="$DATA_DIR/tick.log"
TIMING_FILE="$DATA_DIR/tick-times.csv"

NOW_ISO=$(date -Iseconds)
NOW_EPOCH=$(date +%s)
TODAY=$(date +%Y-%m-%d)
STALE_LOCK_SECONDS=1800
MAX_DAILY_SESSIONS=${VELA_MAX_DAILY_SESSIONS:-20}
SESSION_COUNT_FILE="$DATA_DIR/sessions-$TODAY.count"

cleanup() {
    local end_epoch=$(date +%s)
    local duration=$(( end_epoch - NOW_EPOCH ))
    echo "$NOW_ISO,$duration,$exit_code" >> "$TIMING_FILE"
    rm -f "$LOCK_FILE"
}

get_daily_sessions() {
    if [[ -f "$SESSION_COUNT_FILE" ]]; then
        cat "$SESSION_COUNT_FILE"
    else
        echo 0
    fi
}

increment_session_count() {
    local current
    current=$(get_daily_sessions)
    echo $(( current + 1 )) > "$SESSION_COUNT_FILE"
}

WAKE_HOUR=${VELA_WAKE_HOUR:-9}
SLEEP_HOUR=${VELA_SLEEP_HOUR:-0}

mkdir -p "$DATA_DIR"

# Night guard — sleep between SLEEP_HOUR and WAKE_HOUR
current_hour=$(date +%-H)
if (( current_hour < WAKE_HOUR )); then
    echo "$NOW_ISO [SLEEP] hour=$current_hour, waking at $WAKE_HOUR:00" >> "$LOG_FILE"
    exit 0
fi

# Lock management — prevent overlapping ticks
if [[ -f "$LOCK_FILE" ]]; then
    lock_age=$(( NOW_EPOCH - $(stat -c %Y "$LOCK_FILE") ))
    if (( lock_age < STALE_LOCK_SECONDS )); then
        echo "$NOW_ISO [SKIP] locked (age=${lock_age}s)" >> "$LOG_FILE"
        exit 0
    fi
    rm -f "$LOCK_FILE"
fi

echo $$ > "$LOCK_FILE"
exit_code=0
trap cleanup EXIT

NOW_CLT=$(TZ=America/Santiago date '+%H:%M CLT')

PROMPT="You are Vela, an autonomous AI agent. This is a tick — your regular work cycle.
Current time: $NOW_CLT

Read IDENTITY.md for who you are.
Read log/ for recent context (latest file first).

Tick routine:
1. Check for anything that needs immediate attention (CI failures, deployment issues, errors from last tick)
2. Advance current projects — pick up where you left off
3. If idle, choose new work aligned with your strategy
4. Add a brief entry to log/$TODAY.md using the header format: ## Tick ($NOW_CLT)
   - If the file has existing entries, INSERT your entry at the correct chronological position (by comparing timestamps in ## headers), not at the end. This prevents out-of-order entries when concurrent sessions write to the same file.
5. Commit changes to git and push to GitHub
6. If something noteworthy happened, send a brief ntfy update: scripts/ntfy-send.sh 'message'

Be efficient — this runs frequently. If there's nothing to do, log that and exit quickly.
Do not check financial balances every tick — only when relevant to a financial decision.
Do not ask questions — decide and act within the hard boundaries."

daily_count=$(get_daily_sessions)
if (( daily_count >= MAX_DAILY_SESSIONS )); then
    echo "$NOW_ISO [BUDGET] $daily_count/$MAX_DAILY_SESSIONS sessions used today, skipping" >> "$LOG_FILE"
    exit 0
fi

echo "$NOW_ISO [START] tick ($((daily_count+1))/$MAX_DAILY_SESSIONS)" >> "$LOG_FILE"
increment_session_count

cd "$VELA_DIR"
claude --print --dangerously-skip-permissions -p "$PROMPT" >> "$LOG_FILE" 2>&1
exit_code=$?

echo "$(date -Iseconds) [END] tick (exit=$exit_code)" >> "$LOG_FILE"
