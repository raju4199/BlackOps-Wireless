#!/usr/bin/env bash
#
# install.sh - BlackOps Wireless bootstrapper
#
# Clones this repo -> run this script on Kali -> it installs the
# aircrack-ng toolchain and pulls in Airgeddon (+ optional extra tools)
# under ./tools/.
#
# Intended for an ISOLATED, AUTHORIZED lab only. See LAB_AUTHORIZATION.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="${REPO_ROOT}/tools"
LOG_FILE="${REPO_ROOT}/install.log"

# ---------- colors ----------
c_green="\e[32m"; c_yellow="\e[33m"; c_red="\e[31m"; c_blue="\e[34m"; c_reset="\e[0m"

info()  { echo -e "${c_blue}[*]${c_reset} $*" | tee -a "$LOG_FILE"; }
ok()    { echo -e "${c_green}[+]${c_reset} $*" | tee -a "$LOG_FILE"; }
warn()  { echo -e "${c_yellow}[!]${c_reset} $*" | tee -a "$LOG_FILE"; }
fail()  { echo -e "${c_red}[x]${c_reset} $*" | tee -a "$LOG_FILE"; exit 1; }

: > "$LOG_FILE"

# ---------- sanity checks ----------
if [[ $EUID -ne 0 ]]; then
  fail "Run this with sudo/root: sudo ./install.sh"
fi

if ! command -v apt-get >/dev/null 2>&1; then
  fail "No apt-get found. This installer targets Kali/Debian-based systems."
fi

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" != "kali" ]]; then
    warn "This doesn't look like Kali (ID=${ID:-unknown}). Continuing anyway, but package names/availability may differ."
  else
    ok "Detected Kali Linux (${VERSION:-unknown})."
  fi
fi

read -rp "$(echo -e "${c_yellow}This will install wireless auditing tools intended ONLY for your own authorized lab. Continue? [y/N] ${c_reset}")" CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { warn "Aborted by user."; exit 0; }

# ---------- apt packages ----------
# Core aircrack-ng suite + everything Airgeddon / Wifite / Bettercap commonly expect.
# Most of these ship on Kali by default; apt install is a no-op if already present.
APT_PACKAGES=(
  aircrack-ng
  mdk4
  hostapd
  dnsmasq
  isc-dhcp-server
  iw
  wireless-tools
  macchanger
  xterm
  tshark
  hashcat
  hcxtools
  hcxdumptool
  reaver
  bully
  ettercap-text-only
  wifite
  bettercap
  git
  curl
  usbutils
  kismet
)

export DEBIAN_FRONTEND=noninteractive

info "Updating package index..."
apt-get update -y >>"$LOG_FILE" 2>&1 || warn "apt-get update reported errors, check install.log"

info "Installing packages: ${APT_PACKAGES[*]}"
FAILED_PKGS=()
for pkg in "${APT_PACKAGES[@]}"; do
  if apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1; then
    ok "Installed/verified: $pkg"
  else
    warn "Could not install: $pkg (may not exist in your repos -- skipping)"
    FAILED_PKGS+=("$pkg")
  fi
done

# ---------- clone tools ----------
mkdir -p "$TOOLS_DIR"

clone_or_update() {
  local name="$1" url="$2" dest="${TOOLS_DIR}/$1"
  if [[ -d "$dest/.git" ]]; then
    info "Updating $name..."
    git -C "$dest" pull --ff-only >>"$LOG_FILE" 2>&1 && ok "$name up to date." || warn "$name pull failed, keeping existing copy."
  else
    info "Cloning $name..."
    if git clone --depth 1 "$url" "$dest" >>"$LOG_FILE" 2>&1; then
      ok "$name cloned into tools/$name"
    else
      warn "Failed to clone $name from $url"
    fi
  fi
}

clone_or_update "airgeddon"  "https://github.com/v1s1t0r1sh3r3/airgeddon.git"
clone_or_update "wifite2"    "https://github.com/derv82/wifite2.git"

# Airgeddon expects to be run as ./airgeddon.sh
if [[ -f "${TOOLS_DIR}/airgeddon/airgeddon.sh" ]]; then
  chmod +x "${TOOLS_DIR}/airgeddon/airgeddon.sh"
fi
if [[ -f "${TOOLS_DIR}/wifite2/Wifite.py" ]]; then
  chmod +x "${TOOLS_DIR}/wifite2/Wifite.py"
fi

chmod +x "${REPO_ROOT}/lab.sh" 2>/dev/null || true
chmod +x "${REPO_ROOT}/generate_report.sh" 2>/dev/null || true

# ---------- summary ----------
echo
ok "Install pass complete."
if [[ ${#FAILED_PKGS[@]} -gt 0 ]]; then
  warn "Packages that failed to install: ${FAILED_PKGS[*]}"
  warn "Airgeddon will re-check dependencies itself on launch and tell you what's still missing."
fi
echo
info "Next steps:"
echo "    1. Fill out LAB_AUTHORIZATION.md before doing anything else."
echo "    2. Plug in your monitor-mode-capable USB WiFi adapter and pass it into the VM"
echo "       (see SETUP_NOTES.md)."
echo "    3. Run:  sudo ./lab.sh"
echo
info "Full install log: $LOG_FILE"
