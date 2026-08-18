#!/usr/bin/env bash
# Vela project tracker — CLI wrapping Forgejo Issues on vela/agent
#
# Usage:
#   tracker.sh add "title" [-l label] [-b "body"]   Create a new task
#   tracker.sh list [label]                          List open tasks (optionally filtered by label)
#   tracker.sh next                                  Show highest-priority unblocked task
#   tracker.sh stale [days]                           Show tasks not updated in N days (default: 3)
#   tracker.sh update ID "comment"                   Add a comment to a task (resets staleness)
#   tracker.sh label ID label                        Add a label to a task
#   tracker.sh unlabel ID label                      Remove a label from a task
#   tracker.sh close ID ["comment"]                  Close a task with optional comment
#   tracker.sh reopen ID                             Reopen a closed task
#   tracker.sh show ID                               Show task details
#   tracker.sh summary                               One-line-per-task overview for tick consumption
#   tracker.sh promote ID ["comment"]                 Move backlog → active

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../.env" 2>/dev/null || true

FORGEJO_URL="${FORGEJO_URL:-http://nos-nas:3001}"
REPO="vela/agent"
API="$FORGEJO_URL/api/v1/repos/$REPO"
AUTH="Authorization: token $FORGEJO_TOKEN"

_api() {
    local method="$1" path="$2"
    shift 2
    curl -sf -X "$method" "$API$path" -H "$AUTH" -H "Content-Type: application/json" "$@"
}

_api_raw() {
    local method="$1" path="$2"
    shift 2
    curl -s -X "$method" "$API$path" -H "$AUTH" -H "Content-Type: application/json" "$@"
}

_label_id() {
    local name="$1"
    _api GET "/labels" | python3 -c "
import sys, json
labels = json.load(sys.stdin)
for l in labels:
    if l['name'] == '$name':
        print(l['id'])
        break
" 2>/dev/null
}

cmd_add() {
    local title="$1"; shift
    local body="" labels=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -l|--label) labels+=("$2"); shift 2 ;;
            -b|--body) body="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local label_args=""
    for lbl in "${labels[@]}"; do
        label_args="$label_args $lbl"
    done

    local result
    result=$(python3 -c "
import json, sys, subprocess, os
api = '$API'
auth = 'token ' + os.environ.get('FORGEJO_TOKEN', '$FORGEJO_TOKEN')

label_names = '''$label_args'''.split()
label_ids = []
if label_names:
    r = subprocess.run(['curl', '-sf', api + '/labels', '-H', 'Authorization: ' + auth],
                       capture_output=True, text=True)
    if r.returncode == 0:
        all_labels = json.loads(r.stdout)
        for l in all_labels:
            if l['name'] in label_names:
                label_ids.append(l['id'])

payload = json.dumps({
    'title': sys.argv[1],
    'body': sys.argv[2],
    'labels': label_ids
})
r = subprocess.run(['curl', '-sf', '-X', 'POST', api + '/issues',
                     '-H', 'Authorization: ' + auth,
                     '-H', 'Content-Type: application/json',
                     '-d', payload], capture_output=True, text=True)
if r.returncode == 0:
    d = json.loads(r.stdout)
    print(f\"#{d['number']}: {d['title']}\")
else:
    print('ERROR: ' + r.stderr, file=sys.stderr)
    sys.exit(1)
" "$title" "$body")
    echo "Created issue $result"
}

cmd_list() {
    local label="${1:-}"
    local query="/issues?state=open&type=issues&limit=50&sort=updated&direction=desc"
    [[ -n "$label" ]] && query="$query&labels=$label"

    _api GET "$query" | python3 -c "
import sys, json
issues = json.load(sys.stdin)
if not issues:
    print('No tasks found.')
else:
    for i in issues:
        labels = ', '.join(l['name'] for l in i.get('labels', []))
        labels_str = f' [{labels}]' if labels else ''
        print(f\"#{i['number']:>3} {i['title']}{labels_str}\")
" 2>/dev/null
}

cmd_next() {
    _api GET "/issues?state=open&type=issues&limit=50&sort=updated&direction=desc" | python3 -c "
import sys, json
issues = json.load(sys.stdin)
# Filter out blocked and waiting-review items
actionable = [i for i in issues if not any(l['name'] in ('blocked', 'waiting-review') for l in i.get('labels', []))]
if not actionable:
    # If everything is blocked, show what's blocked
    blocked = [i for i in issues if any(l['name'] == 'blocked' for l in i.get('labels', []))]
    if blocked:
        print('All tasks are blocked or waiting. Blocked items:')
        for i in blocked:
            print(f\"  #{i['number']} {i['title']}\")
    else:
        print('No open tasks.')
else:
    # Prioritize: active > backlog > unlabeled
    active = [i for i in actionable if any(l['name'] == 'active' for l in i.get('labels', []))]
    target = active[0] if active else actionable[0]
    labels = ', '.join(l['name'] for l in target.get('labels', []))
    print(f\"#{target['number']} [{labels}] {target['title']}\")
    if target.get('body'):
        body_lines = target['body'].strip().split('\n')
        for line in body_lines[:5]:
            print(f'  {line}')
" 2>/dev/null
}

cmd_stale() {
    local days="${1:-3}"
    _api GET "/issues?state=open&type=issues&limit=50&sort=updated&direction=asc" | python3 -c "
import sys, json
from datetime import datetime, timezone, timedelta

issues = json.load(sys.stdin)
cutoff = datetime.now(timezone.utc) - timedelta(days=$days)
stale = []
for i in issues:
    updated = datetime.fromisoformat(i['updated_at'].replace('Z', '+00:00'))
    if updated < cutoff:
        age = (datetime.now(timezone.utc) - updated).days
        labels = ', '.join(l['name'] for l in i.get('labels', []))
        stale.append((age, i['number'], i['title'], labels))

if not stale:
    print(f'No tasks stale for {$days}+ days.')
else:
    print(f'{len(stale)} stale task(s) (not updated in {$days}+ days):')
    for age, num, title, labels in sorted(stale, reverse=True):
        lbl = f' [{labels}]' if labels else ''
        print(f'  #{num} ({age}d stale) {title}{lbl}')
" 2>/dev/null
}

cmd_update() {
    local id="$1" comment="$2"
    local payload
    payload=$(python3 -c "import json,sys; print(json.dumps({'body': sys.argv[1]}))" "$comment")
    _api_raw POST "/issues/$id/comments" -d "$payload" >/dev/null
    echo "Updated #$id"
}

cmd_label() {
    local id="$1" label="$2"
    local lid
    lid=$(_label_id "$label")
    if [[ -z "$lid" ]]; then
        echo "Label '$label' not found" >&2
        return 1
    fi
    _api_raw POST "/issues/$id/labels" -d "{\"labels\":[$lid]}" >/dev/null
    echo "Added label '$label' to #$id"
}

cmd_unlabel() {
    local id="$1" label="$2"
    local lid
    lid=$(_label_id "$label")
    if [[ -z "$lid" ]]; then
        echo "Label '$label' not found" >&2
        return 1
    fi
    _api_raw DELETE "/issues/$id/labels/$lid" >/dev/null
    echo "Removed label '$label' from #$id"
}

cmd_close() {
    local id="$1"
    local comment="${2:-}"
    if [[ -n "$comment" ]]; then
        local payload
        payload=$(python3 -c "import json,sys; print(json.dumps({'body': sys.argv[1]}))" "$comment")
        _api_raw POST "/issues/$id/comments" -d "$payload" >/dev/null
    fi
    _api_raw PATCH "/issues/$id" -d '{"state":"closed"}' >/dev/null
    echo "Closed #$id"
}

cmd_reopen() {
    local id="$1"
    _api_raw PATCH "/issues/$id" -d '{"state":"open"}' >/dev/null
    echo "Reopened #$id"
}

cmd_show() {
    local id="$1"
    _api GET "/issues/$id" | python3 -c "
import sys, json
from datetime import datetime, timezone

i = json.load(sys.stdin)
labels = ', '.join(l['name'] for l in i.get('labels', []))
created = datetime.fromisoformat(i['created_at'].replace('Z', '+00:00'))
updated = datetime.fromisoformat(i['updated_at'].replace('Z', '+00:00'))
age = (datetime.now(timezone.utc) - updated).days

print(f\"#{i['number']} {i['title']}\")
print(f'  State: {i[\"state\"]}')
print(f'  Labels: {labels or \"none\"}')
print(f'  Created: {created.strftime(\"%Y-%m-%d %H:%M\")}')
print(f'  Updated: {updated.strftime(\"%Y-%m-%d %H:%M\")} ({age}d ago)')
if i.get('body'):
    print(f'  ---')
    for line in i['body'].strip().split('\n'):
        print(f'  {line}')
" 2>/dev/null
}

cmd_summary() {
    _api GET "/issues?state=open&type=issues&limit=50&sort=priority&direction=desc" | python3 -c "
import sys, json
from datetime import datetime, timezone

issues = json.load(sys.stdin)
if not issues:
    print('No open tasks.')
    sys.exit(0)

now = datetime.now(timezone.utc)
active, blocked, waiting, backlog, other = [], [], [], [], []
for i in issues:
    label_names = {l['name'] for l in i.get('labels', [])}
    updated = datetime.fromisoformat(i['updated_at'].replace('Z', '+00:00'))
    age = (now - updated).days
    stale_marker = ' ⚠' if age >= 3 else ''
    entry = f\"#{i['number']:>3} {i['title']}{stale_marker}\"

    if 'active' in label_names: active.append(entry)
    elif 'blocked' in label_names: blocked.append(entry)
    elif 'waiting-review' in label_names: waiting.append(entry)
    elif 'backlog' in label_names: backlog.append(entry)
    else: other.append(entry)

if active:
    print('ACTIVE:')
    for e in active: print(f'  {e}')
if blocked:
    print('BLOCKED:')
    for e in blocked: print(f'  {e}')
if waiting:
    print('WAITING:')
    for e in waiting: print(f'  {e}')
if backlog:
    print('BACKLOG:')
    for e in backlog: print(f'  {e}')
if other:
    print('OTHER:')
    for e in other: print(f'  {e}')

# Anti-passivity warning: if there's nothing active (only blocked/waiting), and there IS backlog, say so loudly
if not active and (blocked or waiting) and backlog:
    print()
    print('WARNING: No active work — all items are blocked or waiting. Promote from backlog or find new work.')
elif not active and not backlog and not other:
    print()
    print('WARNING: No active or backlog items. Survey for new work.')
" 2>/dev/null
}

cmd_promote() {
    local id="$1"
    local comment="${2:-Promoted from backlog to active}"
    cmd_unlabel "$id" "backlog" 2>/dev/null || true
    cmd_label "$id" "active"
    cmd_update "$id" "$comment"
}

case "${1:-}" in
    add)     shift; cmd_add "$@" ;;
    list)    shift; cmd_list "$@" ;;
    next)    cmd_next ;;
    stale)   shift; cmd_stale "${1:-3}" ;;
    update)  shift; cmd_update "$@" ;;
    label)   shift; cmd_label "$@" ;;
    unlabel) shift; cmd_unlabel "$@" ;;
    close)   shift; cmd_close "$@" ;;
    reopen)  shift; cmd_reopen "$@" ;;
    show)    shift; cmd_show "$@" ;;
    summary) cmd_summary ;;
    promote) shift; cmd_promote "$@" ;;
    *)
        echo "Usage: tracker.sh {add|list|next|stale|update|label|unlabel|close|reopen|show|summary|promote}" >&2
        exit 1
        ;;
esac
