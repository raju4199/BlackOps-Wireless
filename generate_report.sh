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
OUT_JSON="${REPORTS_DIR}/report-${STAMP}.json"
OUT_HTML="${REPORTS_DIR}/report-${STAMP}.html"
OUT_SESSIONS_CSV="${REPORTS_DIR}/report-${STAMP}-sessions.csv"
OUT_CAPTURES_CSV="${REPORTS_DIR}/report-${STAMP}-captures.csv"

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

html_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "$s"
}

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
    echo "| Session ID | Tool | Start | End | Interface | Notes | Captures | Kismet (defensive) log |"
    echo "|---|---|---|---|---|---|---|---|"
    tail -n +2 "$SESSIONS_CSV" | while IFS=',' read -r session_id tool start_iso end_iso interface notes kismet_log; do
      cap_dir="${CAPTURES_DIR}/${session_id}"
      cap_list="none"
      if [[ -d "$cap_dir" ]]; then
        cap_list=$(find "$cap_dir" -maxdepth 1 -type f -printf '%f; ' 2>/dev/null)
        [[ -z "$cap_list" ]] && cap_list="none"
      fi
      [[ -z "$kismet_log" ]] && kismet_log="none"
      echo "| ${session_id} | ${tool} | ${start_iso} | ${end_iso} | ${interface} | ${notes} | ${cap_list} | ${kismet_log} |"
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

# ---------------- CSV: sessions ----------------
if [[ -f "$SESSIONS_CSV" ]]; then
  cp "$SESSIONS_CSV" "$OUT_SESSIONS_CSV"
else
  echo "session_id,tool,start_iso,end_iso,interface,notes,kismet_log" > "$OUT_SESSIONS_CSV"
fi

# ---------------- CSV: captures ----------------
{
  echo "session_id,file,size_bytes"
  if [[ -d "$CAPTURES_DIR" ]]; then
    find "$CAPTURES_DIR" -type f ! -name ".manifest.tsv" | sort | while read -r f; do
      rel="${f#$CAPTURES_DIR/}"
      sdir="${rel%%/*}"
      fname="${rel#*/}"
      size=$(stat -c%s "$f" 2>/dev/null || echo 0)
      echo "${sdir},${fname},${size}"
    done
  fi
} > "$OUT_CAPTURES_CSV"

# ---------------- JSON: sessions + captures ----------------
{
  echo "{"
  echo "  \"generated\": \"$(date -Iseconds)\","
  echo "  \"sessions\": ["
  if [[ -f "$SESSIONS_CSV" ]] && [[ $(wc -l < "$SESSIONS_CSV") -gt 1 ]]; then
    first=1
    tail -n +2 "$SESSIONS_CSV" | while IFS=',' read -r session_id tool start_iso end_iso interface notes kismet_log; do
      cap_dir="${CAPTURES_DIR}/${session_id}"
      caps_json="[]"
      if [[ -d "$cap_dir" ]]; then
        files=()
        while IFS= read -r -d '' cf; do
          files+=("\"$(json_escape "$(basename "$cf")")\"")
        done < <(find "$cap_dir" -maxdepth 1 -type f -print0 2>/dev/null)
        if (( ${#files[@]} > 0 )); then
          caps_json="[$(IFS=,; echo "${files[*]}")]"
        fi
      fi
      [[ $first -eq 1 ]] || echo ","
      first=0
      printf '    {"session_id": "%s", "tool": "%s", "start_iso": "%s", "end_iso": "%s", "interface": "%s", "notes": "%s", "kismet_log": "%s", "captures": %s}' \
        "$(json_escape "$session_id")" "$(json_escape "$tool")" "$(json_escape "$start_iso")" \
        "$(json_escape "$end_iso")" "$(json_escape "$interface")" "$(json_escape "$notes")" \
        "$(json_escape "$kismet_log")" "$caps_json"
    done
    echo
  fi
  echo "  ],"
  echo "  \"captures\": ["
  if [[ -d "$CAPTURES_DIR" ]] && [[ -n "$(find "$CAPTURES_DIR" -type f ! -name '.manifest.tsv' 2>/dev/null)" ]]; then
    first=1
    find "$CAPTURES_DIR" -type f ! -name ".manifest.tsv" | sort | while read -r f; do
      rel="${f#$CAPTURES_DIR/}"
      sdir="${rel%%/*}"
      fname="${rel#*/}"
      size=$(stat -c%s "$f" 2>/dev/null || echo 0)
      [[ $first -eq 1 ]] || echo ","
      first=0
      printf '    {"session_id": "%s", "file": "%s", "size_bytes": %s}' \
        "$(json_escape "$sdir")" "$(json_escape "$fname")" "$size"
    done
    echo
  fi
  echo "  ]"
  echo "}"
} > "$OUT_JSON"

# ---------------- HTML: same content as the markdown report ----------------
{
  echo "<!doctype html>"
  echo "<html lang=\"en\"><head><meta charset=\"utf-8\">"
  echo "<title>BlackOps Wireless - Session Report</title>"
  echo "<style>"
  echo "body{font-family:system-ui,sans-serif;max-width:960px;margin:2rem auto;padding:0 1rem;color:#1a1a1a;}"
  echo "table{border-collapse:collapse;width:100%;margin:1rem 0;}"
  echo "th,td{border:1px solid #ccc;padding:0.4rem 0.6rem;text-align:left;font-size:0.9rem;}"
  echo "th{background:#f0f0f0;}"
  echo "pre{background:#f7f7f7;padding:0.75rem;overflow-x:auto;border:1px solid #ddd;}"
  echo "h1,h2{border-bottom:1px solid #ddd;padding-bottom:0.3rem;}"
  echo "footer{color:#666;font-size:0.85rem;margin-top:2rem;}"
  echo "</style></head><body>"

  echo "<h1>BlackOps Wireless - Session Report</h1>"
  echo "<p>Generated: $(html_escape "$(date -Iseconds)")</p>"

  echo "<h2>Authorized scope (from LAB_AUTHORIZATION.md)</h2>"
  echo "<pre>"
  if [[ -f "$AUTH_FILE" ]]; then
    awk '/^## 2\. Scope/{flag=1} /^## 3\./{flag=0} flag' "$AUTH_FILE" | while IFS= read -r scopeline; do
      html_escape "$scopeline"; echo
    done
  else
    echo "LAB_AUTHORIZATION.md not found -- no scope on record."
  fi
  echo "</pre>"

  echo "<h2>Sessions</h2>"
  if [[ -f "$SESSIONS_CSV" ]] && [[ $(wc -l < "$SESSIONS_CSV") -gt 1 ]]; then
    echo "<table><tr><th>Session ID</th><th>Tool</th><th>Start</th><th>End</th><th>Interface</th><th>Notes</th><th>Captures</th><th>Kismet (defensive) log</th></tr>"
    tail -n +2 "$SESSIONS_CSV" | while IFS=',' read -r session_id tool start_iso end_iso interface notes kismet_log; do
      cap_dir="${CAPTURES_DIR}/${session_id}"
      cap_list="none"
      if [[ -d "$cap_dir" ]]; then
        cap_list=$(find "$cap_dir" -maxdepth 1 -type f -printf '%f; ' 2>/dev/null)
        [[ -z "$cap_list" ]] && cap_list="none"
      fi
      [[ -z "$kismet_log" ]] && kismet_log="none"
      printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
        "$(html_escape "$session_id")" "$(html_escape "$tool")" "$(html_escape "$start_iso")" \
        "$(html_escape "$end_iso")" "$(html_escape "$interface")" "$(html_escape "$notes")" \
        "$(html_escape "$cap_list")" "$(html_escape "$kismet_log")"
    done
    echo "</table>"
  else
    echo "<p><em>No sessions logged yet -- run tools via ./lab.sh first.</em></p>"
  fi

  echo "<h2>Capture files on disk</h2>"
  if [[ -d "$CAPTURES_DIR" ]] && [[ -n "$(find "$CAPTURES_DIR" -type f ! -name '.manifest.tsv' 2>/dev/null)" ]]; then
    echo "<table><tr><th>Session dir</th><th>File</th><th>Size</th></tr>"
    find "$CAPTURES_DIR" -type f ! -name ".manifest.tsv" | sort | while read -r f; do
      rel="${f#$CAPTURES_DIR/}"
      sdir="${rel%%/*}"
      fname="${rel#*/}"
      size=$(du -h "$f" 2>/dev/null | cut -f1)
      printf '<tr><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
        "$(html_escape "$sdir")" "$(html_escape "$fname")" "$(html_escape "$size")"
    done
    echo "</table>"
  else
    echo "<p><em>No capture files harvested yet.</em></p>"
  fi

  echo "<footer>Reminder: anything captured outside the scope table above is out of bounds -- re-check LAB_AUTHORIZATION.md before acting on it.</footer>"
  echo "</body></html>"
} > "$OUT_HTML"

echo "Report written to: $OUT"
echo "HTML report:        $OUT_HTML"
echo "JSON report:        $OUT_JSON"
echo "Sessions CSV:        $OUT_SESSIONS_CSV"
echo "Captures CSV:        $OUT_CAPTURES_CSV"
