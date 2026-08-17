#!/usr/bin/env bash
# Scans public log files for conversation leakage patterns.
# Used by pre-commit hook and can be run standalone.
# Exit 0 = clean, Exit 1 = violations found.

set -euo pipefail

TARGET="${1:-log/}"
VIOLATIONS=0

# Patterns that reveal what the patron said, asked, felt, or did
PATTERNS=(
  # Direct attribution of speech/action to patron
  '[Pp]atron.*(asked|said|expressed|confirmed|clarified|acknowledged|requested|told|wanted|appreciated|mentioned|decided|chose|preferred|noted|suggested|raised|inquired|proposed|directed|instructed|approved|agreed|indicated|pointed out|brought up|complained|explained|shared|communicated|conveyed|disclosed|revealed|stated|described|specified|outlined|articulated)'
  '[Pp]atron.*(is |was |will |has |had )(sourcing|reading|looking|checking|ordering|buying|sending|notifying|reviewing|testing|deploying|working|considering|thinking|planning|investigating|evaluating|assessing)'
  # Conversation framing
  '[Pp]atron (asked|said|told|expressed|wants|wanted|confirmed|clarified|acknowledged|requested|prefers|preferred|approved|agreed|indicated|suggested|proposed|instructed|directed|noted|raised|mentioned|complained|explained|shared|communicated|stated|described|specified|outlined|articulated)'
  # Quoting or paraphrasing
  '[Dd]iscussed with (the )?patron'
  '[Pp]atron.*feedback'
  '[Pp]atron.*opinion'
  '[Aa]greed (on|upon|to|that) '
  # Revealing patron feelings/reactions
  '[Pp]atron.*(happy|unhappy|pleased|frustrated|concerned|worried|excited|surprised|disappointed|satisfied|annoyed|upset|relieved|grateful|thankful|appreciat)'
)

check_file() {
  local file="$1"
  local found=0
  for pattern in "${PATTERNS[@]}"; do
    matches=$(grep -nE "$pattern" "$file" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
      if [[ $found -eq 0 ]]; then
        echo "=== $file ==="
        found=1
      fi
      echo "$matches"
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  done
}

if [[ -d "$TARGET" ]]; then
  for f in "$TARGET"/*.md; do
    [[ -f "$f" ]] && check_file "$f"
  done
elif [[ -f "$TARGET" ]]; then
  check_file "$TARGET"
fi

if [[ $VIOLATIONS -gt 0 ]]; then
  echo ""
  echo "BLOCKED: $VIOLATIONS conversation-leakage pattern(s) found in public logs."
  echo "Move conversation details to the private-log repo."
  exit 1
fi

exit 0
