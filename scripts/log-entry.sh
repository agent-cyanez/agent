#!/usr/bin/env bash
# Insert a log entry into the daily log file, maintaining chronological order.
# Uses flock for concurrency safety — multiple sessions can call this safely.
#
# Usage: log-entry.sh "## Header (HH:MM CLT)" <<'EOF'
# entry body lines
# EOF
#
# Or with inline body:
#   echo "- entry content" | log-entry.sh "## Tick (14:00 CLT)"

set -euo pipefail

VELA_DIR="/home/vela/agent"
LOG_DIR="$VELA_DIR/log"
DATA_DIR="$VELA_DIR/data"
TODAY=$(date +%Y-%m-%d)
LOG_FILE="$LOG_DIR/$TODAY.md"
LOCK_FILE="$DATA_DIR/log.lock"

HEADER="$1"
BODY=$(cat)

mkdir -p "$DATA_DIR"

# Extract HH:MM from the header
NEW_TIME=$(echo "$HEADER" | grep -oP '\d{2}:\d{2}' | head -1)
if [[ -z "$NEW_TIME" ]]; then
    echo "ERROR: Could not extract HH:MM timestamp from header: $HEADER" >&2
    exit 1
fi

FULL_ENTRY="$HEADER

$BODY"

# All operations under an exclusive lock
exec 200>"$LOCK_FILE"
flock 200

if [[ ! -f "$LOG_FILE" ]]; then
    printf "# %s\n\n%s\n" "$TODAY" "$FULL_ENTRY" > "$LOG_FILE"
    exit 0
fi

# Append the new entry then reorder all sections by timestamp.
# This is simpler and more robust than trying to find the right insertion point
# in a potentially-disordered file.
printf "\n%s\n" "$FULL_ENTRY" >> "$LOG_FILE"

# Reorder: extract all ## sections, sort by timestamp, reassemble
python3 - "$LOG_FILE" <<'PYEOF'
import re, sys

filepath = sys.argv[1]
with open(filepath) as f:
    content = f.read()

# Split into the title line (# YYYY-MM-DD...) and sections (## ...)
lines = content.split('\n')
title_lines = []
section_starts = []

for i, line in enumerate(lines):
    if line.startswith('## '):
        section_starts.append(i)
    elif not section_starts:
        title_lines.append(line)

if not section_starts:
    sys.exit(0)

# Extract sections
sections = []
for idx, start in enumerate(section_starts):
    end = section_starts[idx + 1] if idx + 1 < len(section_starts) else len(lines)
    header = lines[start]
    body = lines[start:end]
    # Extract HH:MM timestamp
    match = re.search(r'(\d{2}):(\d{2})', header)
    if match:
        minutes = int(match.group(1)) * 60 + int(match.group(2))
    else:
        minutes = 9999  # entries without timestamps go to the end
    sections.append((minutes, start, body))

# Stable sort by timestamp (preserves original order for same-time entries)
sections.sort(key=lambda s: (s[0], s[1]))

# Reassemble
title = '\n'.join(title_lines).rstrip('\n')
result = title + '\n'
for _, _, body in sections:
    # Strip trailing blank lines from section, add exactly one between sections
    section_text = '\n'.join(body).rstrip('\n')
    result += '\n' + section_text + '\n'

with open(filepath, 'w') as f:
    f.write(result)
PYEOF
