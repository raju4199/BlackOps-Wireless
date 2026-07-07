#!/usr/bin/env bash
#
# generate_report.sh - turns logs/sessions.csv + captures/ into a markdown
# summary report, alongside the current authorization scope from
# LAB_AUTHORIZATION.md so every report is traceable back to what was
# actually authorized.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${REPO_ROOT}/logs"
SESSIONS_CSV="${LOG_DIR}/sessions.csv"
CAPTURES_DIR="${REPO_ROOT}/captures"
AUTH_FILE="${REPO_ROOT}/LAB_AUTHORIZATION.md"
REPORTS_DIR="${REPO_ROOT}/reports"

mkdir -p "$REPORTS_DIR"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${REPORTS_DIR}/report-${STAMP}.md"

{
  echo "# BlackOps Wireless - Session Report"
  echo
  echo "Generated: $(date -Iseconds)"
  echo

  echo "## Authorized scope (from LAB_AUTHORIZATION.md)"
  echo
  if [[ -f "$AUTH_FILE" ]]; then
    awk '/^## 2\. Scope/{flag=1} /^## 3\./{flag=0} flag' "$AUTH_FILE"
  else
    echo "_LAB_AUTHORIZATION.md not found -- no scope on record._"
  fi
  echo

  echo "## Sessions"
  echo
  if [[ -f "$SESSIONS_CSV" ]] && [[ $(wc -l < "$SESSIONS_CSV") -gt 1 ]]; then
    echo "| Session ID | Tool | Start | End | Notes | Captures |"
    echo "|---|---|---|---|---|---|"
    tail -n +2 "$SESSIONS_CSV" | while IFS=',' read -r session_id tool start_iso end_iso interface notes; do
      cap_dir="${CAPTURES_DIR}/${session_id}"
      cap_list="none"
      if [[ -d "$cap_dir" ]]; then
        cap_list=$(find "$cap_dir" -maxdepth 1 -type f -printf '%f; ' 2>/dev/null)
        [[ -z "$cap_list" ]] && cap_list="none"
      fi
      echo "| ${session_id} | ${tool} | ${start_iso} | ${end_iso} | ${notes} | ${cap_list} |"
    done
  else
    echo "_No sessions logged yet -- run tools via ./lab.sh first._"
  fi
  echo

  echo "## Capture files on disk"
  echo
  if [[ -d "$CAPTURES_DIR" ]] && [[ -n "$(find "$CAPTURES_DIR" -type f 2>/dev/null)" ]]; then
    echo "| Session dir | File | Size |"
    echo "|---|---|---|"
    find "$CAPTURES_DIR" -type f | sort | while read -r f; do
      rel="${f#$CAPTURES_DIR/}"
      sdir="${rel%%/*}"
      fname="${rel#*/}"
      size=$(du -h "$f" 2>/dev/null | cut -f1)
      echo "| ${sdir} | ${fname} | ${size} |"
    done
  else
    echo "_No capture files harvested yet._"
  fi
  echo

  echo "---"
  echo "_Reminder: anything captured outside the scope table above is out of_"
  echo "_bounds -- re-check LAB_AUTHORIZATION.md before acting on it._"
} > "$OUT"

echo "Report written to: $OUT"
