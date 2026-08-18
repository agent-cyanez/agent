#!/usr/bin/env bash
# Insert a log entry at the correct chronological position in a daily log file.
# Usage: log-entry.sh "## Header (HH:MM CLT)" <<'EOF'
# entry body lines
# EOF
#
# If no log file exists for today, creates one. If the file exists, inserts
# the entry at the correct position by comparing the HH:MM timestamps in
# ## headers. This replaces the soft prompt instruction "insert at the right
# position" with a mechanical guarantee.

set -euo pipefail

VELA_DIR="/home/vela/agent"
LOG_DIR="$VELA_DIR/log"
TODAY=$(date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/$TODAY.md"

HEADER="$1"
BODY=$(cat)

# Extract HH:MM from the header (looks for patterns like (HH:MM CLT) or (HH:MM))
NEW_TIME=$(echo "$HEADER" | grep -oP '\d{2}:\d{2}' | head -1)
if [[ -z "$NEW_TIME" ]]; then
    echo "ERROR: Could not extract HH:MM timestamp from header: $HEADER" >&2
    exit 1
fi
NEW_MINUTES=$(( 10#${NEW_TIME%%:*} * 60 + 10#${NEW_TIME##*:} ))

FULL_ENTRY="$HEADER

$BODY"

if [[ ! -f "$LOG_FILE" ]]; then
    printf "# %s\n\n%s\n" "$TODAY" "$FULL_ENTRY" > "$LOG_FILE"
    exit 0
fi

# Find all ## header lines with their line numbers and timestamps
# Build an array of (line_number, minutes) pairs
declare -a POSITIONS=()
declare -a TIMES=()

while IFS= read -r line; do
    lineno=$(echo "$line" | cut -d: -f1)
    header_text=$(echo "$line" | cut -d: -f2-)
    time_str=$(echo "$header_text" | grep -oP '\d{2}:\d{2}' | head -1)
    if [[ -n "$time_str" ]]; then
        minutes=$(( 10#${time_str%%:*} * 60 + 10#${time_str##*:} ))
        POSITIONS+=("$lineno")
        TIMES+=("$minutes")
    fi
done < <(grep -n '^## ' "$LOG_FILE")

if [[ ${#POSITIONS[@]} -eq 0 ]]; then
    # No existing ## headers with timestamps — append
    printf "\n%s\n" "$FULL_ENTRY" >> "$LOG_FILE"
    exit 0
fi

# Find the right insertion point: after the last entry whose timestamp <= NEW_TIME
INSERT_AFTER_IDX=-1
for i in "${!TIMES[@]}"; do
    if (( TIMES[i] <= NEW_MINUTES )); then
        INSERT_AFTER_IDX=$i
    fi
done

TOTAL_LINES=$(wc -l < "$LOG_FILE")

if (( INSERT_AFTER_IDX == -1 )); then
    # New entry is earlier than all existing entries — insert before the first ## header
    INSERT_LINE=$(( POSITIONS[0] - 1 ))
    # Find a good insertion point (after any blank lines before the first header)
    while (( INSERT_LINE > 1 )) && [[ -z "$(sed -n "${INSERT_LINE}p" "$LOG_FILE")" ]]; do
        INSERT_LINE=$(( INSERT_LINE - 1 ))
    done
elif (( INSERT_AFTER_IDX == ${#POSITIONS[@]} - 1 )); then
    # New entry goes after the last header — append at end
    printf "\n%s\n" "$FULL_ENTRY" >> "$LOG_FILE"
    exit 0
else
    # Insert between INSERT_AFTER_IDX and INSERT_AFTER_IDX+1
    # Find the line just before the next header
    NEXT_HEADER_LINE=${POSITIONS[$((INSERT_AFTER_IDX + 1))]}
    INSERT_LINE=$(( NEXT_HEADER_LINE - 1 ))
    # Back up over blank lines
    while (( INSERT_LINE > 1 )) && [[ -z "$(sed -n "${INSERT_LINE}p" "$LOG_FILE")" ]]; do
        INSERT_LINE=$(( INSERT_LINE - 1 ))
    done
fi

# Split file and reassemble
{
    head -n "$INSERT_LINE" "$LOG_FILE"
    printf "\n%s\n" "$FULL_ENTRY"
    tail -n +"$((INSERT_LINE + 1))" "$LOG_FILE"
} > "$LOG_FILE.tmp"

mv "$LOG_FILE.tmp" "$LOG_FILE"
