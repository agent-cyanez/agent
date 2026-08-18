#!/usr/bin/env bash
# Validate tick.sh integrity.
# Can be run standalone or called from pre-commit / watchdog contexts.
# Exit 0 = healthy, Exit 1 = problem found.

set -euo pipefail

VELA_DIR="/home/vela/agent"
TICK_SCRIPT="$VELA_DIR/scripts/tick.sh"
LISTEN_SCRIPT="$VELA_DIR/scripts/listen.sh"
TIMING_FILE="$VELA_DIR/data/tick-times.csv"
TICK_LOG="$VELA_DIR/data/tick.log"

ERRORS=0

check_syntax() {
    local script="$1"
    if [[ -f "$script" ]]; then
        if ! bash -n "$script" 2>/dev/null; then
            echo "CRITICAL: syntax error in $script"
            bash -n "$script" 2>&1 | head -5
            ERRORS=$((ERRORS + 1))
        fi
    fi
}

check_consecutive_failures() {
    if [[ ! -f "$TIMING_FILE" ]]; then
        return
    fi

    local threshold=${1:-3}
    local consecutive=0
    local failed_times=()

    while IFS=, read -r timestamp duration exit_code; do
        if [[ "$duration" == "0" ]]; then
            # Check if this was a legitimate skip (budget, sleep, lock)
            local time_prefix="${timestamp%%T*}T${timestamp#*T}"
            if grep -qF "[BUDGET]" <<< "$(grep "$timestamp" "$TICK_LOG" 2>/dev/null)" || \
               grep -qF "[SLEEP]"  <<< "$(grep "$timestamp" "$TICK_LOG" 2>/dev/null)" || \
               grep -qF "[SKIP]"   <<< "$(grep "$timestamp" "$TICK_LOG" 2>/dev/null)"; then
                consecutive=0
            else
                consecutive=$((consecutive + 1))
                failed_times+=("$timestamp")
            fi
        else
            consecutive=0
            failed_times=()
        fi
    done < <(tail -20 "$TIMING_FILE")

    if (( consecutive >= threshold )); then
        echo "WARNING: $consecutive consecutive zero-duration ticks without budget/skip entries"
        echo "Affected: ${failed_times[*]:(-$threshold)}"
        ERRORS=$((ERRORS + 1))
    fi
}

# Run checks
check_syntax "$TICK_SCRIPT"
check_syntax "$LISTEN_SCRIPT"

for script in "$VELA_DIR"/scripts/*.sh; do
    check_syntax "$script"
done

check_consecutive_failures 3

if (( ERRORS > 0 )); then
    exit 1
fi

exit 0
