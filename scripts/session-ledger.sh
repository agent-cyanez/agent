#!/usr/bin/env bash
# Session execution ledger — cross-session awareness for Vela
#
# Provides every session with context about recent and concurrent executions.
# Prevents duplicate work and gives continuity across independent sessions.
#
# Usage:
#   session-ledger.sh start TYPE TRIGGER [MSG_ID]  — record start, print session ID
#   session-ledger.sh end SESSION_ID [SUMMARY]     — record completion
#   session-ledger.sh check MSG_ID                 — exit 0 if already processed, 1 if new
#   session-ledger.sh context [HOURS]              — print recent session context for prompt
#   session-ledger.sh active                       — list currently running sessions

set -euo pipefail

LEDGER_FILE="/home/vela/agent/data/session-ledger.jsonl"
LOCK_FILE="/home/vela/agent/data/session-ledger.lock"

mkdir -p "$(dirname "$LEDGER_FILE")"

_lock() {
    exec 9>"$LOCK_FILE"
    flock -w 5 9
}

_unlock() {
    exec 9>&-
}

_generate_id() {
    python3 -c "import uuid; print(str(uuid.uuid4())[:8])"
}

_now() {
    date -Iseconds
}

cmd_start() {
    local type="${1:?Usage: session-ledger.sh start TYPE TRIGGER [MSG_ID]}"
    local trigger="${2:?Usage: session-ledger.sh start TYPE TRIGGER [MSG_ID]}"
    local msg_id="${3:-}"
    local session_id
    session_id=$(_generate_id)

    local record
    record=$(python3 -c "
import json, sys
r = {'ts': sys.argv[1], 'session': sys.argv[2], 'type': sys.argv[3],
     'trigger': sys.argv[4], 'event': 'start'}
if sys.argv[5]:
    r['msg_id'] = sys.argv[5]
print(json.dumps(r))
" "$(_now)" "$session_id" "$type" "$trigger" "$msg_id")

    _lock
    echo "$record" >> "$LEDGER_FILE"
    _unlock

    echo "$session_id"
}

cmd_end() {
    local session_id="${1:?Usage: session-ledger.sh end SESSION_ID [SUMMARY]}"
    local summary="${2:-}"

    local record
    record=$(python3 -c "
import json, sys
r = {'ts': sys.argv[1], 'session': sys.argv[2], 'event': 'end'}
if sys.argv[3]:
    r['summary'] = sys.argv[3]
print(json.dumps(r))
" "$(_now)" "$session_id" "$summary")

    _lock
    echo "$record" >> "$LEDGER_FILE"
    _unlock
}

cmd_check() {
    local msg_id="${1:?Usage: session-ledger.sh check MSG_ID}"

    if [[ ! -f "$LEDGER_FILE" ]]; then
        return 1
    fi

    python3 -c "
import json, sys
msg_id = sys.argv[1]
with open(sys.argv[2]) as f:
    for line in f:
        try:
            r = json.loads(line)
            if r.get('msg_id') == msg_id and r.get('event') == 'start':
                sys.exit(0)
        except json.JSONDecodeError:
            continue
sys.exit(1)
" "$msg_id" "$LEDGER_FILE"
}

cmd_active() {
    if [[ ! -f "$LEDGER_FILE" ]]; then
        echo "No sessions recorded."
        return
    fi

    python3 -c "
import json, sys
started = {}
with open(sys.argv[1]) as f:
    for line in f:
        try:
            r = json.loads(line)
            sid = r.get('session', '')
            if r.get('event') == 'start':
                started[sid] = r
            elif r.get('event') == 'end':
                started.pop(sid, None)
        except json.JSONDecodeError:
            continue
if not started:
    print('No active sessions.')
else:
    for sid, r in started.items():
        print(f'{r[\"ts\"]} [{r[\"type\"]}] session={sid} trigger={r[\"trigger\"]}')
" "$LEDGER_FILE"
}

cmd_context() {
    local hours="${1:-6}"

    if [[ ! -f "$LEDGER_FILE" ]]; then
        echo "No prior sessions recorded."
        return
    fi

    python3 -c "
import json, sys, datetime

hours = int(sys.argv[2])
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours)

sessions = {}
with open(sys.argv[1]) as f:
    for line in f:
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue
        sid = r.get('session', '')
        ts_str = r.get('ts', '')
        try:
            ts = datetime.datetime.fromisoformat(ts_str)
            if ts.tzinfo is None:
                ts = ts.replace(tzinfo=datetime.timezone.utc)
        except (ValueError, TypeError):
            continue
        if ts < cutoff:
            continue
        if r.get('event') == 'start':
            sessions[sid] = {'start': ts_str, 'type': r.get('type', '?'),
                             'trigger': r.get('trigger', '?'),
                             'msg_id': r.get('msg_id', ''),
                             'end': None, 'summary': None}
        elif r.get('event') == 'end' and sid in sessions:
            sessions[sid]['end'] = ts_str
            sessions[sid]['summary'] = r.get('summary', '')

# Print active sessions first
active = {k: v for k, v in sessions.items() if v['end'] is None}
completed = {k: v for k, v in sessions.items() if v['end'] is not None}

if active:
    print('CURRENTLY RUNNING:')
    for sid, s in active.items():
        line = f'  {s[\"start\"]} [{s[\"type\"]}] trigger={s[\"trigger\"]}'
        if s['msg_id']:
            line += f' msg={s[\"msg_id\"]}'
        print(line)
    print()

if completed:
    print(f'RECENT SESSIONS (last {hours}h):')
    items = sorted(completed.items(), key=lambda x: x[1]['start'], reverse=True)
    for sid, s in items[-10:]:
        line = f'  {s[\"start\"]} [{s[\"type\"]}]'
        if s['summary']:
            line += f' — {s[\"summary\"]}'
        print(line)
elif not active:
    print(f'No sessions in the last {hours}h.')
" "$LEDGER_FILE" "$hours"
}

case "${1:-}" in
    start)   shift; cmd_start "$@" ;;
    end)     shift; cmd_end "$@" ;;
    check)   shift; cmd_check "$@" ;;
    active)  shift; cmd_active "$@" ;;
    context) shift; cmd_context "$@" ;;
    *)
        echo "Usage: session-ledger.sh {start|end|check|active|context} [args...]" >&2
        exit 1
        ;;
esac
