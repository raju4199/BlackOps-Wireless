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

c_green="\e[32m"; c_yellow="\e[33m"; c_red="\e[31m"; c_cyan="\e[36m"; c_bold="\e[1m"; c_reset="\e[0m"

mkdir -p "$LOG_DIR" "$CAPTURES_DIR"
[[ -f "$SESSIONS_CSV" ]] || echo "session_id,tool,start_iso,end_iso,interface,notes" > "$SESSIONS_CSV"

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
  local found=0
  local search_dirs=("${TOOLS_DIR}/airgeddon" "${TOOLS_DIR}/wifite2" "${TOOLS_DIR}/wifite2/hs" "${REPO_ROOT}")
  local dir
  for dir in "${search_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' f; do
      mkdir -p "$dest"
      mv -n "$f" "$dest/" 2>/dev/null && found=$((found+1))
    done < <(find "$dir" -maxdepth 2 -type f \( -name "*.cap" -o -name "*.pcap" -o -name "*.pcapng" -o -name "*.hccapx" -o -name "*.22000" \) -newermt "@${since_epoch}" -print0 2>/dev/null)
  done
  if (( found > 0 )); then
    echo -e "${c_green}[+] Harvested ${found} capture file(s) into captures/${session_id}/${c_reset}"
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

  echo -e "${c_cyan}[session ${session_id}] starting ${tool_name}${c_reset}"
  "$@"
  local exit_code=$?

  end_iso="$(now_iso)"
  harvest_captures "$session_id" "$start_epoch"
  echo "${session_id},${tool_name},${start_iso},${end_iso},,exit=${exit_code}" >> "$SESSIONS_CSV"
  echo -e "${c_cyan}[session ${session_id}] ${tool_name} ended (exit ${exit_code})${c_reset}"
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
    echo -e "${c_green}Run 'iw dev' to confirm the new monitor interface name (often ${IFACE}mon).${c_reset}"
  fi
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
  if command -v wifite >/dev/null 2>&1; then
    run_and_log "wifite" wifite
  elif [[ -f "$bin" ]]; then
    run_and_log "wifite2" python3 "$bin"
  else
    echo -e "${c_red}Wifite not found. Run sudo ./install.sh first.${c_reset}"
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
    0) echo "Bye."; exit 0 ;;
    *) echo "Invalid choice." ; sleep 1 ;;
  esac
done
