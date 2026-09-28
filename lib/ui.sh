#!/usr/bin/env bash
#
# lib/ui.sh - shared terminal UI toolkit for BlackOps Wireless
#
# Purely presentational: boxed headers, aligned tables, colour-coded
# severity badges, signal bars, step banners and a severity legend.
# No attack logic lives here. Source it from lab.sh / generate_report.sh:
#
#   source "${REPO_ROOT}/lib/ui.sh"
#
# Everything degrades to plain ASCII when NO_COLOR is set or stdout is
# not a TTY, so piping a session to a log file stays readable.

# ---------------- capability detection ----------------
if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
  UI_COLOR=0
else
  UI_COLOR=1
fi

# Box-drawing only when the locale looks UTF-8, else ASCII fallbacks.
if [[ "${LANG:-}${LC_ALL:-}${LC_CTYPE:-}" == *UTF-8* || "${LANG:-}${LC_ALL:-}${LC_CTYPE:-}" == *utf8* ]]; then
  UI_UTF8=1
else
  UI_UTF8=0
fi

# ---------------- palette ----------------
if (( UI_COLOR )); then
  U_RESET="\e[0m";  U_BOLD="\e[1m";   U_DIM="\e[2m"
  U_RED="\e[31m";   U_GREEN="\e[32m"; U_YELLOW="\e[33m"
  U_BLUE="\e[34m";  U_MAGENTA="\e[35m"; U_CYAN="\e[36m"; U_WHITE="\e[37m"
  U_BRED="\e[91m";  U_BGREEN="\e[92m"; U_BYELLOW="\e[93m"
  U_BBLUE="\e[94m"; U_BCYAN="\e[96m"
  U_ON_RED="\e[41m"; U_ON_YELLOW="\e[43m"; U_ON_GREEN="\e[42m"
  U_ON_BLUE="\e[44m"; U_BLACK="\e[30m"
else
  U_RESET=""; U_BOLD=""; U_DIM=""
  U_RED=""; U_GREEN=""; U_YELLOW=""; U_BLUE=""; U_MAGENTA=""; U_CYAN=""; U_WHITE=""
  U_BRED=""; U_BGREEN=""; U_BYELLOW=""; U_BBLUE=""; U_BCYAN=""
  U_ON_RED=""; U_ON_YELLOW=""; U_ON_GREEN=""; U_ON_BLUE=""; U_BLACK=""
fi

# ---------------- box characters ----------------
if (( UI_UTF8 )); then
  BX_TL="╔"; BX_TR="╗"; BX_BL="╚"; BX_BR="╝"
  BX_H="═";  BX_V="║"
  LN_TL="┌"; LN_TR="┐"; LN_BL="└"; LN_BR="┘"
  LN_H="─";  LN_V="│";  LN_LT="├"; LN_RT="┤"
  DOT="●";   ARROW="→"; CHECK="✔"; CROSS="✘"; WARN="⚠"
  BAR_FULL="█"; BAR_EMPTY="░"
else
  BX_TL="+"; BX_TR="+"; BX_BL="+"; BX_BR="+"; BX_H="="; BX_V="|"
  LN_TL="+"; LN_TR="+"; LN_BL="+"; LN_BR="+"; LN_H="-"; LN_V="|"; LN_LT="+"; LN_RT="+"
  DOT="*"; ARROW="->"; CHECK="OK"; CROSS="X"; WARN="!"
  BAR_FULL="#"; BAR_EMPTY="."
fi

UI_WIDTH="${UI_WIDTH:-64}"

# Repeat a (possibly multi-byte) glyph N times.
_ui_repeat() {
  local glyph="$1" count="$2" out="" i
  for (( i=0; i<count; i++ )); do out+="$glyph"; done
  printf '%b' "$out"
}

# ---------------- brand banner ----------------
ui_banner() {
  local w=$UI_WIDTH
  echo -e "${U_BOLD}${U_BCYAN}"
  echo -e " ${BX_TL}$(_ui_repeat "$BX_H" $((w-2)))${BX_TR}"
  printf  " ${BX_V}%b%*s%b${BX_V}\n" "" $((w-2)) "" ""
  printf  " ${BX_V}   %-$((w-5))s${BX_V}\n" "BLACKOPS WIRELESS"
  printf  " ${BX_V}   %-$((w-5))s${BX_V}\n" "authorized wireless security lab"
  printf  " ${BX_V}%b%*s%b${BX_V}\n" "" $((w-2)) "" ""
  echo -e " ${BX_BL}$(_ui_repeat "$BX_H" $((w-2)))${BX_BR}"
  echo -e "${U_RESET}"
}

# ui_header "TITLE"  - a single boxed section title
ui_header() {
  local title="$1" w=$UI_WIDTH
  echo
  echo -e "${U_BOLD}${U_CYAN}${LN_TL}$(_ui_repeat "$LN_H" $((w-2)))${LN_TR}${U_RESET}"
  printf  "${U_BOLD}${U_CYAN}${LN_V}${U_RESET} ${U_BOLD}%-$((w-4))s${U_RESET} ${U_BOLD}${U_CYAN}${LN_V}${U_RESET}\n" "$title"
  echo -e "${U_BOLD}${U_CYAN}${LN_BL}$(_ui_repeat "$LN_H" $((w-2)))${LN_BR}${U_RESET}"
}

# ui_rule  - a thin horizontal divider
ui_rule() { echo -e "${U_DIM}$(_ui_repeat "$LN_H" "$UI_WIDTH")${U_RESET}"; }

# ui_step CURRENT TOTAL "Title"  - progress banner for the guided flow
ui_step() {
  local cur="$1" total="$2" title="$3"
  echo
  echo -e "${U_ON_BLUE}${U_WHITE}${U_BOLD} STEP ${cur}/${total} ${U_RESET} ${U_BOLD}${title}${U_RESET}"
  ui_rule
}

# status lines
ui_ok()   { echo -e "  ${U_BGREEN}${CHECK}${U_RESET}  $*"; }
ui_warn() { echo -e "  ${U_BYELLOW}${WARN}${U_RESET}  $*"; }
ui_bad()  { echo -e "  ${U_BRED}${CROSS}${U_RESET}  $*"; }
ui_info() { echo -e "  ${U_BCYAN}${DOT}${U_RESET}  $*"; }
ui_kv()   { printf "  ${U_DIM}%-22s${U_RESET} %b\n" "$1" "$2"; }

# ---------------- severity model ----------------
# Levels, most to least severe:
#   CRITICAL  no/broken encryption or trivially bypassed
#   HIGH      practical offline/registrar attack path
#   MEDIUM    attackable only with a weak secret
#   LOW       hardened but with a known caveat
#   SECURE    no attack path exposed here
#   INFO      not applicable / passive only

# sev_badge LEVEL  - fixed-width colour-coded badge
sev_badge() {
  case "$1" in
    CRITICAL) echo -e "${U_ON_RED}${U_WHITE}${U_BOLD} CRITICAL ${U_RESET}" ;;
    HIGH)     echo -e "${U_BRED}${U_BOLD}[  HIGH  ]${U_RESET}" ;;
    MEDIUM)   echo -e "${U_BYELLOW}${U_BOLD}[ MEDIUM ]${U_RESET}" ;;
    LOW)      echo -e "${U_BBLUE}${U_BOLD}[  LOW   ]${U_RESET}" ;;
    SECURE)   echo -e "${U_BGREEN}${U_BOLD}[ SECURE ]${U_RESET}" ;;
    *)        echo -e "${U_DIM}[  INFO  ]${U_RESET}" ;;
  esac
}

# sev_rank LEVEL  - numeric weight for sorting (higher = worse)
sev_rank() {
  case "$1" in
    CRITICAL) echo 5 ;; HIGH) echo 4 ;; MEDIUM) echo 3 ;;
    LOW) echo 2 ;; SECURE) echo 1 ;; *) echo 0 ;;
  esac
}

# ui_legend  - severity key printed under a findings table
ui_legend() {
  echo
  echo -e "  ${U_BOLD}Severity key${U_RESET}"
  echo -e "    $(sev_badge CRITICAL)  no / broken encryption (OPEN, WEP) - anyone nearby gets in"
  echo -e "    $(sev_badge HIGH)  practical attack path (WPS PIN/Pixie-Dust, WEP key recovery)"
  echo -e "    $(sev_badge MEDIUM)  crackable only if the passphrase is weak (WPA2-PSK capture)"
  echo -e "    $(sev_badge LOW)  hardened but with a caveat (WPA2/WPA3 transition downgrade)"
  echo -e "    $(sev_badge SECURE)  no attack path exposed here (WPA3-SAE + PMF)"
}

# ---------------- signal bar ----------------
# ui_signal_bar DBM  - render airodump power (negative dBm) as a 5-cell bar
ui_signal_bar() {
  local dbm="$1"
  [[ "$dbm" =~ ^-?[0-9]+$ ]] || { printf '%b' "${U_DIM}  ?  ${U_RESET}"; return; }
  # Map -30 (excellent) .. -90 (unusable) onto 0..5 cells.
  local cells=0 col="$U_GREEN"
  if   (( dbm >= -45 )); then cells=5; col="$U_BGREEN"
  elif (( dbm >= -55 )); then cells=4; col="$U_GREEN"
  elif (( dbm >= -67 )); then cells=3; col="$U_YELLOW"
  elif (( dbm >= -75 )); then cells=2; col="$U_BYELLOW"
  elif (( dbm >= -85 )); then cells=1; col="$U_RED"
  else cells=0; col="$U_RED"; fi
  local i out=""
  for (( i=0; i<5; i++ )); do
    if (( i < cells )); then out+="$BAR_FULL"; else out+="$BAR_EMPTY"; fi
  done
  printf '%b%b%b' "$col" "$out" "$U_RESET"
}
