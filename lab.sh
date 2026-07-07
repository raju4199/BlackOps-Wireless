#!/usr/bin/env bash
#
# lab.sh - BlackOps Wireless menu launcher
#
# Gates every tool launch behind an explicit authorization confirmation
# tied to LAB_AUTHORIZATION.md, self-checks dependencies the way Airgeddon
# does on its own startup, then hands off to Airgeddon / Wifite /
# Bettercap - while logging every session and auto-organizing captures.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="${REPO_ROOT}/tools"
AUTH_FILE="${REPO_ROOT}/LAB_AUTHORIZATION.md"
LOG_DIR="${REPO_ROOT}/logs"
CAPTURES_DIR="${REPO_ROOT}/captures"
SESSIONS_CSV="${LOG_DIR}/sessions.csv"
CAPTURE_MANIFEST="${CAPTURES_DIR}/.manifest.tsv"

# Set by "Check / enable monitor mode" so later steps (scan, Kismet
# companion) don't have to re-ask for the interface every time.
MON_IFACE=""
# Toggled via the menu; when true, run_and_log starts Kismet alongside
# whichever attack tool is launched so the session also gets a defensive
# (WIDS) view of the same traffic.
KISMET_ENABLED=false
KISMET_PID=""

c_green="\e[32m"; c_yellow="\e[33m"; c_red="\e[31m"; c_cyan="\e[36m"; c_bold="\e[1m"; c_reset="\e[0m"

mkdir -p "$LOG_DIR" "$CAPTURES_DIR"
[[ -f "$SESSIONS_CSV" ]] || echo "session_id,tool,start_iso,end_iso,interface,notes,kismet_log" > "$SESSIONS_CSV"
[[ -f "$CAPTURE_MANIFEST" ]] || : > "$CAPTURE_MANIFEST"

# Older sessions.csv files (pre-Kismet-companion) only have 6 columns.
# Pad the header and every existing row with an empty kismet_log field
# instead of breaking on read or silently misaligning columns.
migrate_sessions_csv() {
  local header
  header="$(head -n1 "$SESSIONS_CSV" 2>/dev/null)"
  if [[ -n "$header" && "$header" != *"kismet_log"* ]]; then
    local tmp="${SESSIONS_CSV}.tmp.$$"
    { echo "${header},kismet_log"; tail -n +2 "$SESSIONS_CSV" | sed 's/$/,/'; } > "$tmp" \
      && mv "$tmp" "$SESSIONS_CSV"
  fi
}
migrate_sessions_csv

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${c_red}[x]${c_reset} Most of these tools need raw socket / monitor-mode access. Run: sudo ./lab.sh"
    exit 1
  fi
}

banner() {
  echo -e "${c_bold}${c_cyan}"
  echo "  BlackOps Wireless"
  echo "  ------------------"
  echo -e "${c_reset}"
}

# ---------------- dependency self-check (Airgeddon-style) ----------------
DEP_TOOLS=(iw ip aircrack-ng airmon-ng airodump-ng aireplay-ng packetforge-ng mdk4 hostapd dnsmasq macchanger reaver bully tshark hashcat hcxdumptool hcxpcapngtool wifite bettercap git)

check_dependencies() {
  echo -e "${c_bold}Dependency check${c_reset}"
  echo "-------------------------------------------------------------"
  local missing=()
  for tool in "${DEP_TOOLS[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf "  [%bOK%b]      %s\n" "$c_green" "$c_reset" "$tool"
    else
      printf "  [%bMISSING%b] %s\n" "$c_red" "$c_reset" "$tool"
      missing+=("$tool")
    fi
  done
  echo "-------------------------------------------------------------"
  if [[ -f "${TOOLS_DIR}/airgeddon/airgeddon.sh" ]]; then
    printf "  [%bOK%b]      airgeddon (tools/airgeddon)\n" "$c_green" "$c_reset"
  else
    printf "  [%bMISSING%b] airgeddon (run sudo ./install.sh)\n" "$c_red" "$c_reset"
  fi
  echo
  if (( ${#missing[@]} > 0 )); then
    echo -e "${c_yellow}Missing: ${missing[*]}${c_reset}"
    echo "Run 'sudo ./install.sh' to install everything available via apt."
  else
    echo -e "${c_green}All core dependencies present.${c_reset}"
  fi
  if command -v kismet >/dev/null 2>&1; then
    printf "  [%bOK%b]      kismet (optional defensive/WIDS companion)\n" "$c_green" "$c_reset"
  else
    printf "  [%boptional%b] kismet not found -- companion mode (menu) will be unavailable\n" "$c_yellow" "$c_reset"
  fi
}

# ---------------- adapter / chipset pre-flight ----------------
# Airgeddon/Wifite2 don't validate the adapter before you're several menus
# deep; this catches the most common "works on paper, fails at monitor
# mode / injection" chipsets before a session is even started.
CHIPSET_GOOD_PATTERNS=(
  "0cf3:9271|Atheros.*AR9271"                     # Atheros AR9271 - reliable, in-kernel
  "0bda:8812|0bda:881a|RTL8812AU"                 # Realtek RTL8812AU - injection-capable w/ driver
  "0bda:8811|RTL8811AU"                           # Realtek RTL8811AU
  "148f:3070|Ralink.*RT3070"                      # Ralink RT3070 - old but rock solid
)
CHIPSET_BAD_PATTERNS=(
  "Broadcom"                                       # notoriously poor monitor-mode/injection support
  "0bda:8179|RTL8188EUS"                          # RTL8188EUS - flaky monitor mode, driver churn
  "148f:7601|MT7601U"                             # MediaTek MT7601U - weak/no injection
  "8087:|Intel Corporation.*Wireless"             # onboard Intel wifi - rarely supports injection
)

check_adapter_chipset() {
  echo -e "${c_bold}Adapter / chipset pre-flight check${c_reset}"
  echo "-------------------------------------------------------------"
  if ! command -v lsusb >/dev/null 2>&1; then
    echo -e "${c_yellow}lsusb not found (usbutils not installed) -- skipping USB chipset ID.${c_reset}"
  else
    local lsusb_out
    lsusb_out="$(lsusb 2>/dev/null)"
    echo -e "${c_cyan}USB devices:${c_reset}"
    echo "$lsusb_out" | sed 's/^/  /'
    echo
    local found_good=0 found_bad=0
    local pattern line
    for pattern in "${CHIPSET_GOOD_PATTERNS[@]}"; do
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        printf "  [%bGOOD%b]    %s\n" "$c_green" "$c_reset" "$line"
        found_good=1
      done < <(echo "$lsusb_out" | grep -Ei "$pattern")
    done
    for pattern in "${CHIPSET_BAD_PATTERNS[@]}"; do
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        printf "  [%bWARN%b]    %s -- known-flaky monitor mode/injection support\n" "$c_yellow" "$c_reset" "$line"
        found_bad=1
      done < <(echo "$lsusb_out" | grep -Ei "$pattern")
    done
    echo
    if (( found_bad == 1 )); then
      echo -e "${c_yellow}[!] A chipset commonly reported as unreliable for monitor mode/injection was detected.${c_reset}"
      echo -e "${c_yellow}    Sessions may fail partway through (driver crashes, silent injection failure).${c_reset}"
      echo "    See SETUP_NOTES.md section 1 for known-good adapters (Atheros AR9271, RTL8812AU/8811AU, RT3070)."
    elif (( found_good == 1 )); then
      echo -e "${c_green}[+] Detected adapter chipset(s) known to work well with aircrack-ng/Airgeddon.${c_reset}"
    else
      echo -e "${c_yellow}[!] No listed USB adapter matched the known-good or known-bad chipset list.${c_reset}"
      echo "    Not necessarily a problem -- just unverified. Confirm monitor mode below actually works."
    fi
  fi

  echo
  if ! command -v iw >/dev/null 2>&1; then
    echo -e "${c_red}[x] iw not found -- cannot verify monitor-mode support. Run sudo ./install.sh.${c_reset}"
  else
    echo -e "${c_cyan}Wireless interfaces (iw dev):${c_reset}"
    iw dev 2>/dev/null | sed 's/^/  /'
    echo
    echo -e "${c_cyan}Monitor-mode support (iw list):${c_reset}"
    local iw_list_out
    iw_list_out="$(iw list 2>/dev/null)"
    if echo "$iw_list_out" | grep -qi "monitor"; then
      echo -e "  ${c_green}[+] At least one wiphy advertises monitor mode support.${c_reset}"
    else
      echo -e "  ${c_red}[x] No wiphy on this system advertises monitor mode support.${c_reset}"
      echo "      Either the driver isn't loaded correctly or the chipset genuinely lacks it -- check 'dmesg | tail -50'."
    fi
  fi
  echo "-------------------------------------------------------------"
}

# ---------------- authorization gate ----------------
confirm_authorization() {
  echo -e "${c_yellow}${c_bold}"
  echo "==================================================================="
  echo " AUTHORIZATION CHECK"
  echo "==================================================================="
  echo -e "${c_reset}"
  if [[ ! -f "$AUTH_FILE" ]]; then
    echo -e "${c_red}LAB_AUTHORIZATION.md not found. Refusing to continue.${c_reset}"
    exit 1
  fi
  echo "Before any wireless tool is launched, confirm the following:"
  echo "  1. You own the target network/AP, OR have signed written authorization"
  echo "     to test it (see LAB_AUTHORIZATION.md)."
  echo "  2. The test network is isolated from production/third-party traffic."
  echo "  3. You will only target SSIDs/BSSIDs listed in LAB_AUTHORIZATION.md."
  echo
  read -rp "Type exactly I CONFIRM AUTHORIZATION to proceed: " reply
  if [[ "$reply" != "I CONFIRM AUTHORIZATION" ]]; then
    echo -e "${c_red}Confirmation text did not match. Aborting.${c_reset}"
    exit 1
  fi
  echo -e "${c_green}[+] Authorization confirmed for this session.${c_reset}"
  echo
}

# ---------------- helpers ----------------
pause() { read -rp "Press Enter to return to menu..." _; }

now_iso() { date -Iseconds; }
now_epoch() { date +%s; }

harvest_captures() {
  local session_id="$1"
  local since_epoch="$2"
  local dest="${CAPTURES_DIR}/${session_id}"
  local found=0 skipped=0
  local search_dirs=("${TOOLS_DIR}/airgeddon" "${TOOLS_DIR}/wifite2" "${TOOLS_DIR}/wifite2/hs" "${REPO_ROOT}")
  local dir
  for dir in "${search_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' f; do
      local hash
      if command -v sha256sum >/dev/null 2>&1; then
        hash="$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)"
      else
        hash="$(md5sum "$f" 2>/dev/null | cut -d' ' -f1)"
      fi
      if [[ -n "$hash" ]] && grep -qP "^${hash}\t" "$CAPTURE_MANIFEST" 2>/dev/null; then
        skipped=$((skipped+1))
        rm -f "$f" 2>/dev/null
        continue
      fi
      mkdir -p "$dest"
      if mv -n "$f" "$dest/" 2>/dev/null; then
        found=$((found+1))
        [[ -n "$hash" ]] && printf "%s\t%s/%s\t%s\n" "$hash" "$session_id" "$(basename "$f")" "$(now_iso)" >> "$CAPTURE_MANIFEST"
      fi
    done < <(find "$dir" -maxdepth 2 -type f \( -name "*.cap" -o -name "*.pcap" -o -name "*.pcapng" -o -name "*.hccapx" -o -name "*.22000" \) -newermt "@${since_epoch}" -print0 2>/dev/null)
  done
  if (( found > 0 )); then
    echo -e "${c_green}[+] Harvested ${found} capture file(s) into captures/${session_id}/${c_reset}"
  fi
  if (( skipped > 0 )); then
    echo -e "${c_yellow}[i] Skipped ${skipped} duplicate capture(s) already on record (identical handshake/PMKID captured previously).${c_reset}"
  fi
}

# ---------------- PMKID capture dependency check ----------------
# Wifite2 (and Airgeddon's PMKID menu) will hang or fail deep inside the
# attack if hashcat/hcxdumptool/hcxpcapngtool are missing rather than
# failing fast up front. Check first and skip cleanly instead.
check_pmkid_deps() {
  local missing=()
  local tool
  for tool in hashcat hcxdumptool hcxpcapngtool; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if (( ${#missing[@]} > 0 )); then
    echo -e "${c_red}[x] PMKID capture requires: ${missing[*]} (missing).${c_reset}"
    echo "    The underlying tool would otherwise hang or fail mid-attack. Run 'sudo ./install.sh' to install these."
    return 1
  fi
  return 0
}

# ---------------- Kismet companion mode ----------------
# Runs Kismet alongside the chosen attack tool so the same session also
# gets a defensive/WIDS view (rogue AP alerts, deauth-flood detection) of
# the traffic being generated -- purely observational, no new attack logic.
start_kismet_companion() {
  local session_id="$1"
  KISMET_PID=""
  if ! command -v kismet >/dev/null 2>&1; then
    echo -e "${c_yellow}[!] Kismet companion mode is on but kismet is not installed -- skipping.${c_reset}"
    return 1
  fi
  local iface="$MON_IFACE"
  if [[ -z "$iface" ]]; then
    read -rp "Kismet companion: interface to monitor (blank to skip Kismet for this session): " iface
    [[ -z "$iface" ]] && return 1
  fi
  local klog="${LOG_DIR}/kismet-${session_id}.log"
  nohup kismet -c "$iface" --no-ncurses >"$klog" 2>&1 &
  KISMET_PID=$!
  sleep 1
  if ! kill -0 "$KISMET_PID" 2>/dev/null; then
    echo -e "${c_yellow}[!] Kismet failed to start (see ${klog}) -- continuing without it.${c_reset}"
    KISMET_PID=""
    return 1
  fi
  echo -e "${c_green}[+] Kismet companion running (pid ${KISMET_PID}), logging to ${klog}${c_reset}"
  echo "$klog"
}

stop_kismet_companion() {
  if [[ -n "$KISMET_PID" ]]; then
    kill "$KISMET_PID" 2>/dev/null
    wait "$KISMET_PID" 2>/dev/null
    KISMET_PID=""
  fi
}

run_and_log() {
  local tool_name="$1"
  shift
  local session_id
  session_id="$(date +%Y%m%d-%H%M%S)-${tool_name}"
  local start_iso start_epoch end_iso
  start_iso="$(now_iso)"
  start_epoch="$(now_epoch)"

  local klog=""
  if [[ "$KISMET_ENABLED" == "true" ]]; then
    klog="$(start_kismet_companion "$session_id")" || klog=""
  fi

  echo -e "${c_cyan}[session ${session_id}] starting ${tool_name}${c_reset}"
  "$@"
  local exit_code=$?

  [[ -n "$klog" ]] && stop_kismet_companion

  end_iso="$(now_iso)"
  harvest_captures "$session_id" "$start_epoch"
  echo "${session_id},${tool_name},${start_iso},${end_iso},${MON_IFACE},exit=${exit_code},${klog}" >> "$SESSIONS_CSV"
  echo -e "${c_cyan}[session ${session_id}] ${tool_name} ended (exit ${exit_code})${c_reset}"
  if [[ -n "$klog" ]]; then
    echo -e "${c_cyan}[i] Kismet defensive log for this session: ${klog}${c_reset}"
  fi
}

check_monitor_mode() {
  echo -e "${c_cyan}Interfaces:${c_reset}"
  iw dev 2>/dev/null || echo "iw not found"
  echo
  echo -e "${c_cyan}Checking for processes that may interfere with monitor mode:${c_reset}"
  airmon-ng check 2>/dev/null || echo "airmon-ng not found (install.sh not run yet?)"
  echo
  read -rp "Enter interface to put into monitor mode (e.g. wlan0), or leave blank to skip: " IFACE
  if [[ -n "$IFACE" ]]; then
    airmon-ng check kill
    if ! airmon-ng start "$IFACE" >/tmp/monmode.$$ 2>&1; then
      echo -e "${c_yellow}First attempt failed, unblocking rfkill and retrying...${c_reset}"
      rfkill unblock all 2>/dev/null || true
      airmon-ng start "$IFACE" || echo -e "${c_red}Still failing -- check dmesg for driver errors.${c_reset}"
    fi
    cat /tmp/monmode.$$ 2>/dev/null
    rm -f /tmp/monmode.$$
    local guess="${IFACE}mon"
    if iw dev 2>/dev/null | grep -q "$guess"; then
      MON_IFACE="$guess"
    else
      MON_IFACE="$IFACE"
    fi
    echo -e "${c_green}Run 'iw dev' to confirm the new monitor interface name (often ${IFACE}mon).${c_reset}"
    echo "Recorded monitor interface as '${MON_IFACE}' for the scan/Kismet menu options (correct it there if wrong)."
  fi
  pause
}

# ---------------- WPA3-SAE aware target scan + tool recommendation ----------------
# Airgeddon/Wifite2 will happily let you fire a deauth-based capture at a
# pure WPA3-SAE network and just silently fail (PMF protects management
# frames, so deauth frames are dropped). This scans beacons first and
# tells you which of the already-installed tools is actually applicable.
recommend_tool_for() {
  local category="$1" wps="$2"
  case "$category" in
    WEP)
      echo "Airgeddon (dedicated WEP attack menu: chopchop/fragmentation/ARP-replay) or Wifite2 (fully automated WEP handling) -- both fine."
      ;;
    OPEN)
      echo "No key to attack -- nothing for Airgeddon/Wifite2 to do here beyond passive recon."
      ;;
    WPA2)
      if [[ "$wps" == "yes" ]]; then
        echo "WPS is enabled: Airgeddon's Reaver/Bully Pixie-Dust menu is usually fastest. Otherwise Wifite2 (automated handshake+PMKID capture, hands off to hashcat)."
      else
        echo "Wifite2 recommended: automates handshake + PMKID capture and hashcat cracking with the least interaction. Airgeddon if you want manual control over which deauth/capture step runs."
      fi
      ;;
    WPA2/WPA3-mixed)
      echo "Airgeddon recommended: it has WPA3-aware menus for mixed-mode APs. PMF may already be enabled even in mixed mode, so try the PMKID/hcxdumptool-based capture path before deauth-based handshake capture."
      ;;
    WPA3-SAE)
      echo "Neither tool can reliably attack this. Pure SAE + PMF means deauth-based capture will not work, and no downgrade/exploit technique is provided here. Passive monitoring only."
      ;;
    *)
      echo "Unrecognized/mixed beacon data -- inspect manually before choosing a tool."
      ;;
  esac
}

scan_and_recommend() {
  echo -e "${c_bold}Target scan + WPA3-aware tool recommendation${c_reset}"
  echo "-------------------------------------------------------------"
  if ! command -v airodump-ng >/dev/null 2>&1; then
    echo -e "${c_red}[x] airodump-ng not found. Run sudo ./install.sh first.${c_reset}"
    pause
    return
  fi
  local iface
  read -rp "Monitor-mode interface to scan with [${MON_IFACE:-none set}]: " iface
  iface="${iface:-$MON_IFACE}"
  if [[ -z "$iface" ]]; then
    echo -e "${c_red}[x] No interface given. Use option 2 first to enable monitor mode.${c_reset}"
    pause
    return
  fi
  read -rp "Scan duration in seconds [15]: " dur
  dur="${dur:-15}"

  local tmp_prefix="/tmp/boc_scan_$$"
  echo -e "${c_cyan}Scanning for ${dur}s on ${iface}... (Ctrl+C-safe, will stop automatically)${c_reset}"
  timeout "${dur}" airodump-ng --output-format csv -w "$tmp_prefix" "$iface" >/dev/null 2>&1
  local csv="${tmp_prefix}-01.csv"
  if [[ ! -f "$csv" ]]; then
    echo -e "${c_red}[x] No scan output produced -- is ${iface} really in monitor mode?${c_reset}"
    pause
    return
  fi

  # Optional WPS check (best-effort, short scan) -- wash ships with reaver.
  local wash_out=""
  if command -v wash >/dev/null 2>&1; then
    wash_out="$(timeout 8 wash -i "$iface" -C 2>/dev/null)"
  fi

  echo
  printf "%-18s %-25s %-22s %-8s %s\n" "BSSID" "ESSID" "Category" "WPS" "Recommendation"
  echo "-------------------------------------------------------------------------------------------------"

  # airodump CSV: AP block ends at the first fully-blank line, before the
  # "Station MAC" block. Fields are comma-separated with leading spaces.
  awk -F',' '
    NR==1 { next }
    /^ *$/ { exit }
    /^BSSID/ { next }
    { print }
  ' "$csv" | while IFS=',' read -r bssid firstseen lastseen channel speed privacy cipher auth power beacons iv lanip idlen essid key; do
    bssid="$(echo "$bssid" | xargs)"
    [[ -n "$bssid" ]] || continue
    privacy="$(echo "$privacy" | xargs)"
    auth="$(echo "$auth" | xargs)"
    essid="$(echo "$essid" | xargs)"
    [[ -n "$essid" ]] || essid="(hidden)"

    local_category="Unknown"
    if [[ "$privacy" == *WEP* ]]; then
      local_category="WEP"
    elif [[ -z "$privacy" || "$privacy" == "OPN" ]]; then
      local_category="OPEN"
    elif [[ "$auth" == *WPA3* && "$auth" == *WPA2* ]]; then
      local_category="WPA2/WPA3-mixed"
    elif [[ "$auth" == *WPA3* ]]; then
      local_category="WPA3-SAE"
    elif [[ "$auth" == *WPA2* || "$auth" == *PSK* ]]; then
      local_category="WPA2"
    fi

    wps="no"
    if [[ -n "$wash_out" ]] && echo "$wash_out" | grep -qi "$bssid"; then
      wps="yes"
    fi

    rec="$(recommend_tool_for "$local_category" "$wps")"
    printf "%-18s %-25s %-22s %-8s %s\n" "$bssid" "$essid" "$local_category" "$wps" "$rec"

    if [[ "$local_category" == "WPA3-SAE" ]]; then
      echo -e "  ${c_yellow}[!] ${essid} (${bssid}) is pure WPA3-SAE: PMF blocks deauth frames, so deauth-based capture in Airgeddon/Wifite2 will not work against it.${c_reset}"
    fi
  done

  rm -f "${tmp_prefix}"*.csv "${tmp_prefix}"*.cap "${tmp_prefix}"*.kismet.* "${tmp_prefix}"*.log.csv 2>/dev/null
  echo
  echo "Reminder: only scan/target BSSIDs listed in LAB_AUTHORIZATION.md."
  pause
}

launch_airgeddon() {
  local bin="${TOOLS_DIR}/airgeddon/airgeddon.sh"
  if [[ ! -f "$bin" ]]; then
    echo -e "${c_red}Airgeddon not found. Run sudo ./install.sh first.${c_reset}"
    pause
    return
  fi
  run_and_log "airgeddon" bash "$bin"
  pause
}

launch_wifite() {
  local bin="${TOOLS_DIR}/wifite2/Wifite.py"
  if ! command -v wifite >/dev/null 2>&1 && [[ ! -f "$bin" ]]; then
    echo -e "${c_red}Wifite not found. Run sudo ./install.sh first.${c_reset}"
    pause
    return
  fi
  if ! check_pmkid_deps; then
    read -rp "Wifite2 attempts PMKID capture by default -- continue anyway (other attack modes still work)? [y/N] " cont
    if [[ ! "$cont" =~ ^[Yy]$ ]]; then
      pause
      return
    fi
  fi
  if command -v wifite >/dev/null 2>&1; then
    run_and_log "wifite" wifite
  else
    run_and_log "wifite2" python3 "$bin"
  fi
  pause
}

launch_bettercap() {
  if command -v bettercap >/dev/null 2>&1; then
    echo "Example: bettercap -iface wlan0mon"
    read -rp "Interface to use with bettercap: " IFACE
    [[ -n "$IFACE" ]] && run_and_log "bettercap" bettercap -iface "$IFACE"
  else
    echo -e "${c_red}bettercap not found. Run sudo ./install.sh first.${c_reset}"
  fi
  pause
}

toggle_kismet_companion() {
  if [[ "$KISMET_ENABLED" == "true" ]]; then
    KISMET_ENABLED=false
    echo -e "${c_yellow}Kismet companion mode: OFF${c_reset}"
  else
    if ! command -v kismet >/dev/null 2>&1; then
      echo -e "${c_red}[x] kismet is not installed -- install it (e.g. sudo apt-get install kismet) before enabling.${c_reset}"
    else
      KISMET_ENABLED=true
      echo -e "${c_green}Kismet companion mode: ON${c_reset} -- it will start alongside the next Airgeddon/Wifite/Bettercap launch"
      echo "using monitor interface '${MON_IFACE:-<not set, will prompt>}'."
    fi
  fi
  pause
}

view_authorization() {
  ${PAGER:-less} "$AUTH_FILE" 2>/dev/null || cat "$AUTH_FILE"
}

generate_report() {
  if [[ -f "${REPO_ROOT}/generate_report.sh" ]]; then
    bash "${REPO_ROOT}/generate_report.sh"
  else
    echo -e "${c_red}generate_report.sh not found.${c_reset}"
  fi
  pause
}

# ---------------- main ----------------
require_root
clear
banner
check_dependencies
echo
confirm_authorization

while true; do
  clear
  banner
  echo -e "${c_bold}  main menu${c_reset}"
  echo "-------------------------------------------------------------"
  echo " 1) Check dependencies"
  echo " 2) Check / enable monitor mode"
  echo " 3) Launch Airgeddon"
  echo " 4) Launch Wifite"
  echo " 5) Launch Bettercap"
  echo " 6) View LAB_AUTHORIZATION.md"
  echo " 7) Generate session report"
  echo " 8) Re-run install.sh (update tools)"
  echo " 9) Adapter / chipset pre-flight check"
  echo "10) Scan target + WPA3-aware tool recommendation"
  printf "11) Toggle Kismet companion mode (currently: %s)\n" "$([[ "$KISMET_ENABLED" == "true" ]] && echo ON || echo OFF)"
  echo " 0) Exit"
  echo
  read -rp "Choice: " choice
  case "$choice" in
    1) check_dependencies; pause ;;
    2) check_monitor_mode ;;
    3) launch_airgeddon ;;
    4) launch_wifite ;;
    5) launch_bettercap ;;
    6) view_authorization ;;
    7) generate_report ;;
    8) bash "${REPO_ROOT}/install.sh" ;;
    9) check_adapter_chipset; pause ;;
    10) scan_and_recommend ;;
    11) toggle_kismet_companion ;;
    0) echo "Bye."; exit 0 ;;
    *) echo "Invalid choice." ; sleep 1 ;;
  esac
done
