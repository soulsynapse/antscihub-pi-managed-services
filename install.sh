#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# antscihub-pi-managed-services installer
# Installs the meta service only. Safe to re-run.
# Usage: sudo bash install.sh
# =============================================================================

INSTALL_DIR="/opt/antscihub-pi-managed-services"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[install]${NC} $*"; }
warn() { echo -e "${YELLOW}[install]${NC} $*"; }
err()  { echo -e "${RED}[install]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    err "Must run as root: sudo bash install.sh"
    exit 1
fi

REAL_USER="${SUDO_USER:-pi}"
REAL_HOME=$(eval echo "~${REAL_USER}")
DESKTOP_DIR="${REAL_HOME}/Desktop"

log "User=${REAL_USER} Home=${REAL_HOME} Desktop=${DESKTOP_DIR}"

# --- Preflight ----------------------------------------------------------------

if ! command -v fleet-publish &>/dev/null; then
    err "fleet-publish not found. Is fleet-shell installed?"
    exit 1
fi

if ! command -v git &>/dev/null; then
    log "Installing git..."
    apt-get update -qq && apt-get install -y -qq git > /dev/null 2>&1
fi

# --- Copy files ---------------------------------------------------------------

log "Installing to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}/config"
mkdir -p "${INSTALL_DIR}/services"
mkdir -p "${DESKTOP_DIR}"

# Copy everything except .git
rsync -a --exclude='.git' --exclude='.gitignore' "${SCRIPT_DIR}/" "${INSTALL_DIR}/"

# Set SERVICES_DIR in config if blank
if grep -q '^SERVICES_DIR=""' "${INSTALL_DIR}/config/meta.conf" 2>/dev/null; then
    sed -i "s|^SERVICES_DIR=\"\"|SERVICES_DIR=\"${DESKTOP_DIR}\"|" "${INSTALL_DIR}/config/meta.conf"
fi

chmod +x "${INSTALL_DIR}/services/meta-service.sh"

# --- Disable Wi-Fi power management ------------------------------------------

log "Disabling Wi-Fi power management..."

mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-antscihub-wifi-powersave.conf <<'EOF'
[connection]
wifi.powersave = 2
EOF

cat > /etc/udev/rules.d/70-antscihub-wifi-powersave.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="/usr/sbin/iwconfig %k power off"
EOF

ip link show wlan0 &>/dev/null && iwconfig wlan0 power off 2>/dev/null || true

# --- Install systemd unit -----------------------------------------------------

log "Installing systemd service..."
cp "${INSTALL_DIR}/services/antscihub-meta.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now antscihub-meta.service

log "  ✓ antscihub-meta enabled and started"

# --- Report -------------------------------------------------------------------

fleet-publish --topic "fleet/managed-services/$(hostname)/install" \
    --json "{\"event\":\"meta_installed\",\"version\":\"$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)\"}" \
    2>/dev/null || true

# --- Done ---------------------------------------------------------------------

log "============================================"
log " antscihub-pi-managed-services installed!"
log ""
log " Config:  ${INSTALL_DIR}/config/meta.conf"
log " Logs:    journalctl -t antscihub-meta -f"
log " Status:  systemctl status antscihub-meta"
log ""
log " To add a managed service, place a folder"
log " in ${DESKTOP_DIR}/ with an"
log " antscihub.manifest file. See README."
log "============================================"